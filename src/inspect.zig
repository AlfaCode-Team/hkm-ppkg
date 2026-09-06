//! Reading an installed tree — `show`, `why`, `licenses`, `validate`.
//!
//! Every one of these answers from `vendor/composer/installed.json`, which is
//! the record of what is ACTUALLY on disk. That is the deliberate choice over
//! reading `composer.lock`: a lock says what should be installed, and the
//! interesting questions ("why is this here", "what am I actually shipping")
//! are about what is.

const std = @import("std");
const manifest = @import("manifest.zig");
const lockfile = @import("lock.zig");
const constraint = @import("constraint.zig");
const packagist = @import("packagist.zig");
const fetch = @import("fetch.zig");
const prompt = @import("report.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// A package as recorded in installed.json, with the few extra fields these
/// reports need beyond what `manifest.Manifest` models.
const Installed = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    licenses: []const []const u8,
    requires: []const manifest.Dep,
    dev: bool,
};

fn load(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) ![]const Installed {
    const vendor_dir = try std.fs.path.join(allocator, &.{ root_dir, "vendor" });
    const path = try std.fs.path.join(allocator, &.{ vendor_dir, "composer", "installed.json" });

    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch {
        return error.NoInstalledJson;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
        return error.MalformedInstalled;
    };
    if (parsed != .object) return error.MalformedInstalled;

    const list = parsed.object.get("packages") orelse return error.MalformedInstalled;
    if (list != .array) return error.MalformedInstalled;

    // dev-package-names is the authority on which packages are dev-only; the
    // package objects themselves carry no such flag.
    var dev_names: std.ArrayList([]const u8) = .empty;
    if (parsed.object.get("dev-package-names")) |d| {
        if (d == .array) for (d.array.items) |n| {
            if (n == .string) try dev_names.append(allocator, n.string);
        };
    }

    var out: std.ArrayList(Installed) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const m = try manifest.fromObject(allocator, item.object);
        if (m.name.len == 0) continue;

        try out.append(allocator, .{
            .name = m.name,
            .version = m.version,
            .description = strField(item.object, "description") orelse "",
            .licenses = try strList(allocator, item.object, "license"),
            .requires = m.require,
            .dev = util.contains(dev_names.items, m.name),
        });
    }

    std.mem.sort(Installed, out.items, {}, byName);
    return out.toOwnedSlice(allocator);
}

fn byName(_: void, a: Installed, b: Installed) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// ── show ──────────────────────────────────────────────────────────────────────

pub fn show(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, filter: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);

    prompt.intro("hkm ppkg show");

    var shown: usize = 0;
    for (packages) |p| {
        if (filter.len > 0 and std.mem.indexOf(u8, p.name, filter) == null) continue;
        shown += 1;

        prompt.item(
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ p.name, p.version }),
            if (p.description.len > 72) p.description[0..72] else p.description,
        );
    }

    if (shown == 0) {
        prompt.muted(try std.fmt.allocPrint(allocator, "Nothing installed matching '{s}'.", .{filter}));
        return 1;
    }

    var dev_count: usize = 0;
    for (packages) |p| if (p.dev) {
        dev_count += 1;
    };
    prompt.outro(try std.fmt.allocPrint(
        allocator,
        "{d} shown  ·  {d} installed ({d} require-dev)",
        .{ shown, packages.len, dev_count },
    ));
    return 0;
}

// ── why ───────────────────────────────────────────────────────────────────────

/// Which installed packages require `target`, and under what constraint.
pub fn why(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, target: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);

    prompt.intro("hkm ppkg why");

    var present: ?Installed = null;
    for (packages) |p| {
        if (std.mem.eql(u8, p.name, target)) present = p;
    }

    if (present) |p| {
        prompt.item(target, try std.fmt.allocPrint(allocator, "installed at {s}", .{p.version}));
    } else {
        prompt.warn(try std.fmt.allocPrint(allocator, "{s} is not installed.", .{target}));
    }

    prompt.section("Required by");

    var found: usize = 0;
    for (packages) |p| {
        for (p.requires) |dep| {
            if (!std.mem.eql(u8, dep.name, target)) continue;
            found += 1;
            prompt.muted(try std.fmt.allocPrint(
                allocator,
                "    {s} {s}  requires  {s}{s}",
                .{ p.name, p.version, dep.constraint, if (p.dev) "   (dev)" else "" },
            ));
        }
    }

    if (found == 0) {
        // Not an error: this is exactly the answer for a package the ROOT
        // project requires directly, and saying so beats printing nothing.
        prompt.muted("    nothing — it is required by the root project, or not required at all");
    }

    prompt.outro(try std.fmt.allocPrint(allocator, "{d} dependent(s)", .{found}));
    return 0;
}

// ── licenses ──────────────────────────────────────────────────────────────────

pub fn licenses(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);

    prompt.intro("hkm ppkg licenses");

    var names: std.ArrayList([]const u8) = .empty;
    var counts: std.ArrayList(usize) = .empty;
    var unlicensed: std.ArrayList([]const u8) = .empty;

    for (packages) |p| {
        if (p.licenses.len == 0) {
            try unlicensed.append(allocator, p.name);
            continue;
        }
        for (p.licenses) |l| {
            var hit: ?usize = null;
            for (names.items, 0..) |n, i| if (std.mem.eql(u8, n, l)) {
                hit = i;
            };
            if (hit) |i| counts.items[i] += 1 else {
                try names.append(allocator, l);
                try counts.append(allocator, 1);
            }
        }
    }

    for (names.items, counts.items) |name, count| {
        prompt.item(name, try std.fmt.allocPrint(allocator, "{d} package(s)", .{count}));
    }

    // Worth calling out rather than folding into a count: a dependency with no
    // declared licence is the one a redistribution review has to look at.
    if (unlicensed.items.len > 0) {
        prompt.section("No declared licence");
        for (unlicensed.items) |n| prompt.muted(try std.fmt.allocPrint(allocator, "    {s}", .{n}));
    }

    prompt.outro(try std.fmt.allocPrint(allocator, "{d} package(s)", .{packages.len}));
    return 0;
}

// ── outdated ──────────────────────────────────────────────────────────────────

pub const OutdatedOptions = struct {
    /// Only report upgrades the project's own constraints already allow.
    /// The default reports everything, marking which is which.
    constrained_only: bool = false,
    /// Include dev branches as upgrade candidates.
    with_dev: bool = false,
};

/// Compare what is installed against what Packagist offers.
///
/// Two distinct answers, and conflating them is the usual mistake: a release can
/// be newer AND already allowed by the constraint in composer.json (so an
/// `update` would take it), or newer and OUTSIDE it (so it needs the constraint
/// widened first). The second is not actionable by an update, and reporting them
/// the same way sends people to run a command that will do nothing.
pub fn outdated(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    opts: OutdatedOptions,
) !u8 {
    const packages = try load(allocator, io, root_dir);
    const root = (try manifest.read(allocator, io, root_dir)) orelse manifest.Manifest{};
    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);

    prompt.intro("hkm ppkg outdated");
    prompt.item("installed", try std.fmt.allocPrint(allocator, "{d} packages", .{packages.len}));

    const floor = constraint.stabilityFromName(root.minimum_stability);

    var upgradable: usize = 0;
    var blocked: usize = 0;
    var transitive: usize = 0;
    var unchecked: usize = 0;

    prompt.section("Newer releases");

    for (packages) |p| {
        const current = constraint.parseVersion(p.version) orelse {
            unchecked += 1;
            continue;
        };

        const candidates = packagist.versionsOf(allocator, io, cache_dir, p.name, .{
            .dev = opts.with_dev,
        }) catch {
            // A path repository or a private package is not on Packagist; that
            // is expected, not a failure.
            unchecked += 1;
            continue;
        };

        var newest: ?constraint.Version = null;
        var newest_text: []const u8 = "";
        for (candidates) |c| {
            const v = constraint.parseVersion(c.version) orelse continue;
            if (@intFromEnum(v.stability) < @intFromEnum(floor)) continue;
            if (v.order(current) != .gt) continue;
            if (newest == null or v.order(newest.?) == .gt) {
                newest = v;
                newest_text = c.version;
            }
        }

        const better = newest orelse continue;

        // Three distinct situations, and collapsing them misleads:
        //
        //   root-declared and allowed   an update takes it
        //   root-declared but outside   the constraint must be widened first
        //   not root-declared           TRANSITIVE — whether it moves depends on
        //                               its dependents' constraints, not the
        //                               root's, so calling it "upgradable" is a
        //                               promise this report cannot make
        const declared = declaredConstraintFor(root, p.name);
        const note = if (declared) |text| blk: {
            const parsed = constraint.parse(allocator, text) catch break :blk "";
            break :blk if (parsed.matches(better)) "" else "   (outside the declared constraint)";
        } else "   (transitive — gated by its dependents)";

        if (declared == null) {
            transitive += 1;
        } else if (note.len == 0) {
            upgradable += 1;
        } else {
            blocked += 1;
        }
        if (opts.constrained_only and note.len > 0) continue;

        prompt.muted(try std.fmt.allocPrint(
            allocator,
            "    {s}  {s} → {s}{s}",
            .{ p.name, p.version, newest_text, note },
        ));
    }

    prompt.blank();
    prompt.item("upgradable now", try std.fmt.allocPrint(allocator, "{d}  (declared in composer.json)", .{upgradable}));
    if (blocked > 0) prompt.item("needs a wider constraint", try std.fmt.allocPrint(allocator, "{d}", .{blocked}));
    if (transitive > 0) prompt.item("transitive", try std.fmt.allocPrint(allocator, "{d}  (moved only by their dependents)", .{transitive}));
    if (unchecked > 0) prompt.item("not on packagist", try std.fmt.allocPrint(allocator, "{d}", .{unchecked}));

    prompt.outro("comparison only — nothing was changed");
    return 0;
}

/// The root project's own constraint on a package, if it declares one.
fn declaredConstraintFor(root: manifest.Manifest, name: []const u8) ?[]const u8 {
    for (root.require) |d| if (std.mem.eql(u8, d.name, name)) return d.constraint;
    for (root.require_dev) |d| if (std.mem.eql(u8, d.name, name)) return d.constraint;
    return null;
}

// ── validate ──────────────────────────────────────────────────────────────────

/// Check `composer.json` for the mistakes that break an install later.
pub fn validate(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !u8 {
    prompt.intro("hkm ppkg validate");

    const m = (manifest.read(allocator, io, root_dir) catch {
        prompt.err("composer.json is not valid JSON.");
        return 1;
    }) orelse {
        prompt.err("No composer.json here.");
        return 1;
    };

    var errors: usize = 0;
    var warnings: usize = 0;

    if (m.name.len == 0) {
        prompt.warn("no \"name\" — required to publish, and it is what keys autoload file identifiers");
        warnings += 1;
    } else if (std.mem.indexOfScalar(u8, m.name, '/') == null) {
        prompt.err("\"name\" must be vendor/package");
        errors += 1;
    }

    // An autoload path that does not exist produces no error at install time and
    // a "class not found" much later, which is why it is checked here.
    for ([_]manifest.Autoload{ m.autoload, m.autoload_dev }) |block| {
        for (block.psr4) |rule| {
            if (!std.mem.endsWith(u8, rule.prefix, "\\")) {
                prompt.err(try std.fmt.allocPrint(
                    allocator,
                    "psr-4 prefix \"{s}\" must end with a backslash",
                    .{rule.prefix},
                ));
                errors += 1;
            }
            for (rule.paths) |p| {
                const abs = try std.fs.path.join(allocator, &.{ root_dir, p });
                if (!util.dirExists(Dir.cwd(), io, abs) and !util.fileExists(io, abs)) {
                    prompt.warn(try std.fmt.allocPrint(
                        allocator,
                        "psr-4 \"{s}\" points at {s}, which does not exist",
                        .{ rule.prefix, p },
                    ));
                    warnings += 1;
                }
            }
        }
        for (block.files) |f| {
            const abs = try std.fs.path.join(allocator, &.{ root_dir, f });
            if (!util.fileExists(io, abs)) {
                prompt.err(try std.fmt.allocPrint(
                    allocator,
                    "autoload files entry {s} does not exist — it is required unconditionally at boot",
                    .{f},
                ));
                errors += 1;
            }
        }
    }

    // A lock that predates composer.json is the classic "works on my machine".
    const lock_present = util.fileExists(io, try std.fs.path.join(allocator, &.{ root_dir, "composer.lock" }));
    if (!lock_present) {
        prompt.warn("no composer.lock — installs will not be reproducible");
        warnings += 1;
    }

    prompt.blank();
    if (errors > 0) {
        prompt.err(try std.fmt.allocPrint(allocator, "{d} error(s), {d} warning(s)", .{ errors, warnings }));
        return 1;
    }
    if (warnings > 0) {
        prompt.warn(try std.fmt.allocPrint(allocator, "{d} warning(s)", .{warnings}));
        return 0;
    }
    prompt.ok("composer.json is valid.");
    return 0;
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn strList(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const raw = obj.get(key) orelse return &.{};
    // "license" is an array in practice but a bare string is legal.
    switch (raw) {
        .string => |s| {
            const one = try allocator.alloc([]const u8, 1);
            one[0] = s;
            return one;
        },
        .array => |a| {
            var out: std.ArrayList([]const u8) = .empty;
            for (a.items) |item| if (item == .string) try out.append(allocator, item.string);
            return out.toOwnedSlice(allocator);
        },
        else => return &.{},
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a licence given as a bare string is read like a one-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"license":"MIT"}
    , .{});
    const got = try strList(a, one.object, "license");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("MIT", got[0]);

    const many = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"license":["MIT","Apache-2.0"]}
    , .{});
    const got2 = try strList(a, many.object, "license");
    try testing.expectEqual(@as(usize, 2), got2.len);
    try testing.expectEqualStrings("Apache-2.0", got2[1]);

    // Absent, and the wrong type, both mean "nothing declared" rather than an
    // error — these reports must not fail on one odd package.
    const none = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"license":42}
    , .{});
    try testing.expectEqual(@as(usize, 0), (try strList(a, none.object, "license")).len);
}

test "packages are reported in name order" {
    var list = [_]Installed{
        .{ .name = "z/last", .version = "1", .description = "", .licenses = &.{}, .requires = &.{}, .dev = false },
        .{ .name = "a/first", .version = "1", .description = "", .licenses = &.{}, .requires = &.{}, .dev = false },
    };
    std.mem.sort(Installed, &list, {}, byName);
    try testing.expectEqualStrings("a/first", list[0].name);
}
