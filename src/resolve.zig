//! `hkm pkg resolve` — run the solver against a project and report the result.
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
const lockfile = @import("lock.zig");
const fetch = @import("fetch.zig");
const prompt = @import("report.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// A pool that answers from local path repositories first, then Packagist.
const ProjectPool = struct {
    io: Io,
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    cache_dir: []const u8,
    locals: []const Local,
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

    const Local = struct { name: []const u8, dir: []const u8 };
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
        for (self.locals) |local| {
            if (!std.mem.eql(u8, local.name, name)) continue;
            return self.localCandidate(allocator, local);
        }
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
};

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

    prompt.intro("hkm pkg resolve");

    var locals: std.ArrayList(ProjectPool.Local) = .empty;
    for (root.repositories) |repo| {
        if (repo.kind != .path or repo.url.len == 0) continue;
        const dir = try std.fs.path.join(allocator, &.{ root_dir, repo.url });
        if (try manifest.read(allocator, io, dir)) |m| {
            if (m.name.len > 0) try locals.append(allocator, .{ .name = m.name, .dir = dir });
        }
    }
    if (locals.items.len > 0) {
        prompt.item("path repositories", try std.fmt.allocPrint(allocator, "{d} pinned from disk", .{locals.items.len}));
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

    var project: ProjectPool = .{
        .io = io,
        .allocator = allocator,
        .root_dir = root_dir,
        .cache_dir = try fetch.cacheRoot(allocator, env, root_dir),
        .locals = locals.items,
        .meta = .{ .dev = need_dev },
    };

    // Warm the metadata cache for everything this resolution is likely to
    // touch, in parallel, before the solver starts asking for packages one at
    // a time. The name list comes from the lock when there is one — it is the
    // best available guess at the closure — plus the root requirements.
    {
        var names: std.ArrayList([]const u8) = .empty;
        for (roots.items) |r| try names.append(allocator, r.name);
        if (lockfile.read(allocator, io, root_dir) catch null) |lock| {
            for (lock.packages) |p| {
                if (util.contains(names.items, p.name)) continue;
                try names.append(allocator, p.name);
            }
        }
        const warmed = packagist.warm(
            allocator,
            io,
            project.cache_dir,
            names.items,
            project.meta,
            fetch.workerCount(env),
        );
        if (warmed > 0) {
            prompt.item("metadata", try std.fmt.allocPrint(allocator, "{d} packages fetched concurrently", .{warmed}));
        }
    }

    const started = std.Io.Timestamp.now(io, .awake);
    const outcome = try solver.solve(allocator, project.pool(), roots.items, .{
        .minimum_stability = floor,
        .prefer_stable = root.prefer_stable,
        .with_dev = need_dev,
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
