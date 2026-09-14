//! `create-project`, `global`, `browse` and `self-update` — the four commands
//! that are about something other than the project in the current directory.
//!
//! ## `create-project`
//!
//! Resolve a package, unpack it as a project rather than as a dependency, and
//! install its dependencies. Two details are what separate it from "download
//! and unzip":
//!
//!   * the new project keeps NO `composer.lock` from the package archive unless
//!     the package shipped one deliberately — and if it did, it is honoured, so
//!     `create-project` of an application reproduces the versions its author
//!     tested;
//!   * `post-create-project-cmd` runs LAST, after the dependencies are in
//!     place, because that hook exists to generate a key or copy an `.env` and
//!     both need a working vendor tree.
//!
//! ## `global`
//!
//! Not a command of its own so much as a change of working directory: every
//! other command, run against `$COMPOSER_HOME` instead of here. That is the
//! whole of Composer's semantics for it, and modelling it as anything more
//! elaborate invents behaviour.
//!
//! ## `self-update`
//!
//! Says what it can and does not pretend to more. This package ships as the
//! standalone `ppkg` binary and inside `hkm`; either way the binary on disk was
//! put there by Homebrew, by an installer or release archive, or by a build from
//! source, and each of those has its own upgrade path that owns the file. A package manager that overwrites a binary
//! Homebrew believes it manages leaves the machine in a state neither tool can
//! reason about, so this reports the release it found and the command that
//! installs it, and stops there.

const std = @import("std");
const manifest = @import("manifest.zig");
const packagist = @import("packagist.zig");
const constraint = @import("constraint.zig");
const fetch = @import("fetch.zig");
const archive = @import("archive.zig");
const install_mod = @import("install.zig");
const resolve_mod = @import("resolve.zig");
const scripts_mod = @import("scripts.zig");
const layout = @import("layout.zig");
const auth = @import("auth.zig");
const util = @import("util.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    NoSuchPackage,
    NoMatchingVersion,
    TargetExists,
    NoDistribution,
};

// ── create-project ────────────────────────────────────────────────────────────

pub const CreateOptions = struct {
    /// A version constraint; empty means "the newest stable".
    constraint: []const u8 = "",
    /// Stop after unpacking — do not install dependencies.
    no_install: bool = false,
    dev: bool = true,
    /// The new project's `scripts`, handled exactly as `install` handles them.
    scripts: scripts_mod.Options = .{},
    /// Keep the package's own composer.lock, if it shipped one.
    prefer_lock: bool = true,
};

pub fn createProject(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    name: []const u8,
    target: []const u8,
    opts: CreateOptions,
) !u8 {
    prompt.intro("ppkg create-project");

    // A non-empty target is refused rather than merged into. Unpacking a
    // project over someone's working directory is not recoverable, and
    // "directory already exists" is a message they can act on.
    if (util.dirExists(Dir.cwd(), io, target) and !dirIsEmpty(io, target)) {
        prompt.err(try std.fmt.allocPrint(allocator, "{s} already exists and is not empty.", .{target}));
        return 1;
    }

    const cache_dir = try fetch.cacheRoot(allocator, env, ".");
    resolve_mod.useCredentials(allocator, io, env, ".");

    const candidates = packagist.versionsOf(allocator, io, cache_dir, name, .{}) catch {
        prompt.err(try std.fmt.allocPrint(allocator, "{s} could not be read from packagist.", .{name}));
        return 1;
    };
    if (candidates.len == 0) {
        prompt.err(try std.fmt.allocPrint(allocator, "{s} is not a package packagist knows.", .{name}));
        return 1;
    }

    const chosen = pick(allocator, candidates, opts.constraint) orelse {
        prompt.err(try std.fmt.allocPrint(
            allocator,
            "no release of {s} satisfies {s}.",
            .{ name, if (opts.constraint.len > 0) opts.constraint else "*" },
        ));
        return 1;
    };
    prompt.item("package", try std.fmt.allocPrint(allocator, "{s} {s}", .{ name, chosen.version }));

    const dist = distOf(chosen) orelse {
        prompt.err(try std.fmt.allocPrint(allocator, "{s} {s} publishes no downloadable archive.", .{ name, chosen.version }));
        return 1;
    };

    const got = fetch.intoCache(allocator, io, cache_dir, dist.url, dist.reference, dist.shasum) catch {
        prompt.err("the archive could not be downloaded.");
        return 1;
    };
    archive.unpackTo(allocator, io, got.path, target) catch {
        prompt.err("the archive could not be unpacked.");
        return 1;
    };
    prompt.item("unpacked into", target);

    // The package's own lock is a decision its author made about which versions
    // this application was tested against. Deleting it and re-resolving would
    // hand the user a different tree than the one the README describes.
    const lock_path = try std.fs.path.join(allocator, &.{ target, "composer.lock" });
    const has_lock = util.fileExists(io, lock_path);
    if (has_lock and !opts.prefer_lock) Dir.cwd().deleteFile(io, lock_path) catch {};

    if (opts.no_install) {
        prompt.outro("unpacked — dependencies not installed");
        return 0;
    }

    const absolute = try util.absPath(allocator, env, target);

    // With the author's lock, install from it and resolve nothing. Without one,
    // resolve first — and stop if that fails, rather than installing a tree
    // from a lock that was never written.
    if (!(has_lock and opts.prefer_lock)) {
        const resolved = try resolve_mod.command(allocator, io, env, absolute, .{
            .dev = opts.dev,
            .write = true,
            .scripts = opts.scripts,
        });
        if (resolved != 0) return resolved;
    }

    const code = try installFrom(allocator, io, env, absolute, opts);
    if (code != 0) return code;

    // LAST, and only now: the hook exists to generate a key or seed an `.env`,
    // and both need the dependencies it is being run beside.
    if (!opts.scripts.disabled) {
        const declared = (try manifest.read(allocator, io, absolute)) orelse manifest.Manifest{};
        const lay = try layout.resolve(allocator, env, absolute, declared);
        _ = try scripts_mod.run(allocator, io, env, lay, .post_create_project_cmd, opts.scripts);
    }

    prompt.outro(try std.fmt.allocPrint(allocator, "created {s}", .{target}));
    return 0;
}

fn installFrom(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    dir: []const u8,
    opts: CreateOptions,
) !u8 {
    const summary = try install_mod.run(allocator, io, env, dir, .{
        .dev = opts.dev,
        .scripts = opts.scripts,
    });
    return summary.exit_code;
}

/// The newest candidate the constraint accepts.
///
/// "Newest" by Composer's ordering, and STABLE unless the constraint asks for
/// something else — `create-project laravel/laravel` must not hand somebody a
/// dev branch because it sorted highest.
fn pick(
    allocator: std.mem.Allocator,
    candidates: []const packagist.Candidate,
    want: []const u8,
) ?packagist.Candidate {
    const c: ?constraint.Constraint = if (want.len > 0)
        constraint.parse(allocator, want) catch null
    else
        null;

    var best: ?packagist.Candidate = null;
    var best_version: constraint.Version = .{};
    for (candidates) |candidate| {
        const version = constraint.parseVersion(candidate.version_normalized) orelse continue;
        if (c) |parsed| {
            if (!parsed.accepts(candidate.version_normalized)) continue;
        } else if (version.stability != .stable or version.isBranch()) {
            continue;
        }
        if (best == null or version.order(best_version) == .gt) {
            best = candidate;
            best_version = version;
        }
    }
    return best;
}

const Dist = struct { url: []const u8, reference: []const u8, shasum: []const u8 };

fn distOf(candidate: packagist.Candidate) ?Dist {
    const raw = candidate.field("dist") orelse return null;
    if (raw != .object) return null;
    const url = stringAt(raw.object, "url") orelse return null;
    if (url.len == 0) return null;
    return .{
        .url = url,
        .reference = stringAt(raw.object, "reference") orelse candidate.version,
        .shasum = stringAt(raw.object, "shasum") orelse "",
    };
}

fn stringAt(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn dirIsEmpty(io: Io, path: []const u8) bool {
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var it = dir.iterate();
    return (it.next(io) catch null) == null;
}

// ── global ────────────────────────────────────────────────────────────────────

/// The directory `global` operates in, created if it is not there.
///
/// `$COMPOSER_HOME`, exactly as Composer resolves it, so a `global require`
/// here and a `composer global require` land in the same tree and can see each
/// other's packages.
pub fn globalDir(allocator: std.mem.Allocator, io: Io, env: *EnvMap) ?[]const u8 {
    const home = auth.composerHome(allocator, env) orelse return null;
    Dir.cwd().createDirPath(io, home) catch return null;

    // Composer creates a minimal manifest there on first use; without one every
    // command in that directory reports "no composer.json here", which is true
    // and unhelpful.
    const path = std.fs.path.join(allocator, &.{ home, "composer.json" }) catch return home;
    if (!util.fileExists(io, path)) {
        util.writeFileAtomic(io, path, "{\n}\n") catch {};
    }
    return home;
}

// ── browse ────────────────────────────────────────────────────────────────────

/// The URL `browse` would open for a package.
///
/// Composer prefers the homepage and falls back to the source URL; `--homepage`
/// forces the first and refuses rather than silently substituting the second,
/// because "open the homepage" and "open the repository" are different requests.
pub fn browseUrl(
    candidate_home: ?[]const u8,
    candidate_source: ?[]const u8,
    homepage_only: bool,
) ?[]const u8 {
    if (candidate_home) |h| {
        if (h.len > 0) return h;
    }
    if (homepage_only) return null;
    if (candidate_source) |s| {
        if (s.len > 0) return s;
    }
    return null;
}

// ── self-update ───────────────────────────────────────────────────────────────

pub const Installation = enum {
    homebrew,
    release_tarball,
    build_tree,
    unknown,

    /// The command that upgrades THIS installation of the executable at
    /// `exe_path` — the formula Homebrew knows it by is the file's own name.
    pub fn upgradeCommand(self: Installation, allocator: std.mem.Allocator, exe_path: []const u8) []const u8 {
        return switch (self) {
            .homebrew => std.fmt.allocPrint(allocator, "brew upgrade {s}", .{binaryName(exe_path)}) catch "brew upgrade",
            .release_tarball => "re-run the installer from the latest release",
            .build_tree => "git pull && zig build -Doptimize=ReleaseFast",
            .unknown => "reinstall from the latest release",
        };
    }
};

/// `/opt/homebrew/bin/ppkg` → `ppkg`; `C:\…\ppkg.exe` → `ppkg`.
fn binaryName(exe_path: []const u8) []const u8 {
    const base = std.fs.path.basename(exe_path);
    const name = if (std.mem.endsWith(u8, base, ".exe")) base[0 .. base.len - 4] else base;
    return if (name.len > 0) name else "ppkg";
}

/// Guess how the running binary got here, from its own path.
///
/// Path-shape inference is a guess, and it is labelled as one in the output.
/// It is still worth making: telling a Homebrew user to `git pull` is worse
/// than telling them nothing.
pub fn installationOf(exe_path: []const u8) Installation {
    if (std.mem.indexOf(u8, exe_path, "/Cellar/") != null) return .homebrew;
    if (std.mem.indexOf(u8, exe_path, "/homebrew/") != null) return .homebrew;
    if (std.mem.indexOf(u8, exe_path, "/linuxbrew/") != null) return .homebrew;
    if (std.mem.indexOf(u8, exe_path, "/zig-out/") != null) return .build_tree;
    if (std.mem.indexOf(u8, exe_path, "/lib/hkm-kernel/") != null) return .release_tarball;
    if (std.mem.indexOf(u8, exe_path, "/usr/local/bin/") != null) return .release_tarball;
    // Where install.sh puts a user-local install, of this tool or of hkm.
    if (std.mem.indexOf(u8, exe_path, "/.local/bin/") != null) return .release_tarball;
    return .unknown;
}

/// The newest release tag a GitHub repository publishes.
pub fn latestRelease(allocator: std.mem.Allocator, io: Io, repo: []const u8) ?[]const u8 {
    const url = std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{repo}) catch return null;
    const body = fetch.download(allocator, io, url) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    if (parsed != .object) return null;
    return stringAt(parsed.object, "tag_name");
}

/// Is `latest` newer than `current`?
///
/// Both are release tags, so a leading `v` is noise and the rest is a version.
/// A tag that does not parse is treated as NOT newer: offering an upgrade to
/// something unrecognisable is worse than staying quiet.
pub fn isNewer(current: []const u8, latest: []const u8) bool {
    const a = std.mem.trimStart(u8, current, "v");
    const b = std.mem.trimStart(u8, latest, "v");
    if (a.len == 0 or b.len == 0) return false;
    if (!std.ascii.isDigit(a[0]) or !std.ascii.isDigit(b[0])) return false;

    const have = constraint.parseVersion(a) orelse return false;
    const want = constraint.parseVersion(b) orelse return false;
    return want.order(have) == .gt;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an installation is guessed from the path the binary sits in" {
    try testing.expectEqual(Installation.homebrew, installationOf("/opt/homebrew/Cellar/hkm/1.14.0/bin/hkm"));
    try testing.expectEqual(Installation.build_tree, installationOf("/home/u/hkm-kernel/tools/zig-out/bin/hkm"));
    try testing.expectEqual(Installation.release_tarball, installationOf("/usr/local/bin/hkm"));
    try testing.expectEqual(Installation.unknown, installationOf("/somewhere/odd/hkm"));

    // And each one names a command that would actually work there.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("brew upgrade hkm", Installation.homebrew.upgradeCommand(a, "/opt/homebrew/Cellar/hkm/1.14.0/bin/hkm"));
    try testing.expectEqualStrings("brew upgrade ppkg", Installation.homebrew.upgradeCommand(a, "/opt/homebrew/bin/ppkg"));
    try testing.expectEqual(Installation.release_tarball, installationOf("/home/u/.local/bin/ppkg"));
}

test "only a newer release is offered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = a;
    try testing.expect(isNewer("1.14.0", "v1.15.0"));
    try testing.expect(isNewer("v1.14.0", "1.14.1"));
    try testing.expect(!isNewer("1.14.0", "v1.14.0"));
    try testing.expect(!isNewer("1.15.0", "v1.14.0"));

    // A tag that is not a version at all offers nothing, rather than offering
    // an "upgrade" to something unrecognisable.
    try testing.expect(!isNewer("1.14.0", "nightly"));
    try testing.expect(!isNewer("1.14.0", ""));
}

test "browse prefers the homepage and refuses to substitute when asked not to" {
    try testing.expectEqualStrings("https://example.test", browseUrl("https://example.test", "https://github.com/a/b", false).?);
    // No homepage: the source URL stands in — unless the caller asked for the
    // homepage specifically, which is a different question.
    try testing.expectEqualStrings("https://github.com/a/b", browseUrl(null, "https://github.com/a/b", false).?);
    try testing.expect(browseUrl(null, "https://github.com/a/b", true) == null);
    try testing.expect(browseUrl("", "", false) == null);
}
