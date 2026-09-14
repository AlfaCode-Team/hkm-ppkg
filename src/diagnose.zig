//! `diagnose` — is this machine able to do the work, and is this project in a
//! state where the work would mean anything.
//!
//! ## What this is for
//!
//! Every other command answers a question about a project. This one answers a
//! question about the SITUATION, and it exists because the failures it catches
//! are the ones that present as something else:
//!
//!   * no `git` on the PATH — every `vcs` repository "could not be read", which
//!     reads as a network problem;
//!   * an unwritable cache — every install re-downloads everything, silently,
//!     forever;
//!   * a `composer.lock` that does not match `composer.json` — `install`
//!     faithfully builds a tree for requirements that are no longer declared;
//!   * no credential for a declared private host — a 404 that reads as "no such
//!     package".
//!
//! Each of those is a one-line check. Together they are the difference between
//! a support conversation and a self-service answer.
//!
//! ## The rule about exit codes
//!
//! A FAILED check exits non-zero; a warning does not. `diagnose` is a thing CI
//! runs, and a check that turns a passing build red for "your php is 8.4 and
//! the project wants 8.2 or later" would be turned off within a week.

const std = @import("std");
const manifest = @import("manifest.zig");
const lockfile = @import("lock.zig");
const contenthash = @import("contenthash.zig");
const platform = @import("platform.zig");
const fetch = @import("fetch.zig");
const git = @import("git.zig");
const auth = @import("auth.zig");
const layout = @import("layout.zig");
const util = @import("util.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Level = enum { ok, warn, fail };

pub const Check = struct {
    name: []const u8,
    level: Level,
    detail: []const u8,
};

pub const Options = struct {
    /// Skip the one check that needs the network.
    offline: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    opts: Options,
) !u8 {
    prompt.intro("ppkg diagnose");

    var checks: std.ArrayList(Check) = .empty;

    try checks.append(allocator, gitCheck(allocator, io, env));
    try checks.append(allocator, phpCheck(allocator, io, env));

    const declared = try manifest.read(allocator, io, root_dir);
    try checks.append(allocator, manifestCheck(allocator, declared));

    // Only when the project actually declares one. Reporting a missing `hg` to
    // a project that has never mentioned Mercurial is noise, and noise is what
    // makes a diagnostic get skimmed.
    if (declared) |root| {
        if (declaresKind(root, .hg)) try checks.append(allocator, toolCheck(
            allocator,
            io,
            env,
            "hg",
            &.{ "hg", "--version" },
            "Mercurial",
            "this project declares an hg repository, and every package only it publishes will be missing from the resolve",
        ));
        if (declaresKind(root, .svn)) try checks.append(allocator, toolCheck(
            allocator,
            io,
            env,
            "svn",
            &.{ "svn", "--version", "--quiet" },
            "",
            "this project declares an svn repository, and every package only it publishes will be missing from the resolve",
        ));
    }

    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);
    try checks.append(allocator, cacheCheck(allocator, io, cache_dir));

    if (declared) |root| {
        try checks.append(allocator, try lockCheck(allocator, io, root_dir));
        try checks.append(allocator, try vendorCheck(allocator, io, env, root_dir, root));
        try checks.append(allocator, platformCheck(allocator, io, env, root));
        try checks.append(allocator, credentialCheck(allocator, io, env, root_dir, root));
    }

    if (!opts.offline) try checks.append(allocator, reachabilityCheck(allocator, io));

    var failed: usize = 0;
    var warned: usize = 0;
    for (checks.items) |c| {
        switch (c.level) {
            .ok => prompt.item(c.name, c.detail),
            .warn => {
                warned += 1;
                prompt.warn(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ c.name, c.detail }));
            },
            .fail => {
                failed += 1;
                prompt.err(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ c.name, c.detail }));
            },
        }
    }

    prompt.blank();
    if (failed > 0) {
        prompt.outro(try std.fmt.allocPrint(
            allocator,
            "{d} check{s} failed, {d} warning{s}",
            .{ failed, plural(failed), warned, plural(warned) },
        ));
        return 1;
    }
    // A warning is a thing to look at, not a thing to stop a build for.
    prompt.ok("Everything this command can check is in order.");
    prompt.outro(if (warned == 0)
        "healthy"
    else
        try std.fmt.allocPrint(allocator, "healthy — {d} warning{s}", .{ warned, plural(warned) }));
    return 0;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// ── the checks ────────────────────────────────────────────────────────────────

fn gitCheck(allocator: std.mem.Allocator, io: Io, env: *EnvMap) Check {
    const out = git.run(allocator, io, env, &.{ "git", "--version" }) catch {
        return .{
            .name = "git",
            .level = .fail,
            // Named precisely, because the symptom is a network-shaped error.
            .detail = "not on PATH. Every `vcs` repository will report as unreadable, and a source install cannot happen at all.",
        };
    };
    return .{ .name = "git", .level = .ok, .detail = std.mem.trim(u8, out, " \t\r\n") };
}

fn phpCheck(allocator: std.mem.Allocator, io: Io, env: *EnvMap) Check {
    const out = git.run(allocator, io, env, &.{ "php", "-r", "echo PHP_VERSION;" }) catch {
        return .{
            .name = "php",
            .level = .warn,
            // A warning, not a failure: installing and generating an autoloader
            // never runs PHP. Only `scripts`, `exec` and the platform check do.
            .detail = "not on PATH. Installing still works; `run-script`, `exec` and platform verification do not.",
        };
    };
    return .{ .name = "php", .level = .ok, .detail = std.mem.trim(u8, out, " \t\r\n") };
}

fn declaresKind(root: manifest.Manifest, kind: manifest.Repo.Kind) bool {
    for (root.repositories) |repo| {
        if (repo.kind == kind) return true;
    }
    return false;
}

/// Is a version-control tool this project needs actually here?
///
/// A FAILURE, not a warning: without it the repository is unreadable, and the
/// package it publishes silently falls through to whatever packagist has under
/// the same name — which is the exact outcome the whole compatibility gate
/// exists to prevent.
fn toolCheck(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    name: []const u8,
    argv: []const []const u8,
    expect: []const u8,
    consequence: []const u8,
) Check {
    const out = git.runTool(allocator, io, env, argv) catch {
        return .{
            .name = name,
            .level = .fail,
            .detail = std.fmt.allocPrint(allocator, "not on PATH — {s}.", .{consequence}) catch consequence,
        };
    };
    if (expect.len > 0 and std.mem.indexOf(u8, out, expect) == null) {
        return .{ .name = name, .level = .fail, .detail = "did not identify itself as expected." };
    }
    const line = std.mem.trim(u8, out, " \t\r\n");
    return .{
        .name = name,
        .level = .ok,
        .detail = if (line.len > 0) firstLine(line) else "present",
    };
}

fn firstLine(text: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0..nl];
}

fn manifestCheck(allocator: std.mem.Allocator, declared: ?manifest.Manifest) Check {
    const root = declared orelse return .{
        .name = "composer.json",
        .level = .fail,
        .detail = "missing or unparseable in this directory.",
    };
    if (root.name.len == 0) {
        return .{
            .name = "composer.json",
            .level = .warn,
            .detail = "has no \"name\". It installs, but it cannot be required by anything.",
        };
    }
    return .{
        .name = "composer.json",
        .level = .ok,
        .detail = allocator.dupe(u8, root.name) catch root.name,
    };
}

fn cacheCheck(allocator: std.mem.Allocator, io: Io, cache_dir: []const u8) Check {
    Dir.cwd().createDirPath(io, cache_dir) catch {
        return .{
            .name = "cache",
            .level = .warn,
            .detail = std.fmt.allocPrint(
                allocator,
                "{s} cannot be created. Every install will re-download everything.",
                .{cache_dir},
            ) catch cache_dir,
        };
    };

    // Writable, not merely present: a directory owned by root from a `sudo`
    // install is the case that produces an install which is slow forever and
    // never says why.
    const probe = std.fs.path.join(allocator, &.{ cache_dir, ".ppkg-write-probe" }) catch cache_dir;
    util.writeFileAtomic(io, probe, "") catch {
        return .{
            .name = "cache",
            .level = .warn,
            .detail = std.fmt.allocPrint(
                allocator,
                "{s} is not writable. Every install will re-download everything.",
                .{cache_dir},
            ) catch cache_dir,
        };
    };
    Dir.cwd().deleteFile(io, probe) catch {};

    return .{ .name = "cache", .level = .ok, .detail = cache_dir };
}

fn lockCheck(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !Check {
    const lock_path = try std.fs.path.join(allocator, &.{ root_dir, "composer.lock" });
    if (!util.fileExists(io, lock_path)) {
        return .{
            .name = "composer.lock",
            .level = .warn,
            .detail = "absent. `install` has nothing to build from; run `update` first.",
        };
    }

    const lock = try lockfile.read(allocator, io, root_dir);
    const json_path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const source = Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(8 * 1024 * 1024)) catch
        return .{ .name = "composer.lock", .level = .warn, .detail = "composer.json could not be re-read to compare." };

    const want = contenthash.of(allocator, source) catch
        return .{ .name = "composer.lock", .level = .warn, .detail = "composer.json could not be hashed to compare." };

    if (lock.content_hash.len > 0 and !std.mem.eql(u8, lock.content_hash, want)) {
        return .{
            .name = "composer.lock",
            .level = .warn,
            // Not a failure: an out-of-date lock still installs, and telling CI
            // to go red for it is a policy decision the project makes, not this
            // command.
            .detail = "is out of date with composer.json. `install` will build the OLD requirements; run `update`.",
        };
    }
    return .{
        .name = "composer.lock",
        .level = .ok,
        .detail = try std.fmt.allocPrint(allocator, "{d} packages, current with composer.json", .{lock.packages.len}),
    };
}

fn vendorCheck(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    root: manifest.Manifest,
) !Check {
    const lay = try layout.resolve(allocator, env, root_dir, root);
    const autoload_path = try std.fs.path.join(allocator, &.{ lay.vendor, "autoload.php" });

    if (!util.fileExists(io, autoload_path)) {
        return .{
            .name = "vendor",
            .level = .warn,
            .detail = try std.fmt.allocPrint(
                allocator,
                "{s} has no autoload.php. Nothing that requires it will boot.",
                .{lay.label(allocator, lay.vendor)},
            ),
        };
    }
    return .{ .name = "vendor", .level = .ok, .detail = lay.label(allocator, lay.vendor) };
}

fn platformCheck(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root: manifest.Manifest,
) Check {
    const present = platform.detect(allocator, io, env, "php", root.config_platform) catch
        return .{
            .name = "platform",
            .level = .warn,
            .detail = "could not be inspected — no usable php on PATH.",
        };

    var unmet: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    for (root.require) |dep| {
        if (!dep.isPlatform()) continue;
        switch (present.check(allocator, dep)) {
            // `unmodelled` means no interpreter answered — the php check above
            // has already reported that, and counting it again as an unmet
            // requirement would fail a machine nobody managed to inspect.
            .satisfied, .unmodelled, .ignored => continue,
            .missing, .conflict => {},
        }
        count += 1;
        if (count <= 4) {
            if (unmet.items.len > 0) unmet.appendSlice(allocator, ", ") catch {};
            unmet.appendSlice(allocator, dep.name) catch {};
        }
    }

    if (count == 0) return .{ .name = "platform", .level = .ok, .detail = "every declared php/ext requirement is met" };
    return .{
        .name = "platform",
        .level = .fail,
        .detail = std.fmt.allocPrint(allocator, "unmet: {s}{s}", .{
            unmet.items,
            if (count > 4) " (and more)" else "",
        }) catch "unmet platform requirements",
    };
}

fn credentialCheck(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    root: manifest.Manifest,
) Check {
    const store = auth.load(allocator, io, env, root_dir);

    // Only hosts this project actually declares. Reporting "no credential for
    // gitlab.com" to a project that has never mentioned gitlab is noise.
    var without: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    for (root.repositories) |repo| {
        if (repo.kind != .vcs and repo.kind != .composer) continue;
        const host = auth.hostOf(repo.url) orelse continue;
        if (std.ascii.eqlIgnoreCase(host, "packagist.org")) continue;
        if (store.forHost(host) != null) continue;
        count += 1;
        if (count <= 3) {
            if (without.items.len > 0) without.appendSlice(allocator, ", ") catch {};
            without.appendSlice(allocator, host) catch {};
        }
    }

    if (!store.hasAny() and count == 0) {
        return .{ .name = "credentials", .level = .ok, .detail = "none configured, and none of the declared repositories needs one" };
    }
    if (count > 0) {
        return .{
            .name = "credentials",
            .level = .warn,
            // A warning: a public repository on a private-capable host needs
            // nothing, and this cannot tell the two apart without asking.
            .detail = std.fmt.allocPrint(
                allocator,
                "no credential for {s}. If any of those is private, its packages will 404 and read as \"no such package\".",
                .{without.items},
            ) catch "some declared hosts have no credential",
        };
    }
    return .{
        .name = "credentials",
        .level = .ok,
        .detail = std.fmt.allocPrint(allocator, "{d} host{s} configured", .{
            store.credentials.len,
            plural(store.credentials.len),
        }) catch "configured",
    };
}

fn reachabilityCheck(allocator: std.mem.Allocator, io: Io) Check {
    const body = fetch.download(allocator, io, "https://repo.packagist.org/packages.json") catch {
        return .{
            .name = "packagist",
            .level = .warn,
            .detail = "unreachable. Resolution will fail; installing from a warm cache still works.",
        };
    };
    return .{
        .name = "packagist",
        .level = .ok,
        .detail = std.fmt.allocPrint(allocator, "reachable ({d} bytes)", .{body.len}) catch "reachable",
    };
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a missing manifest fails; a nameless one only warns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(Level.fail, manifestCheck(a, null).level);
    try testing.expectEqual(Level.warn, manifestCheck(a, .{}).level);
    try testing.expectEqual(Level.ok, manifestCheck(a, .{ .name = "acme/thing" }).level);
}

test "a cache directory that cannot be written is a warning, not a failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Under a path that cannot exist. A slow install is not a broken one, so
    // this must never turn a build red.
    const bad = cacheCheck(a, io, "/dev/null/not-a-directory");
    try testing.expectEqual(Level.warn, bad.level);
    try testing.expect(std.mem.indexOf(u8, bad.detail, "re-download") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const usable = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "cache" });
    try testing.expectEqual(Level.ok, cacheCheck(a, io, usable).level);
}
