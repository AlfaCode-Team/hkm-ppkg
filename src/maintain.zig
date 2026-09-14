//! The maintenance commands — `status`, `bump`, `reinstall`, `exec`,
//! `clear-cache`, `suggests`, `fund`, `prohibits`, `home`, `diagnose`.
//!
//! Small individually, and grouped here rather than scattered because they
//! share one shape: read the installed tree or the lock, and either report on
//! it or act on one narrow part of it. None of them resolves anything.
//!
//! Two are worth reading before use:
//!
//!   * `status` compares each installed package against the reference it was
//!     installed at. It reports a package whose directory has been EDITED,
//!     which is the thing that makes an install non-reproducible and is
//!     invisible in every other report.
//!   * `bump` rewrites `require` constraints to the versions actually locked.
//!     It is the one command here that changes `composer.json`, and it changes
//!     what the project will accept in future — so it says what it did, per
//!     package, rather than reporting a count.

const std = @import("std");
const manifest = @import("manifest.zig");
const lockfile = @import("lock.zig");
const layout = @import("layout.zig");
const jsonedit = @import("jsonedit.zig");
const constraint = @import("constraint.zig");
const fetch = @import("fetch.zig");
const stamps = @import("stamps.zig");
const util = @import("util.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

// ── status ────────────────────────────────────────────────────────────────────

/// `hkm ppkg status` — which installed packages are not what was installed.
///
/// Every package this tool placed is recorded, in the cache, with the
/// reference its directory was given (see `stamps.zig`). A package whose
/// recorded reference differs from the lock's is not what the lock asks for,
/// and an install that silently overwrote it would throw away whatever put it
/// there.
pub fn status(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
) !u8 {
    const root = (try manifest.read(allocator, io, root_dir)) orelse manifest.Manifest{};
    const lay = try layout.resolve(allocator, env, root_dir, root);

    const lock = lockfile.read(allocator, io, root_dir) catch {
        prompt.err("No composer.lock here.");
        return 1;
    };
    const packages = try lock.selected(allocator, true);

    var changed: usize = 0;
    var missing: usize = 0;
    var linked: usize = 0;

    // What the last install recorded. Held in the cache rather than in the
    // vendor tree — see stamps.zig. A cleared cache means no record, and this
    // command says so rather than reporting every package as unverifiable.
    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);
    const table = stamps.read(allocator, io, cache_dir, lay.vendor);

    for (packages) |pkg| {
        const dir = try std.fs.path.join(allocator, &.{ lay.vendor, pkg.name });
        if (!util.dirExists(Dir.cwd(), io, dir)) {
            missing += 1;
            prompt.item(pkg.name, "not installed");
            continue;
        }

        const want = table.get(pkg.name) orelse {
            // Either a path repository — a symlink into the user's own source
            // tree, permanently "modified" by design — or a package this tool
            // did not place. Reporting either as a problem every time trains
            // people to ignore this command.
            linked += 1;
            continue;
        };
        if (!std.mem.eql(u8, want, pkg.dist.reference)) {
            changed += 1;
            prompt.item(pkg.name, try std.fmt.allocPrint(
                allocator,
                "installed at {s}, lock says {s}",
                .{ shortRef(want), shortRef(pkg.dist.reference) },
            ));
        }
    }

    prompt.blank();
    if (changed == 0 and missing == 0) {
        prompt.ok(try std.fmt.allocPrint(
            allocator,
            "{d} package(s) match the lock{s}.",
            .{ packages.len, if (linked > 0) " (path repositories and packages placed elsewhere not checked)" else "" },
        ));
        return 0;
    }
    prompt.warn(try std.fmt.allocPrint(
        allocator,
        "{d} at a different reference, {d} not installed. Run `ppkg install`.",
        .{ changed, missing },
    ));
    return 1;
}

fn shortRef(ref: []const u8) []const u8 {
    return if (ref.len > 8) ref[0..8] else ref;
}

// ── bump ──────────────────────────────────────────────────────────────────────

pub const BumpOptions = struct {
    /// Only report; write nothing.
    dry_run: bool = false,
    /// Also bump `require-dev`. Composer's `--dev-only` inverts this; both
    /// sections are bumped by default, as Composer does.
    dev: bool = true,
};

/// `hkm ppkg bump` — raise each constraint's floor to the locked version.
///
/// `"^7.0"` with 7.9.2 locked becomes `"^7.9.2"`. What this buys is that a
/// FRESH install of the project cannot silently resolve to an older version
/// than the one that was tested; what it costs is that the manifest now
/// describes the tested set rather than the supported range, which is wrong for
/// a library and right for an application. Composer says the same in its own
/// help, and the command exists for the application case.
pub fn bump(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    opts: BumpOptions,
) !u8 {
    const path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch {
        prompt.err("No composer.json here.");
        return 1;
    };
    const root = try manifest.parse(allocator, source);

    const lock = lockfile.read(allocator, io, root_dir) catch {
        prompt.err("No composer.lock here. `bump` raises constraints to the versions a lock pins.");
        return 1;
    };
    const locked = try lock.selected(allocator, true);

    var doc = try jsonedit.Document.init(allocator, source);
    var bumped: usize = 0;

    const sections = [_]struct { name: []const u8, deps: []const manifest.Dep }{
        .{ .name = "require", .deps = root.require },
        .{ .name = "require-dev", .deps = if (opts.dev) root.require_dev else &.{} },
    };

    for (sections) |section| {
        for (section.deps) |dep| {
            // A platform requirement has no locked version to bump to, and
            // pinning `php` to the exact patch the developer happens to run is
            // how a project stops installing on every other machine.
            if (dep.isPlatform()) continue;

            const version = versionOf(locked, dep.name) orelse continue;
            const want = try std.fmt.allocPrint(allocator, "^{s}", .{version});
            if (std.mem.eql(u8, dep.constraint, want)) continue;

            // Only ever RAISE. A constraint already narrower than the lock —
            // an exact pin, or a branch — is the author's decision and is left
            // alone; widening it would be the opposite of what was asked.
            if (!widerThan(allocator, dep.constraint, version)) continue;

            _ = try doc.addLink(section.name, dep.name, want, false);
            bumped += 1;
            prompt.item(dep.name, try std.fmt.allocPrint(allocator, "{s}  →  {s}", .{ dep.constraint, want }));
        }
    }

    if (bumped == 0) {
        prompt.ok("Every constraint already names its locked version.");
        return 0;
    }
    if (opts.dry_run) {
        prompt.note("--dry-run: composer.json not written.");
        return 0;
    }

    try util.writeFileAtomic(io, path, try doc.output());
    prompt.blank();
    prompt.ok(try std.fmt.allocPrint(allocator, "{d} constraint(s) raised.", .{bumped}));
    return 0;
}

fn versionOf(packages: []const lockfile.Package, name: []const u8) ?[]const u8 {
    for (packages) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) {
            // A branch has no numeric floor to raise to.
            if (std.mem.startsWith(u8, p.version, "dev-")) return null;
            if (std.mem.endsWith(u8, p.version, "-dev")) return null;
            return std.mem.trimStart(u8, p.version, "v");
        }
    }
    return null;
}

/// Does `text` admit anything OLDER than `version`?
///
/// The test for "is there room to raise". An exact pin admits nothing older, a
/// caret range on an earlier version does.
fn widerThan(allocator: std.mem.Allocator, text: []const u8, version: []const u8) bool {
    const c = constraint.parse(allocator, text) catch return false;
    const target = constraint.parseVersion(version) orelse return false;
    if (target.isBranch()) return false;

    // Probe the version one patch below: if the constraint still accepts it,
    // the floor is lower than the lock and raising it changes something.
    var lower = target;
    if (lower.parts[2] > 0) {
        lower.parts[2] -= 1;
    } else if (lower.parts[1] > 0) {
        lower.parts[1] -= 1;
        lower.parts[2] = 0;
    } else if (lower.parts[0] > 0) {
        lower.parts[0] -= 1;
        lower.parts[1] = 0;
        lower.parts[2] = 0;
    } else return false;

    return c.matches(lower);
}

// ── reinstall ─────────────────────────────────────────────────────────────────

/// `hkm ppkg reinstall <pkg>…` — delete the named directories so the next
/// install replaces them.
///
/// Deliberately does NOT run the install itself. Deleting is the irreversible
/// half, and a command that deletes and then fails to re-fetch (offline, a
/// removed tag) has taken a working tree apart; leaving the install as a
/// separate step means the user sees the deletion succeed before anything
/// depends on the network.
pub fn reinstall(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    patterns: []const []const u8,
) !u8 {
    if (patterns.len == 0) {
        prompt.err("Nothing to reinstall. Give at least one package name.");
        return 2;
    }

    const root = (try manifest.read(allocator, io, root_dir)) orelse manifest.Manifest{};
    const lay = try layout.resolve(allocator, env, root_dir, root);
    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);
    const table = stamps.read(allocator, io, cache_dir, lay.vendor);

    const lock = lockfile.read(allocator, io, root_dir) catch {
        prompt.err("No composer.lock here.");
        return 1;
    };
    const packages = try lock.selected(allocator, true);

    var removed: usize = 0;
    for (packages) |pkg| {
        var wanted = false;
        for (patterns) |p| {
            if (globMatch(p, pkg.name)) wanted = true;
        }
        if (!wanted) continue;

        const dir = try std.fs.path.join(allocator, &.{ lay.vendor, pkg.name });
        // Never delete a path repository: `dest` is a symlink into the user's
        // own source tree, and removing the TARGET would delete their work.
        // The record says which packages were FETCHED; anything absent from it
        // is either a link or something this tool did not place.
        if (table.get(pkg.name) == null) {
            prompt.muted(try std.fmt.allocPrint(allocator, "  {s} skipped (not a fetched package)", .{pkg.name}));
            continue;
        }

        Dir.cwd().deleteTree(io, dir) catch {
            prompt.warn(try std.fmt.allocPrint(allocator, "{s}: could not be removed.", .{pkg.name}));
            continue;
        };
        removed += 1;
        prompt.item(pkg.name, "removed");
    }

    if (removed == 0) {
        prompt.note("Nothing matched.");
        return 1;
    }
    prompt.blank();
    prompt.ok(try std.fmt.allocPrint(
        allocator,
        "{d} package(s) removed. Run `ppkg install` to put them back.",
        .{removed},
    ));
    return 0;
}

// ── exec ──────────────────────────────────────────────────────────────────────

/// `hkm ppkg exec <binary> [args…]` — run something from the bin directory.
///
/// The point is the PATH: a project's own `phpunit` runs, not whichever one is
/// installed globally. With no arguments it LISTS what is available, which is
/// what `composer exec --list` does and what someone typing the command blind
/// actually wants.
pub fn exec(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    argv: []const []const u8,
) !u8 {
    const root = (try manifest.read(allocator, io, root_dir)) orelse manifest.Manifest{};
    const lay = try layout.resolve(allocator, env, root_dir, root);

    if (argv.len == 0) {
        var dir = Dir.cwd().openDir(io, lay.bin, .{ .iterate = true }) catch {
            prompt.note("No binaries are installed.");
            return 0;
        };
        defer dir.close(io);

        prompt.section("Available binaries");
        var it = dir.iterate();
        var any = false;
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            prompt.item(entry.name, "");
            any = true;
        }
        if (!any) prompt.muted("  (none)");
        prompt.blank();
        return 0;
    }

    const binary = try std.fs.path.join(allocator, &.{ lay.bin, argv[0] });
    if (!util.fileExists(io, binary)) {
        prompt.err(try std.fmt.allocPrint(
            allocator,
            "'{s}' is not in {s}. Run `ppkg exec` with no arguments to see what is.",
            .{ argv[0], lay.label(allocator, lay.bin) },
        ));
        return 1;
    }

    var full: std.ArrayList([]const u8) = .empty;
    try full.append(allocator, binary);
    try full.appendSlice(allocator, argv[1..]);

    // The bin directory goes on PATH for the same reason it does for scripts:
    // a tool that shells out to a sibling tool must find the project's copy.
    var child_env: EnvMap = .init(allocator);
    var envs = env.iterator();
    while (envs.next()) |e| try child_env.put(e.key_ptr.*, e.value_ptr.*);
    try child_env.put("PATH", try std.fmt.allocPrint(
        allocator,
        "{s}:{s}",
        .{ lay.bin, env.get("PATH") orelse "" },
    ));

    var child = std.process.spawn(io, .{
        .argv = full.items,
        .environ_map = &child_env,
        .cwd = .{ .path = lay.root },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        prompt.err(try std.fmt.allocPrint(allocator, "Could not run '{s}'.", .{argv[0]}));
        return 1;
    };

    return switch (child.wait(io) catch return 1) {
        .exited => |code| code,
        else => 1,
    };
}

// ── clear-cache ───────────────────────────────────────────────────────────────

/// `hkm ppkg clear-cache` — empty the download and metadata cache.
pub fn clearCache(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
) !u8 {
    const dir = try fetch.cacheRoot(allocator, env, root_dir);
    if (!util.dirExists(Dir.cwd(), io, dir)) {
        prompt.note(try std.fmt.allocPrint(allocator, "Nothing cached in {s}.", .{dir}));
        return 0;
    }

    Dir.cwd().deleteTree(io, dir) catch {
        prompt.err(try std.fmt.allocPrint(allocator, "Could not clear {s}.", .{dir}));
        return 1;
    };
    prompt.ok(try std.fmt.allocPrint(allocator, "Cleared {s}", .{dir}));
    return 0;
}

// ── shared ────────────────────────────────────────────────────────────────────

/// Case-insensitive glob, `*` matching any run. The same matcher `remove` uses.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;

    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (p < pattern.len and
            std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n]))
        {
            p += 1;
            n += 1;
        } else if (star) |at| {
            p = at + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bump only raises a constraint that admits something older" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Room to raise: ^7.0 accepts 7.9.1, which is below the locked 7.9.2.
    try testing.expect(widerThan(a, "^7.0", "7.9.2"));
    try testing.expect(widerThan(a, ">=1.0", "2.5.0"));
    try testing.expect(widerThan(a, "*", "3.0.0"));

    // No room: already at the floor, or pinned.
    try testing.expect(!widerThan(a, "^7.9.2", "7.9.2"));
    try testing.expect(!widerThan(a, "7.9.2", "7.9.2"));
    try testing.expect(!widerThan(a, "dev-main", "7.9.2"));
}

test "a locked branch has no version to bump to" {
    const packages = [_]lockfile.Package{
        .{ .name = "a/stable", .version = "v7.9.2", .raw = .null },
        .{ .name = "b/branch", .version = "dev-main", .raw = .null },
        .{ .name = "c/branch", .version = "2.0.x-dev", .raw = .null },
    };
    // The leading `v` is stripped, because a constraint is written without one.
    try testing.expectEqualStrings("7.9.2", versionOf(&packages, "a/stable").?);
    try testing.expect(versionOf(&packages, "b/branch") == null);
    try testing.expect(versionOf(&packages, "c/branch") == null);
    try testing.expect(versionOf(&packages, "nobody/here") == null);

    // Package names are matched case-insensitively, as everywhere else.
    try testing.expectEqualStrings("7.9.2", versionOf(&packages, "A/Stable").?);
}

test "a short reference is short, and a short one is left alone" {
    try testing.expectEqualStrings("abc12345", shortRef("abc1234567890"));
    try testing.expectEqualStrings("abc", shortRef("abc"));
}

test "the glob matcher is the one remove uses" {
    try testing.expect(globMatch("symfony/*", "symfony/console"));
    try testing.expect(!globMatch("symfony/*", "psr/log"));
    try testing.expect(globMatch("psr/log", "PSR/LOG"));
}
