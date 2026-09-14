//! `require` and `remove` — changing what a project depends on.
//!
//! The two commands that made this a package manager rather than a very fast
//! installer. Everything before them could only act on requirements someone
//! else had written down.
//!
//! Both follow Composer's shape, and the ORDER is the part that matters:
//!
//!   1. edit `composer.json` (in place — see `jsonedit.zig`)
//!   2. re-resolve and write `composer.lock`
//!   3. install
//!
//! and if step 2 or 3 fails, step 1 is UNDONE. A failed `require` that leaves a
//! package in the manifest but not in the lock has moved the project into a
//! state neither `install` nor `update` can explain, and the person who ran it
//! has no reason to suspect the manifest was touched at all.

const std = @import("std");
const manifest = @import("manifest.zig");
const jsonedit = @import("jsonedit.zig");
const packagist = @import("packagist.zig");
const constraint = @import("constraint.zig");
const resolve = @import("resolve.zig");
const install = @import("install.zig");
const fetch = @import("fetch.zig");
const platform = @import("platform.zig");
const util = @import("util.zig");
const scripts_mod = @import("scripts.zig");
const platform_mod = @import("platform.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// One `vendor/package` or `vendor/package:^1.2` from the command line.
pub const Spec = struct {
    name: []const u8,
    /// Absent means "work out the best available and write that down".
    constraint: ?[]const u8 = null,

    /// Split an argument on the LAST `:`, so a name is never mistaken for a
    /// constraint and a constraint containing a colon is still reachable.
    ///
    /// Composer also accepts `name=constraint` and a bare `name` followed by a
    /// separate constraint argument; both are handled by the caller, which is
    /// the only place that can see argument order.
    pub fn parse(arg: []const u8) Spec {
        if (std.mem.lastIndexOfScalar(u8, arg, ':')) |at| {
            // `php:^8.1` splits; `https://…` would not be a package name.
            if (at > 0 and at + 1 < arg.len) {
                return .{ .name = arg[0..at], .constraint = arg[at + 1 ..] };
            }
        }
        if (std.mem.lastIndexOfScalar(u8, arg, '=')) |at| {
            if (at > 0 and at + 1 < arg.len) {
                return .{ .name = arg[0..at], .constraint = arg[at + 1 ..] };
            }
        }
        return .{ .name = arg };
    }
};

pub const Options = struct {
    /// Write to `require-dev` rather than `require`.
    dev: bool = false,
    /// Edit the manifest and stop — no resolution, no install.
    no_update: bool = false,
    /// Resolve and lock, but do not place anything in the vendor tree.
    no_install: bool = false,
    /// Say what would happen and touch nothing, manifest included.
    dry_run: bool = false,
    /// `config.sort-packages`, or an explicit override.
    sort: ?bool = null,
    /// Passed straight through to the resolver.
    ignore_unsupported: bool = false,
    refresh: bool = false,
    optimize: bool = false,
    /// `--fixed` — write the exact version as the constraint (`1.2.3`) rather
    /// than a caret range.
    ///
    /// For a package a project pins deliberately: a `^` range invites the next
    /// update to move it, which is the opposite of what pinning means.
    fixed: bool = false,
    /// `-W` — let the resolution move the new package's dependencies too.
    with_all_dependencies: bool = false,
    /// `-w` — the same, except for packages the root requires directly.
    with_dependencies: bool = false,
    /// `--update-no-dev` — resolve and install without the dev requirements,
    /// even when adding to `require-dev`.
    update_no_dev: bool = false,
    prefer_lowest: bool = false,
    prefer_stable: bool = false,
    /// `--ignore-platform-req` — platform requirements not to enforce.
    ignore_platform: platform_mod.Ignore = .{},
    /// The ROOT package's `scripts`, passed to the update and install this
    /// command runs on the user's behalf.
    scripts: scripts_mod.Options = .{},
};

/// `hkm ppkg require <spec>…`
pub fn require(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    specs: []const Spec,
    opts: Options,
) !u8 {
    if (specs.len == 0) {
        prompt.err("Nothing to require. Give at least one package name.");
        return 2;
    }

    const path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const before = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch {
        prompt.err("No composer.json here.");
        return 1;
    };

    const root = manifest.parse(allocator, before) catch {
        prompt.err("composer.json is not valid JSON; refusing to edit it.");
        return 1;
    };

    const section: []const u8 = if (opts.dev) "require-dev" else "require";
    const sort = opts.sort orelse sortPackages(before);

    var doc = jsonedit.Document.init(allocator, before) catch {
        prompt.err("composer.json is not a JSON object.");
        return 1;
    };

    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);

    for (specs) |spec| {
        const chosen = spec.constraint orelse blk: {
            const best = bestConstraint(allocator, io, cache_dir, spec.name, root, opts.fixed) catch |e| {
                prompt.err(try std.fmt.allocPrint(
                    allocator,
                    "Could not find a version of '{s}' to require ({s}). Give one explicitly: {s}:^1.0",
                    .{ spec.name, @errorName(e), spec.name },
                ));
                return 1;
            };
            break :blk best;
        };

        if (!try doc.addLink(section, spec.name, chosen, sort)) {
            prompt.err(try std.fmt.allocPrint(
                allocator,
                "Could not add '{s}' to {s} — the section is not an object.",
                .{ spec.name, section },
            ));
            return 1;
        }
        prompt.item(spec.name, try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ chosen, if (spec.constraint == null) "  (chosen)" else "" },
        ));
    }

    const after = try doc.output();
    if (opts.dry_run) {
        prompt.note("--dry-run: composer.json not written.");
        return 0;
    }

    try util.writeFileAtomic(io, path, after);
    var touched: std.ArrayList([]const u8) = .empty;
    for (specs) |spec| try touched.append(allocator, spec.name);
    return try settle(allocator, io, env, root_dir, path, before, touched.items, opts);
}

/// `hkm ppkg remove <name>…`
pub fn remove(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    names: []const []const u8,
    opts: Options,
) !u8 {
    if (names.len == 0) {
        prompt.err("Nothing to remove. Give at least one package name.");
        return 2;
    }

    const path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const before = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch {
        prompt.err("No composer.json here.");
        return 1;
    };

    var doc = jsonedit.Document.init(allocator, before) catch {
        prompt.err("composer.json is not a JSON object.");
        return 1;
    };

    const section: []const u8 = if (opts.dev) "require-dev" else "require";
    const other: []const u8 = if (opts.dev) "require" else "require-dev";

    var removed: usize = 0;
    for (names) |pattern| {
        // `symfony/*` removes everything matching, which Composer supports
        // through `BasePackage::packageNameToRegexp`.
        const here = try matching(allocator, doc, section, pattern);
        for (here) |name| {
            _ = try doc.removeLink(section, name);
            removed += 1;
            prompt.item(name, try std.fmt.allocPrint(allocator, "removed from {s}", .{section}));
        }
        if (here.len > 0) continue;

        // Present, but in the section the user did NOT name. Composer warns and
        // leaves it alone unless a human confirms; with no human to ask, saying
        // so and stopping is the only answer that cannot delete the wrong
        // thing. The message names the flag rather than describing it.
        const elsewhere = try matching(allocator, doc, other, pattern);
        if (elsewhere.len > 0) {
            for (elsewhere) |name| {
                prompt.warn(try std.fmt.allocPrint(
                    allocator,
                    "{s} is in {s}, not {s}. Re-run with {s} to remove it.",
                    .{ name, other, section, if (opts.dev) "no --dev" else "--dev" },
                ));
            }
            continue;
        }

        prompt.muted(try std.fmt.allocPrint(allocator, "  {s} is not required; nothing to do.", .{pattern}));
    }

    if (removed == 0) return 0;

    const after = try doc.output();
    if (opts.dry_run) {
        prompt.note("--dry-run: composer.json not written.");
        return 0;
    }

    try util.writeFileAtomic(io, path, after);
    return try settle(allocator, io, env, root_dir, path, before, &.{}, opts);
}

/// Re-lock and install, restoring the manifest if either step fails.
///
/// `touched` are the packages this edit named. They become the resolution's
/// allow-list, because `require` is a PARTIAL update in Composer and always
/// has been: adding one package must not silently bump the other forty. A
/// removal passes none, since taking a package out can only free constraints.
fn settle(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    path: []const u8,
    before: []const u8,
    touched: []const []const u8,
    opts: Options,
) !u8 {
    if (opts.no_update) {
        prompt.note("--no-update: composer.json written; composer.lock is now stale.");
        return 0;
    }

    const code = resolve.command(allocator, io, env, root_dir, .{
        .write = true,
        .refresh = opts.refresh,
        .ignore_unsupported = opts.ignore_unsupported,
        .scripts = opts.scripts,
        .dev = !opts.update_no_dev,
        .only = touched,
        .with_dependencies = opts.with_dependencies,
        .with_all_dependencies = opts.with_all_dependencies,
        .prefer_lowest = opts.prefer_lowest,
        .prefer_stable = opts.prefer_stable,
        .ignore_platform = opts.ignore_platform,
    }) catch |e| {
        try revert(io, path, before);
        return err(allocator, "resolution failed", e);
    };
    if (code != 0) {
        try revert(io, path, before);
        prompt.err("Resolution failed; composer.json has been restored.");
        return code;
    }

    if (opts.no_install) return 0;

    const summary = install.run(allocator, io, env, root_dir, .{
        .optimize = opts.optimize,
        .ignore_unsupported = opts.ignore_unsupported,
        .scripts = opts.scripts,
        .dev = !opts.update_no_dev,
        .ignore_platform = opts.ignore_platform,
    }) catch |e| {
        // The lock is already written and correct at this point, so the
        // manifest is NOT reverted: reverting it would put the two out of
        // agreement, which is worse than a vendor tree that is one `install`
        // behind.
        return err(allocator, "install failed", e);
    };
    return summary.exit_code;
}

fn revert(io: Io, path: []const u8, before: []const u8) !void {
    try util.writeFileAtomic(io, path, before);
}

fn err(allocator: std.mem.Allocator, what: []const u8, e: anyerror) u8 {
    prompt.err(std.fmt.allocPrint(allocator, "{s}: {s}", .{ what, @errorName(e) }) catch what);
    return 1;
}

/// The names in `section` that `pattern` selects — an exact match, or every
/// match when the pattern contains `*`.
fn matching(
    allocator: std.mem.Allocator,
    doc: jsonedit.Document,
    section: []const u8,
    pattern: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    const value = doc.decode() catch return out.toOwnedSlice(allocator);
    if (value != .object) return out.toOwnedSlice(allocator);
    const s = value.object.get(section) orelse return out.toOwnedSlice(allocator);
    if (s != .object) return out.toOwnedSlice(allocator);

    var it = s.object.iterator();
    while (it.next()) |e| {
        if (globMatch(pattern, e.key_ptr.*)) try out.append(allocator, e.key_ptr.*);
    }
    return out.toOwnedSlice(allocator);
}

/// Case-insensitive glob where `*` matches any run of characters.
///
/// Iterative rather than recursive: the pattern comes from the command line,
/// and a recursive matcher on `*a*a*a*a*b` is a stack the user controls.
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

/// `config.sort-packages`, read straight from the raw text so that reading it
/// cannot disagree with the manifest the edit is about to be applied to.
fn sortPackages(source: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), source, .{}) catch return false;
    if (parsed != .object) return false;
    const config = parsed.object.get("config") orelse return false;
    if (config != .object) return false;
    const v = config.object.get("sort-packages") orelse return false;
    return v == .bool and v.bool;
}

// ── choosing a constraint ─────────────────────────────────────────────────────

pub const SelectError = error{ NoStableVersion, Unresolvable };

/// The constraint to write down when the user did not give one.
///
/// `Composer\Package\Version\VersionSelector::findRecommendedRequireVersion`:
/// take the best version the project's stability floor admits, then loosen it to
/// a caret range on major.minor — `7.9.3` becomes `^7.9`, and `0.9.3` becomes
/// `^0.9.3`, because in 0.x the MINOR is the breaking-change position.
pub fn bestConstraint(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    name: []const u8,
    root: manifest.Manifest,
    /// `--fixed` — write the exact version instead of loosening it.
    fixed: bool,
) ![]const u8 {
    // A platform requirement has no packagist metadata to consult. Composer
    // answers `*` for an extension already matching the running PHP; the honest
    // general answer here is `*`, and the user can be more specific.
    if ((manifest.Dep{ .name = name, .constraint = "" }).isPlatform()) return "*";

    const floor = constraint.stabilityFromName(root.minimum_stability);
    const candidates = try packagist.versionsOf(allocator, io, cache_dir, name, .{
        .dev = @intFromEnum(floor) < @intFromEnum(constraint.Stability.stable),
    });

    var best: ?constraint.Version = null;
    var best_pretty: []const u8 = "";
    for (candidates) |c| {
        const v = constraint.parseVersion(c.version_normalized) orelse continue;
        // A branch cannot be loosened into a caret range, and recommending
        // `dev-main` to someone who typed a package name is not what they meant.
        if (v.isBranch()) continue;
        if (@intFromEnum(v.stability) < @intFromEnum(floor)) continue;
        if (best == null or v.order(best.?) == .gt) {
            best = v;
            best_pretty = c.version;
        }
    }

    const chosen = best orelse return SelectError.NoStableVersion;
    // `--fixed` writes what was chosen, verbatim. Loosening it to a range is
    // the opposite of what pinning a package means.
    if (fixed) return allocator.dupe(u8, best_pretty);
    return transform(allocator, chosen, best_pretty);
}

/// `VersionSelector::transformVersion`, on an already-parsed version.
fn transform(allocator: std.mem.Allocator, v: constraint.Version, pretty: []const u8) ![]const u8 {
    const base = if (v.parts[0] == 0)
        // 0.x: keep the patch, because 0.9.3 → 0.10.0 is a breaking change and
        // `^0.9` would not admit it anyway — but `^0.9.3` says so explicitly.
        try std.fmt.allocPrint(allocator, "0.{d}.{d}", .{ v.parts[1], v.parts[2] })
    else
        try std.fmt.allocPrint(allocator, "{d}.{d}", .{ v.parts[0], v.parts[1] });

    if (v.stability == .stable) return std.fmt.allocPrint(allocator, "^{s}", .{base});
    _ = pretty;
    return std.fmt.allocPrint(allocator, "^{s}@{s}", .{ base, @tagName(v.stability) });
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a spec splits on the last colon or equals" {
    try testing.expectEqualStrings("psr/log", Spec.parse("psr/log").name);
    try testing.expect(Spec.parse("psr/log").constraint == null);

    const pinned = Spec.parse("psr/log:^3.0");
    try testing.expectEqualStrings("psr/log", pinned.name);
    try testing.expectEqualStrings("^3.0", pinned.constraint.?);

    const equals = Spec.parse("psr/log=^3.0");
    try testing.expectEqualStrings("psr/log", equals.name);
    try testing.expectEqualStrings("^3.0", equals.constraint.?);

    // A constraint that itself contains a colon still parses, because the split
    // is on the LAST one.
    const odd = Spec.parse("acme/pkg:dev-main");
    try testing.expectEqualStrings("acme/pkg", odd.name);
    try testing.expectEqualStrings("dev-main", odd.constraint.?);
}

test "the recommended constraint keeps the patch in 0.x and drops it above" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("^7.9", try transform(a, constraint.parseVersion("7.9.3.0").?, "7.9.3"));
    try testing.expectEqualStrings("^0.9.3", try transform(a, constraint.parseVersion("0.9.3.0").?, "0.9.3"));
    try testing.expectEqualStrings("^1.0", try transform(a, constraint.parseVersion("1.0.0.0").?, "1.0.0"));
}

test "an unstable best version carries its stability flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const beta = constraint.parseVersion("2.1.0.0-beta2").?;
    try testing.expectEqualStrings("^2.1@beta", try transform(a, beta, "2.1.0-beta2"));
}

test "a glob selects several packages, an exact name selects one" {
    try testing.expect(globMatch("symfony/*", "symfony/console"));
    try testing.expect(!globMatch("symfony/*", "psr/log"));
    try testing.expect(globMatch("psr/log", "psr/log"));
    try testing.expect(globMatch("PSR/LOG", "psr/log"));
    try testing.expect(!globMatch("psr/log", "psr/log-implementation"));
    try testing.expect(globMatch("*", "anything/at-all"));
    try testing.expect(globMatch("*/*fill*", "symfony/polyfill-mbstring"));
    // The pathological pattern a recursive matcher would blow the stack on.
    try testing.expect(!globMatch("*a*a*a*a*a*a*a*a*b", "a" ** 64));
}

test "sort-packages is read from the manifest text" {
    try testing.expect(sortPackages(
        \\{"config": {"sort-packages": true}}
    ));
    try testing.expect(!sortPackages(
        \\{"config": {"sort-packages": false}}
    ));
    try testing.expect(!sortPackages(
        \\{"name": "acme/app"}
    ));
    try testing.expect(!sortPackages("not json at all"));
}
