//! `hkm ppkg resolve` — run the solver against a project and report the result.
//!
//! The point of this command is that the resolver's claim is CHECKABLE.
//! `--check` resolves the project's `composer.json` from scratch and diffs the
//! answer against the `composer.lock` Composer produced, package by package.
//! Agreement on a real 107-package graph is evidence; a passing unit test on a
//! four-package fixture is not.
//!
//! Path repositories are read from disk and contributed as a single pinned
//! candidate. They are not a resolution decision — the project says where they
//! are — but they must be in the pool, because other packages depend on them and
//! a missing one would look like an unsatisfiable graph.

const std = @import("std");
const constraint = @import("constraint.zig");
const packagist = @import("packagist.zig");
const solver = @import("solver.zig");
const manifest = @import("manifest.zig");
const layout = @import("layout.zig");
const scripts_mod = @import("scripts.zig");
const lockfile = @import("lock.zig");
const fetch = @import("fetch.zig");
const prompt = @import("report.zig");
const util = @import("util.zig");
const lockwrite = @import("lockwrite.zig");
const contenthash = @import("contenthash.zig");
const compat = @import("compat.zig");
const vcs = @import("vcs.zig");
const repo_mod = @import("repo.zig");
const git = @import("git.zig");
const auth = @import("auth.zig");
const platform_mod = @import("platform.zig");
const settings = @import("settings.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// Load every credential source and hand the result to the two things that make
/// requests.
///
/// Both are set-once globals rather than parameters — see `fetch.credentials`
/// for why — so this is the single place that writes them, called at the top of
/// each entry point rather than from a library function that might run twice.
pub fn useCredentials(allocator: std.mem.Allocator, io: Io, env: *EnvMap, root_dir: []const u8) void {
    const store = auth.load(allocator, io, env, root_dir);
    fetch.credentials = store;
    git.credentials = store;

    if (store.hasAny()) {
        var hosts: std.ArrayList(u8) = .empty;
        for (store.credentials, 0..) |c, i| {
            if (i > 0) hosts.appendSlice(allocator, ", ") catch break;
            // The host and the scheme, never the secret.
            hosts.appendSlice(allocator, c.redacted(allocator)) catch break;
        }
        prompt.item("credentials", hosts.items);
    }
}

/// A pool that answers from local path repositories first, then Packagist.
const ProjectPool = struct {
    io: Io,
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    cache_dir: []const u8,
    locals: []const Local,
    /// Everything a `package` or `artifact` repository declares.
    ///
    /// Ahead of `vcs` in the search, because both are LOCAL — an inline
    /// definition and a file on this disk — and Composer consults repositories
    /// in declaration order with no network kind outranking a local one.
    static_candidates: []const packagist.Candidate = &.{},
    /// Everything the declared `vcs` repositories publish, read once up front.
    ///
    /// Searched BEFORE packagist, which is Composer's rule: repositories are
    /// consulted in declaration order and the implicit packagist entry is last.
    /// It is what makes a fork of a public package resolve to the fork.
    vcs_candidates: []const packagist.Candidate = &.{},
    meta: packagist.Options,
    /// Candidate lists already built, keyed by package name.
    ///
    /// Not an optimisation to file away for later: the solver asks for a
    /// package's candidates every time it reconsiders it, and answering means
    /// re-reading the metadata document and re-expanding every version in it.
    /// For `aws/aws-sdk-php` that is several hundred objects rebuilt per
    /// lookup, and with backtracking the same list gets rebuilt dozens of
    /// times — the difference between a resolution that takes a second and one
    /// that burns a minute of CPU and runs the arena out of memory.
    memo: std.ArrayList(Memo) = .empty,

    const Local = struct {
        name: []const u8,
        dir: []const u8,
        /// The url exactly as `repositories` declared it — what goes into the
        /// lock, and what `install` resolves against the project root. An
        /// absolute path here would make the lock unusable on any other
        /// machine.
        url: []const u8 = "",
    };

    /// `hash('sha1', $json . serialize($this->options))`.
    fn pathReference(allocator: std.mem.Allocator, composer_json: []const u8) ![]const u8 {
        var digest: [20]u8 = undefined;
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(composer_json);
        h.update("a:1:{s:8:\"relative\";b:1;}");
        h.final(&digest);
        return std.fmt.allocPrint(allocator, "{x}", .{&digest});
    }
    const Memo = struct { name: []const u8, candidates: []const packagist.Candidate };

    fn pool(self: *ProjectPool) solver.Pool {
        return .{ .context = self, .lookup = lookup };
    }

    fn lookup(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const packagist.Candidate {
        const self: *ProjectPool = @ptrCast(@alignCast(context));

        for (self.memo.items) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.candidates;
        }

        const built = try self.build(allocator, name);
        try self.memo.append(self.allocator, .{ .name = name, .candidates = built });
        return built;
    }

    fn build(self: *ProjectPool, allocator: std.mem.Allocator, name: []const u8) ![]const packagist.Candidate {
        // 1. path repositories — a checkout on disk beats anything remote.
        for (self.locals) |local| {
            if (!std.mem.eql(u8, local.name, name)) continue;
            return self.localCandidate(allocator, local);
        }

        // 2. package / artifact repositories — declared or on this disk.
        var from_static: std.ArrayList(packagist.Candidate) = .empty;
        for (self.static_candidates) |c| {
            if (std.mem.eql(u8, c.name, name)) try from_static.append(allocator, c);
        }
        if (from_static.items.len > 0) return from_static.toOwnedSlice(allocator);

        // 3. vcs repositories, in declaration order.
        var from_vcs: std.ArrayList(packagist.Candidate) = .empty;
        for (self.vcs_candidates) |c| {
            if (std.mem.eql(u8, c.name, name)) try from_vcs.append(allocator, c);
        }
        if (from_vcs.items.len > 0) return from_vcs.toOwnedSlice(allocator);

        // 4. packagist.
        return packagist.versionsOf(allocator, self.io, self.cache_dir, name, self.meta);
    }

    /// A path repository contributes exactly one candidate: whatever is on disk.
    fn localCandidate(self: *ProjectPool, allocator: std.mem.Allocator, local: Local) ![]const packagist.Candidate {
        const path = try std.fs.path.join(allocator, &.{ local.dir, "composer.json" });
        const source = Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(4 * 1024 * 1024)) catch {
            return error.NotFound;
        };
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{});
        if (parsed != .object) return error.NotFound;

        var obj = try parsed.object.clone(allocator);
        // A path package has no version of its own; Composer gives it the branch
        // it is checked out on, and the branch-alias is what lets a numeric
        // constraint match it.
        const version = if (obj.get("version")) |v| switch (v) {
            .string => |s| s,
            else => try branchVersion(allocator, self.io, local.dir),
        } else try branchVersion(allocator, self.io, local.dir);

        try obj.put(allocator, "version", .{ .string = version });

        // `ArrayLoader` defaults a package with no declared type to `library`,
        // and the lock dumper writes the field unconditionally — so a path
        // package whose composer.json omits it still ends up with it in the
        // lock. Omitting it here is a one-line diff against every lock
        // Composer writes for the same project.
        if (obj.get("type") == null) try obj.put(allocator, "type", .{ .string = "library" });

        // The `dist` a path package gets. Without it the lock records a package
        // with no source of any kind, and `install` refuses it — correctly,
        // because nothing in the entry says where the files are.
        //
        // `PathRepository::initialize`:
        //
        //     dist.type      "path"
        //     dist.url       the url AS DECLARED, relative to the project
        //     dist.reference sha1(composer.json bytes . serialize(options))
        //
        // The options of a plain path repository are `['relative' => true]`,
        // whose PHP serialisation is the literal below — reproduced rather
        // than computed because there is exactly one shape of it and a
        // serialiser for one value is more code than the value.
        var dist: std.json.ObjectMap = .empty;
        try dist.put(allocator, "type", .{ .string = "path" });
        try dist.put(allocator, "url", .{ .string = local.url });
        try dist.put(allocator, "reference", .{ .string = try pathReference(allocator, source) });
        try obj.put(allocator, "dist", .{ .object = dist });

        var transport: std.json.ObjectMap = .empty;
        try transport.put(allocator, "relative", .{ .bool = true });
        try obj.put(allocator, "transport-options", .{ .object = transport });

        const one = try allocator.alloc(packagist.Candidate, 1);
        one[0] = .{
            .name = local.name,
            .version = version,
            .version_normalized = version,
            .raw = .{ .object = obj },
        };
        return one;
    }

    /// The branch a path package is checked out on, as `dev-<branch>`.
    ///
    /// `.git` is a FILE, not a directory, in a submodule and in any worktree —
    /// it holds `gitdir: <path>` pointing at the real repository. Every module
    /// in this kernel is a submodule, so reading `<dir>/.git/HEAD` directly
    /// finds nothing and silently falls back to `dev-master`, which then
    /// disagrees with the lock for every one of them.
    fn branchVersion(allocator: std.mem.Allocator, io: Io, dir: []const u8) ![]const u8 {
        const git_dir = try resolveGitDir(allocator, io, dir);
        const head_path = try std.fs.path.join(allocator, &.{ git_dir, "HEAD" });

        const head = Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096)) catch {
            return "dev-master";
        };
        const trimmed = std.mem.trim(u8, head, " \n\r\t");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return std.fmt.allocPrint(allocator, "dev-{s}", .{std.fs.path.basename(trimmed[5..])});
        }

        // Detached HEAD — the normal state of a submodule pinned to a commit.
        // Composer does not stop at `dev-<sha>` here: its VersionGuesser looks
        // for a local branch sitting on that same commit and uses its name, and
        // that is what makes `phpshots/bind-it` resolve as `dev-master` rather
        // than as a sha nothing declares a constraint against.
        if (try branchAtCommit(allocator, io, git_dir, trimmed)) |branch| {
            return std.fmt.allocPrint(allocator, "dev-{s}", .{branch});
        }
        return std.fmt.allocPrint(allocator, "dev-{s}", .{trimmed});
    }

    /// A local branch whose tip is `sha`, preferring the conventional names.
    ///
    /// Reads the ref files directly rather than spawning git: this runs inside a
    /// resolution that is otherwise process-free, and `git` may not be on PATH
    /// in a deployed tree at all.
    fn branchAtCommit(
        allocator: std.mem.Allocator,
        io: Io,
        git_dir: []const u8,
        sha: []const u8,
    ) !?[]const u8 {
        const heads = try std.fs.path.join(allocator, &.{ git_dir, "refs", "heads" });

        var best: ?[]const u8 = null;
        var d = Dir.cwd().openDir(io, heads, .{ .iterate = true }) catch return null;
        defer d.close(io);

        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;

            const ref_path = try std.fs.path.join(allocator, &.{ heads, entry.name });
            const body = Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(256)) catch continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, body, " \n\r\t"), sha)) continue;

            // Several branches can sit on one commit; prefer the one a
            // branch-alias is most likely to be declared for.
            if (std.mem.eql(u8, entry.name, "master") or std.mem.eql(u8, entry.name, "main")) {
                return try allocator.dupe(u8, entry.name);
            }
            if (best == null) best = try allocator.dupe(u8, entry.name);
        }
        return best;
    }

    /// `<dir>/.git`, following the `gitdir:` indirection when it is a file.
    fn resolveGitDir(allocator: std.mem.Allocator, io: Io, dir: []const u8) ![]const u8 {
        const dot_git = try std.fs.path.join(allocator, &.{ dir, ".git" });

        const body = Dir.cwd().readFileAlloc(io, dot_git, allocator, .limited(4096)) catch {
            return dot_git; // a real directory
        };
        const text = std.mem.trim(u8, body, " \n\r\t");
        if (!std.mem.startsWith(u8, text, "gitdir:")) return dot_git;

        const target = std.mem.trim(u8, text["gitdir:".len..], " \n\r\t");
        if (target.len > 0 and target[0] == '/') return allocator.dupe(u8, target);
        return std.fs.path.join(allocator, &.{ dir, target });
    }
};

pub const Options = struct {
    dev: bool = true,
    check: bool = false,
    with_dev_branches: bool = false,
    /// Write the resolution to composer.lock.
    write: bool = false,
    /// Resolve and report what WOULD be written, touching nothing.
    dry_run: bool = false,
    /// Re-list vcs refs even when a cached listing is still within its TTL.
    refresh: bool = false,
    /// Proceed despite a blocking compatibility finding.
    ///
    /// The operator's override, not a default: only they can know that their
    /// `vcs` entry mirrors the packagist package it shadows.
    ignore_unsupported: bool = false,
    /// The ROOT package's `scripts` — `pre-update-cmd` and `post-update-cmd`
    /// fire around a run that WRITES. A `--check` or `--dry-run` raises
    /// neither, because nothing happened for a hook to react to.
    scripts: scripts_mod.Options = .{},

    // ── partial update ────────────────────────────────────────────────────────

    /// Package names this run may move. Empty means every package.
    ///
    /// `composer update vendor/name` — the difference between reviewing one
    /// dependency bump and reviewing all of them. Patterns are accepted
    /// (`symfony/*`), as Composer accepts them.
    only: []const []const u8 = &.{},
    /// `-w` — also move what the named packages require, EXCEPT packages the
    /// root requires directly. Those are the project's own declarations, and
    /// moving one because something else pulled it in is a change the operator
    /// did not ask for.
    with_dependencies: bool = false,
    /// `-W` — move the transitive dependencies too, root requirements included.
    with_all_dependencies: bool = false,
    /// `--root-reqs` — restrict the update to first-degree dependencies.
    root_reqs_only: bool = false,
    /// `--lock` — re-write the lock without moving a single version.
    ///
    /// For a manifest edit that does not change what resolves: the lock's
    /// content-hash goes stale and every later command warns about it. This
    /// pins everything and rewrites the file.
    lock_only: bool = false,
    /// `--prefer-lowest` — take the floor of every constraint.
    prefer_lowest: bool = false,
    /// `--prefer-stable` on the command line, overriding the manifest.
    prefer_stable: bool = false,
    /// `--ignore-platform-req` — platform requirements not to enforce.
    ignore_platform: platform_mod.Ignore = .{},
};

/// The packages a partial update must NOT move.
///
/// Everything in the lock except what was named (and, under `-w`/`-W`, what
/// those depend on). A package with no pin is free to move; a pinned one is
/// offered exactly the version the lock holds.
fn computePins(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    root: manifest.Manifest,
    opts: Options,
) ![]const solver.Pin {
    if (!opts.lock_only and opts.only.len == 0 and !opts.root_reqs_only) return &.{};

    const lock = lockfile.read(allocator, io, root_dir) catch {
        // Nothing to hold anything at. Naming packages to update when there is
        // no lock is a request that cannot be honoured, and resolving
        // everything instead would quietly do the opposite of what was asked.
        prompt.err("A partial update needs an existing composer.lock — there is none here. Run a full update first.");
        return error.NoLockFile;
    };

    var free: std.ArrayList([]const u8) = .empty;
    if (!opts.lock_only) {
        if (opts.root_reqs_only) {
            for (root.require) |d| try free.append(allocator, d.name);
            if (opts.dev) for (root.require_dev) |d| try free.append(allocator, d.name);
        }
        for (lock.packages) |p| {
            for (opts.only) |pattern| {
                if (nameMatches(pattern, p.name)) {
                    try free.append(allocator, p.name);
                    break;
                }
            }
        }
        if (opts.with_dependencies or opts.with_all_dependencies) {
            try expandDependencies(allocator, lock, root, opts, &free);
        }
    }

    var pins: std.ArrayList(solver.Pin) = .empty;
    for (lock.packages) |p| {
        if (util.contains(free.items, p.name)) continue;
        try pins.append(allocator, .{ .name = p.name, .version = p.version });
    }
    return pins.toOwnedSlice(allocator);
}

/// Walk `require` from the already-free packages, freeing what they reach.
///
/// `-w` stops at a package the ROOT requires directly: that is the project's
/// own declaration, and moving it because a dependency reached it is a change
/// nobody asked for. `-W` does not stop.
fn expandDependencies(
    allocator: std.mem.Allocator,
    lock: lockfile.Lock,
    root: manifest.Manifest,
    opts: Options,
    free: *std.ArrayList([]const u8),
) !void {
    var cursor: usize = 0;
    while (cursor < free.items.len) : (cursor += 1) {
        const name = free.items[cursor];
        const pkg = findLocked(lock, name) orelse continue;
        if (pkg.raw != .object) continue;
        const m = manifest.fromObject(allocator, pkg.raw.object) catch continue;
        for (m.require) |dep| {
            if (solver.isPlatform(dep.name)) continue;
            if (util.contains(free.items, dep.name)) continue;
            if (!opts.with_all_dependencies and isRootRequirement(root, dep.name)) continue;
            if (findLocked(lock, dep.name) == null) continue;
            try free.append(allocator, dep.name);
        }
    }
}

fn findLocked(lock: lockfile.Lock, name: []const u8) ?lockfile.Package {
    for (lock.packages) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
    }
    return null;
}

fn isRootRequirement(root: manifest.Manifest, name: []const u8) bool {
    for (root.require) |d| {
        if (std.ascii.eqlIgnoreCase(d.name, name)) return true;
    }
    for (root.require_dev) |d| {
        if (std.ascii.eqlIgnoreCase(d.name, name)) return true;
    }
    return false;
}

/// `vendor/name`, or a pattern with `*` in it — Composer accepts both.
fn nameMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse
        return std.ascii.eqlIgnoreCase(pattern, name);
    const head = pattern[0..star];
    const tail = pattern[star + 1 ..];
    if (name.len < head.len + tail.len) return false;
    return std.ascii.startsWithIgnoreCase(name, head) and
        std.ascii.endsWithIgnoreCase(name, tail);
}

pub fn command(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    opts: Options,
) !u8 {
    const root = (try manifest.read(allocator, io, root_dir)) orelse {
        prompt.err("No composer.json here.");
        return 1;
    };

    prompt.intro("ppkg resolve");

    // Credentials before any request. A private repository without one is a
    // 404, and a 404 during resolution reads as "no such package".
    useCredentials(allocator, io, env, root_dir);

    // And the transport settings the same config block carries — the CA
    // bundle, `secure-http`, the cache directory. Before the first request,
    // for the same reason.
    const cfg = settings.load(allocator, io, env, root_dir);
    cfg.applyTransport();

    // Before anything is fetched or written. A project this package cannot
    // honour must hear so BEFORE it gets a lock that looks ordinary and points
    // somewhere else.
    if (try reportCompat(allocator, root, opts.ignore_unsupported)) |code| return code;

    // `pre-update-cmd` fires before any metadata is fetched, so a project can
    // refuse an update it is not ready for — which a hook running afterwards
    // could not do.
    if (opts.write and !opts.dry_run) {
        const lay = try layout.resolve(allocator, env, root_dir, root);
        const code = try scripts_mod.run(allocator, io, env, lay, .pre_update_cmd, opts.scripts);
        if (code != 0) {
            prompt.err("pre-update-cmd failed; composer.lock was not touched.");
            return code;
        }
    }

    var locals: std.ArrayList(ProjectPool.Local) = .empty;
    for (root.repositories) |repo| {
        if (repo.kind != .path or repo.url.len == 0) continue;
        const dir = try std.fs.path.join(allocator, &.{ root_dir, repo.url });
        if (try manifest.read(allocator, io, dir)) |m| {
            if (m.name.len > 0) try locals.append(allocator, .{ .name = m.name, .dir = dir, .url = repo.url });
        }
    }
    if (locals.items.len > 0) {
        prompt.item("path repositories", try std.fmt.allocPrint(allocator, "{d} pinned from disk", .{locals.items.len}));
    }

    // What this run is allowed to move. Computed before anything is fetched,
    // so a partial update with no lock fails immediately rather than after a
    // minute of metadata requests.
    const pins = try computePins(allocator, io, root_dir, root, opts);
    if (pins.len > 0) {
        prompt.item("held at the lock", try std.fmt.allocPrint(
            allocator,
            "{d} package{s}{s}",
            .{
                pins.len,
                if (pins.len == 1) @as([]const u8, "") else "s",
                if (opts.lock_only) "  (--lock: nothing will move)" else "",
            },
        ));
    }

    var roots: std.ArrayList(solver.Requirement) = .empty;
    for (root.require) |dep| try appendRoot(allocator, dep, &roots);
    if (opts.dev) for (root.require_dev) |dep| try appendRoot(allocator, dep, &roots);

    prompt.item("root requirements", try std.fmt.allocPrint(allocator, "{d}", .{roots.items.len}));
    prompt.item("stability floor", try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ root.minimum_stability, if (root.prefer_stable) "  (prefer-stable)" else "" },
    ));

    // Dev branches live in a second metadata document (`~dev.json`) and cost a
    // second request per package, so they are not fetched unconditionally. They
    // ARE fetched whenever the project's floor is below stable: a project that
    // declares `minimum-stability: dev` is very likely to require a branch
    // somewhere (this kernel requires `psr/http-message: 2.0.x-dev`), and
    // without the dev document that requirement has an empty pool and looks
    // like a package with no matching release.
    const floor = stabilityOf(root);
    const need_dev = opts.with_dev_branches or @intFromEnum(floor) < @intFromEnum(constraint.Stability.stable);

    // Read the vcs repositories before solving. A lookup cannot know which of
    // them publishes a given name without asking, so they are all asked once,
    // concurrently, rather than one at a time as the search stumbles into them.
    var vcs_repos: std.ArrayList(vcs.Repo) = .empty;
    for (root.repositories) |entry| {
        if (!entry.isVcs() or entry.url.len == 0) continue;
        // Every host and every tool is read now — GitHub over its static
        // endpoints, any other git host through a bare mirror, Mercurial
        // through a `--noupdate` clone, Subversion straight over its own
        // protocol. A non-GitHub entry used to be dropped here, which meant the
        // packagist package of the same name was taken instead: a lock that
        // looks ordinary and points at somebody else's code. `compat` blocked
        // that case rather than let it happen; there is nothing left to block.
        try vcs_repos.append(
            allocator,
            vcs.parseAs(allocator, entry.kind, entry.url, entry.raw) catch continue,
        );
    }

    var project: ProjectPool = .{
        .io = io,
        .allocator = allocator,
        .root_dir = root_dir,
        .cache_dir = try fetch.cacheRoot(allocator, env, root_dir),
        .locals = locals.items,
        .meta = .{ .dev = need_dev },
    };

    // `package` and `artifact` repositories, read before the solver starts.
    // Both are local, so this is disk work, not network work — but an artifact
    // directory still has to be unpacked once to learn what is in it.
    {
        var static_all: std.ArrayList(packagist.Candidate) = .empty;
        var rejected: usize = 0;
        for (root.repositories) |entry| {
            const result = switch (entry.kind) {
                .package => repo_mod.inlinePackages(allocator, entry) catch continue,
                .artifact => repo_mod.artifacts(allocator, io, root_dir, project.cache_dir, entry) catch continue,
                else => continue,
            };
            try static_all.appendSlice(allocator, result.candidates);
            // Never silent. A rejected definition is a package the project
            // thinks it has, and the failure it would otherwise produce is
            // "could not find a matching version", which sends the reader
            // looking for a typo in a name that is spelled correctly.
            for (result.rejected) |r| {
                rejected += 1;
                prompt.warn(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ r.subject, r.reason }));
            }
        }
        project.static_candidates = try static_all.toOwnedSlice(allocator);
        if (project.static_candidates.len > 0 or rejected > 0) {
            prompt.item("package/artifact repositories", try std.fmt.allocPrint(
                allocator,
                "{d} version{s} declared locally",
                .{ project.static_candidates.len, if (project.static_candidates.len == 1) @as([]const u8, "") else "s" },
            ));
        }
    }

    if (vcs_repos.items.len > 0) {
        vcs.refresh_refs = opts.refresh;
        const started_vcs = std.Io.Timestamp.now(io, .awake);
        const primed = vcs.prime(
            allocator,
            io,
            env,
            project.cache_dir,
            vcs_repos.items,
            fetch.workerCount(env),
        );
        project.vcs_candidates = primed.candidates;

        const ms = started_vcs.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        prompt.item("vcs repositories", try std.fmt.allocPrint(
            allocator,
            "{d} read in {d}ms — {d} versions, no API calls",
            .{ vcs_repos.items.len, ms, primed.candidates.len },
        ));
        if (primed.failed > 0) {
            prompt.warn(try std.fmt.allocPrint(
                allocator,
                "{d} vcs repositor{s} could not be read; anything only they publish will not resolve.",
                .{ primed.failed, if (primed.failed == 1) @as([]const u8, "y") else "ies" },
            ));
        }
    }

    // Warm the metadata cache for everything this resolution is likely to
    // touch, BEFORE the solver starts asking for packages one at a time.
    //
    // The seed list is the root requirements plus, when there is a lock, every
    // package in it — the best available guess at the closure. But a first
    // resolve has no lock, and then the seeds are just the two or three direct
    // requirements: the solver discovers the other seventy one at a time, each
    // a serial round trip. Measured on a 71-package tree that was 167 seconds
    // of wall clock against 9 seconds of CPU — the process was asleep on the
    // network for 95% of it.
    //
    // So the closure is discovered in WAVES instead: fetch what is known,
    // read what those packages require, fetch all of that at once, repeat. The
    // depth of a PHP dependency graph is small, so this is a handful of
    // parallel rounds rather than one serial chain.
    {
        var seeds: std.ArrayList([]const u8) = .empty;
        for (roots.items) |r| try seeds.append(allocator, r.name);
        if (lockfile.read(allocator, io, root_dir) catch null) |lock| {
            for (lock.packages) |p| {
                if (util.contains(seeds.items, p.name)) continue;
                try seeds.append(allocator, p.name);
            }
        }

        const started_warm = std.Io.Timestamp.now(io, .awake);
        const warmed = try warmGraph(allocator, io, env, &project, seeds.items);
        const ms = started_warm.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        if (warmed.fetched > 0) {
            prompt.item("metadata", try std.fmt.allocPrint(
                allocator,
                "{d} packages in {d} parallel wave{s}, {d}ms",
                .{ warmed.fetched, warmed.waves, if (warmed.waves == 1) @as([]const u8, "") else "s", ms },
            ));
        }
    }

    const started = std.Io.Timestamp.now(io, .awake);
    const outcome = try solver.solve(allocator, project.pool(), roots.items, .{
        .minimum_stability = floor,
        .prefer_stable = root.prefer_stable or opts.prefer_stable,
        .with_dev = need_dev,
        .prefer_lowest = opts.prefer_lowest,
        .pins = pins,
    });
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    const decisions = switch (outcome) {
        .solved => |d| d,
        .unsatisfiable => |c| {
            prompt.blank();
            prompt.err(try std.fmt.allocPrint(allocator, "No version of {s} satisfies every requirement on it:", .{c.name}));
            for (c.demands) |d| {
                prompt.muted(try std.fmt.allocPrint(allocator, "    {s} requires {s}", .{ d.origin, d.text }));
            }
            if (c.available.len > 0) {
                prompt.blank();
                prompt.muted(try std.fmt.allocPrint(
                    allocator,
                    "  available: {s}",
                    .{try util.joinList(allocator, c.available)},
                ));
            } else {
                prompt.muted("  available: nothing in the pool");
            }
            return 1;
        },
        .unavailable => |name| {
            prompt.blank();
            prompt.err(try std.fmt.allocPrint(allocator, "No metadata for {s} — unknown package, or the network is unavailable.", .{name}));
            return 1;
        },
        .exhausted => |steps| {
            prompt.blank();
            // Deliberately not phrased as "impossible": the search gave up.
            prompt.err(try std.fmt.allocPrint(
                allocator,
                "Gave up after {d} decisions. This resolver backtracks; it cannot prove a graph unsatisfiable the way composer's SAT solver can.",
                .{steps},
            ));
            return 1;
        },
    };

    prompt.item("resolved", try std.fmt.allocPrint(allocator, "{d} packages in {d}ms", .{ decisions.len, elapsed_ms }));

    if (opts.write or opts.dry_run) {
        const code = try writeLock(allocator, io, root_dir, root, decisions, locals.items, opts, cfg);
        if (code != 0 or opts.dry_run) return code;
        // Only after a lock was actually written. `post-update-cmd` exists to
        // react to a changed dependency set, and a dry run changed nothing.
        const lay = try layout.resolve(allocator, env, root_dir, root);
        return scripts_mod.run(allocator, io, env, lay, .post_update_cmd, opts.scripts);
    }

    if (!opts.check) {
        prompt.section("Chosen");
        for (decisions) |d| {
            prompt.muted(try std.fmt.allocPrint(allocator, "    {s} {s}", .{ d.name, d.candidate.version }));
        }
        prompt.outro("resolution only — no lock written");
        return 0;
    }

    return compareToLock(allocator, io, root_dir, decisions);
}

fn appendRoot(allocator: std.mem.Allocator, dep: manifest.Dep, out: *std.ArrayList(solver.Requirement)) !void {
    if (dep.isPlatform()) return;
    try out.append(allocator, .{
        .name = dep.name,
        .text = dep.constraint,
        .parsed = try constraint.parse(allocator, dep.constraint),
        .origin = "__root__",
    });
}

/// The pool floor for this project.
///
/// Load-bearing, and easy to overlook: the kernel declares
/// `"minimum-stability": "dev"`, and with the default `stable` floor every one
/// of its path packages — all on `dev-master` — is filtered out of the pool
/// before any constraint is consulted, so the graph looks unsatisfiable.
fn stabilityOf(root: manifest.Manifest) constraint.Stability {
    return constraint.stabilityFromName(root.minimum_stability);
}

/// Diff the resolution against the lock Composer produced.
fn compareToLock(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    decisions: []const solver.Decision,
) !u8 {
    const lock = lockfile.read(allocator, io, root_dir) catch {
        prompt.warn("No composer.lock to compare against.");
        return 1;
    };

    var same: usize = 0;
    var differing: usize = 0;
    var missing: usize = 0;

    prompt.section("Against composer.lock");

    for (decisions) |d| {
        var found: ?lockfile.Package = null;
        for (lock.packages) |p| {
            if (std.mem.eql(u8, p.name, d.name)) found = p;
        }
        const locked = found orelse {
            prompt.muted(try std.fmt.allocPrint(allocator, "    + {s} {s}  (not in the lock)", .{ d.name, d.candidate.version }));
            missing += 1;
            continue;
        };
        if (std.mem.eql(u8, locked.version, d.candidate.version)) {
            same += 1;
            continue;
        }
        differing += 1;
        prompt.muted(try std.fmt.allocPrint(
            allocator,
            "    ~ {s}  lock {s}  →  resolved {s}",
            .{ d.name, locked.version, d.candidate.version },
        ));
    }

    var absent: usize = 0;
    for (lock.packages) |p| {
        var seen = false;
        for (decisions) |d| {
            if (std.mem.eql(u8, d.name, p.name)) seen = true;
        }
        if (!seen) absent += 1;
    }

    prompt.blank();
    prompt.item("identical", try std.fmt.allocPrint(allocator, "{d}", .{same}));
    if (differing > 0) prompt.item("different version", try std.fmt.allocPrint(allocator, "{d}", .{differing}));
    if (missing > 0) prompt.item("not in the lock", try std.fmt.allocPrint(allocator, "{d}", .{missing}));
    if (absent > 0) prompt.item("in the lock only", try std.fmt.allocPrint(allocator, "{d}", .{absent}));

    prompt.blank();
    if (differing == 0 and missing == 0 and absent == 0) {
        prompt.ok("The resolution matches the lock exactly.");
        return 0;
    }
    // A newer release published since the lock was written is a legitimate
    // difference, not a defect — which is why this reports rather than fails.
    prompt.note("Differences are expected where a newer release exists than the lock pinned.");
    return 0;
}

// ── writing the lock ──────────────────────────────────────────────────────────

/// Turn a resolution into composer.lock.
fn writeLock(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    root: manifest.Manifest,
    decisions: []const solver.Decision,
    locals: []const ProjectPool.Local,
    opts: Options,
    /// The merged `config`, for `lock`.
    cfg: settings.Settings,
) !u8 {
    // The hash is taken over the composer.json ON DISK, not over the parsed
    // manifest: it is a fingerprint of the file's bytes-as-decoded, and any
    // field this package does not model still participates in it.
    const json_path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const json_source = Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(8 * 1024 * 1024)) catch {
        prompt.err("composer.json could not be read.");
        return 1;
    };
    const hash = contenthash.of(allocator, json_source) catch {
        prompt.err("composer.json could not be parsed.");
        return 1;
    };

    // A package is a DEV package when nothing reachable from `require` needs
    // it. Composer resolves both sets together and partitions afterwards for
    // the same reason: a package can be a direct dev requirement and also a
    // transitive runtime one, and it belongs in `packages` when it is.
    const runtime = try reachableFrom(allocator, root.require, decisions);

    var prod: std.ArrayList(lockwrite.Package) = .empty;
    var dev: std.ArrayList(lockwrite.Package) = .empty;
    for (decisions) |d| {
        const entry: lockwrite.Package = .{
            .name = d.name,
            .version = d.candidate.version,
            .raw = d.candidate.raw,
            // `notification-url` belongs to the REPOSITORY, not to the
            // package, so it is applied here rather than read from the
            // metadata — and only for a package packagist actually served. A
            // git remote, an inline definition and a path checkout each get
            // none, which is what Composer writes and what this used to get
            // wrong for every vcs package in a lock.
            .notification_url = if (isLocalName(locals, d.name) or d.candidate.origin != .packagist)
                null
            else
                packagist.notification_url,
        };
        if (util.contains(runtime, d.name)) {
            try prod.append(allocator, entry);
        } else {
            try dev.append(allocator, entry);
        }
    }

    const data: lockwrite.Data = .{
        .content_hash = hash,
        .packages = prod.items,
        // `--no-dev` records null here; a resolution that considered dev
        // requirements records a list, empty or not.
        .packages_dev = if (opts.dev) dev.items else null,
        .minimum_stability = root.minimum_stability,
        .stability_flags = try stabilityFlags(allocator, root),
        .prefer_stable = root.prefer_stable,
        .platform = try platformMap(allocator, root.require),
        .platform_dev = try platformMap(allocator, root.require_dev),
        .platform_overrides = if (root.config_platform.len > 0)
            try depMap(allocator, root.config_platform)
        else
            null,
    };

    const rendered = try lockwrite.render(allocator, data);

    prompt.item("packages", try std.fmt.allocPrint(allocator, "{d}", .{prod.items.len}));
    if (opts.dev) {
        prompt.item("packages-dev", try std.fmt.allocPrint(allocator, "{d}", .{dev.items.len}));
    }
    prompt.item("content-hash", hash);

    const lock_path = try std.fs.path.join(allocator, &.{ root_dir, "composer.lock" });

    if (opts.dry_run) {
        const existing = Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(64 * 1024 * 1024)) catch "";
        prompt.blank();
        if (existing.len > 0 and std.mem.eql(u8, existing, rendered)) {
            prompt.ok("composer.lock is already exactly this.");
        } else if (existing.len == 0) {
            prompt.note(try std.fmt.allocPrint(allocator, "Would create composer.lock ({d} bytes).", .{rendered.len}));
        } else {
            prompt.note(try std.fmt.allocPrint(
                allocator,
                "Would rewrite composer.lock ({d} → {d} bytes).",
                .{ existing.len, rendered.len },
            ));
        }
        prompt.outro("dry run — nothing was written");
        return 0;
    }

    // `config.lock: false` — a library that deliberately ships no lock. Writing
    // one anyway adds a file to their repository, and the next `git status` is
    // where they would find out.
    if (!cfg.writesLock()) {
        prompt.note("config.lock is false — composer.lock was resolved but not written.");
        prompt.outro("resolved");
        return 0;
    }

    util.writeFileAtomic(io, lock_path, rendered) catch {
        prompt.err("composer.lock could not be written.");
        return 1;
    };

    prompt.blank();
    prompt.ok("composer.lock written.");
    prompt.note("Run `ppkg install` to bring vendor/ in line with it.");
    prompt.outro(try std.fmt.allocPrint(allocator, "{d} bytes", .{rendered.len}));
    return 0;
}

/// Every package reachable from a set of root requirements, over the SOLVED
/// set — so the walk follows the versions actually chosen, not the whole pool.
fn reachableFrom(
    allocator: std.mem.Allocator,
    roots: []const manifest.Dep,
    decisions: []const solver.Decision,
) ![]const []const u8 {
    var seen: std.ArrayList([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;

    for (roots) |dep| {
        if (dep.isPlatform()) continue;
        try queue.append(allocator, dep.name);
    }

    while (queue.pop()) |name| {
        if (util.contains(seen.items, name)) continue;
        try seen.append(allocator, name);

        for (decisions) |d| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            for (try d.candidate.requires(allocator)) |req| {
                if (solver.isPlatform(req.name)) continue;
                if (util.contains(seen.items, req.name)) continue;
                try queue.append(allocator, req.name);
            }
        }
    }

    return seen.toOwnedSlice(allocator);
}

/// The `platform` / `platform-dev` maps: the root's platform requirements,
/// ksorted, exactly as declared.
fn platformMap(allocator: std.mem.Allocator, deps: []const manifest.Dep) !std.json.Value {
    var only: std.ArrayList(manifest.Dep) = .empty;
    for (deps) |d| {
        if (d.isPlatform()) try only.append(allocator, d);
    }
    return depMap(allocator, only.items);
}

/// `platform`, `platform-dev` and `platform-overrides` keep the order they were
/// DECLARED in.
///
/// Not sorted, and the asymmetry is deliberate on Composer's part rather than an
/// oversight: `fixupJsonDataType` ksorts `stability-flags` and pointedly leaves
/// these alone, so they read back in the order the author wrote them in
/// composer.json. Sorting here is a diff on every project whose requirements
/// are not already alphabetical.
fn depMap(allocator: std.mem.Allocator, deps: []const manifest.Dep) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (deps) |d| try obj.put(allocator, d.name, .{ .string = d.constraint });
    return .{ .object = obj };
}

fn isLocalName(locals: []const ProjectPool.Local, name: []const u8) bool {
    for (locals) |l| {
        if (std.mem.eql(u8, l.name, name)) return true;
    }
    return false;
}

/// `stability-flags` — per-package floors declared inside a constraint.
///
/// Transcribed from `RootPackageLoader::extractStabilityFlags`. Two rules, and
/// the first wins outright when it matches:
///
///   1. An explicit `@stability` suffix anywhere in the constraint.
///   2. Otherwise, a bare single-token constraint whose own stability is not
///      stable — which is how `dev-main` or `1.0.0-beta1` raises the floor for
///      that one package without touching `minimum-stability`.
///
/// A wrong value here is not cosmetic: Composer compares the whole lock array
/// and rewrites the file when it differs, so an incorrect flag means every
/// `composer install` reports the lock as out of date.
fn stabilityFlags(allocator: std.mem.Allocator, root: manifest.Manifest) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    var names: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList(i64) = .empty;

    for ([_][]const manifest.Dep{ root.require, root.require_dev }) |list| {
        for (list) |dep| {
            if (dep.isPlatform()) continue;
            const flag = flagFor(dep.constraint) orelse continue;

            // A package named twice keeps the LOWEST number, i.e. the most
            // stable floor already recorded.
            var found = false;
            for (names.items, 0..) |n, i| {
                if (!std.ascii.eqlIgnoreCase(n, dep.name)) continue;
                found = true;
                if (flag < flags.items[i]) flags.items[i] = flag;
            }
            if (!found) {
                try names.append(allocator, dep.name);
                try flags.append(allocator, flag);
            }
        }
    }

    const order = try allocator.dupe([]const u8, names.items);
    std.mem.sort([]const u8, order, {}, lessBytes);

    for (order) |name| {
        for (names.items, flags.items) |n, f| {
            if (!std.mem.eql(u8, n, name)) continue;
            try obj.put(allocator, name, .{ .integer = f });
            break;
        }
    }

    return .{ .object = obj };
}

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `BasePackage::STABILITIES` — the numbers the lock records.
fn stabilityNumber(s: constraint.Stability) i64 {
    return switch (s) {
        .stable, .patch => 0,
        .rc => 5,
        .beta => 10,
        .alpha => 15,
        .dev => 20,
    };
}

fn flagFor(text: []const u8) ?i64 {
    var best: ?i64 = null;

    var alternatives = std.mem.splitSequence(u8, text, "||");
    while (alternatives.next()) |alt| {
        var parts = std.mem.tokenizeAny(u8, alt, ", \t");
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t");
            if (part.len == 0) continue;

            // Rule 1: an explicit `@stability` suffix.
            if (std.mem.lastIndexOfScalar(u8, part, '@')) |at| {
                const name = part[at + 1 ..];
                if (name.len > 0) {
                    const s = constraint.stabilityFromName(name);
                    // stabilityFromName falls back to stable for anything it
                    // does not recognise, so an unknown suffix records nothing
                    // rather than silently pinning the package to stable.
                    if (!std.ascii.eqlIgnoreCase(name, "stable") and stabilityNumber(s) != 0) {
                        const n = stabilityNumber(s);
                        if (best == null or n < best.?) best = n;
                    }
                }
                continue;
            }

            // Rule 2: a bare token whose own stability is not stable.
            if (std.mem.indexOfAny(u8, part, "<>=!~^*") != null) continue;
            const v = constraint.parseVersion(part) orelse continue;
            const n = stabilityNumber(v.stability);
            if (n == 0) continue;
            if (best == null or n < best.?) best = n;
        }
    }

    return best;
}

/// Print the compatibility audit, and stop when it blocks.
///
/// Returns an exit code when the run must not continue, `null` to proceed.
pub fn reportCompat(
    allocator: std.mem.Allocator,
    root: manifest.Manifest,
    ignore_unsupported: bool,
) !?u8 {
    const report = try compat.audit(allocator, root);
    if (report.findings.len == 0) return null;

    prompt.blank();
    for (report.findings) |f| {
        const line = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ f.subject, f.detail });
        switch (f.severity) {
            .blocking => if (ignore_unsupported) prompt.warn(line) else prompt.err(line),
            .warning => prompt.warn(line),
        }
    }

    if (report.blocking() > 0 and !ignore_unsupported) {
        prompt.blank();
        prompt.note("Composer handles this project and this does not. Use `--ignore-unsupported` to proceed anyway, having read the above.");
        prompt.outro("refused — this project needs composer");
        return 1;
    }

    prompt.blank();
    return null;
}

// ── warming the whole closure, in waves ───────────────────────────────────────

const Warmed = struct { fetched: usize, waves: usize };

/// Fetch metadata for the transitive closure of `seeds`, a level at a time.
///
/// Each wave fetches every newly discovered name concurrently, then reads what
/// those packages require to find the next wave. It stops when a wave discovers
/// nothing new.
///
/// This deliberately over-fetches: it reads the requirements of EVERY version
/// of a package, not only the one the solver will pick, because which version
/// that is has not been decided yet. Fetching a package the resolution turns
/// out not to need costs one cached file; not having fetched the one it does
/// need costs a serial round trip in the middle of the search.
fn warmGraph(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    project: *ProjectPool,
    seeds: []const []const u8,
) !Warmed {
    var seen: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    for (seeds) |n| {
        if (solver.isPlatform(n) or util.contains(pending.items, n)) continue;
        try pending.append(allocator, n);
    }

    var fetched: usize = 0;
    var waves: usize = 0;
    const workers = fetch.workerCount(env);

    // A ceiling on the rounds, not on the work. A graph deep enough to exceed
    // it still resolves — the solver simply fetches the remainder itself, the
    // way it did before this existed.
    const max_waves = 12;

    while (pending.items.len > 0 and waves < max_waves) : (waves += 1) {
        fetched += packagist.warm(allocator, io, project.cache_dir, pending.items, project.meta, workers);

        var next: std.ArrayList([]const u8) = .empty;
        for (pending.items) |name| {
            try seen.append(allocator, name);

            // From the pool, so a name published by a vcs repository is read
            // from there and never looked for on packagist.
            const list = project.pool().candidates(allocator, name) catch continue;
            for (list) |c| {
                for (c.requires(allocator) catch continue) |dep| {
                    if (solver.isPlatform(dep.name)) continue;
                    if (util.contains(seen.items, dep.name)) continue;
                    if (util.contains(next.items, dep.name)) continue;
                    try next.append(allocator, dep.name);
                }
            }
        }

        pending = next;
    }

    return .{ .fetched = fetched, .waves = waves };
}
