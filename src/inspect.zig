//! Reading an installed tree — `show`, `why`, `licenses`, `validate`.
//!
//! Every one of these answers from `vendor/composer/installed.json`, which is
//! the record of what is ACTUALLY on disk. That is the deliberate choice over
//! reading `composer.lock`: a lock says what should be installed, and the
//! interesting questions ("why is this here", "what am I actually shipping")
//! are about what is.

const std = @import("std");
const manifest = @import("manifest.zig");
const layout = @import("layout.zig");
const lockfile = @import("lock.zig");
const constraint = @import("constraint.zig");
const packagist = @import("packagist.zig");
const fetch = @import("fetch.zig");
const prompt = @import("report.zig");
const util = @import("util.zig");
const platform_mod = @import("platform.zig");

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
    /// Names this package answers to besides its own. `symfony/polyfill-ctype`
    /// provides `ext-ctype`, which is why a machine without that extension can
    /// still satisfy a tree that requires it.
    ///
    /// Defaulted because most callers construct an Installed to test one thing
    /// and every field they must spell out is a field the test is not about.
    provides: []const manifest.Dep = &.{},
    replaces: []const manifest.Dep = &.{},
    /// `conflict` — what this package refuses to sit beside. Read for
    /// `prohibits`, which is the only report that needs it.
    conflicts: []const manifest.Dep = &.{},
    /// `suggest` — optional companions, name → why.
    suggests: []const Suggestion = &.{},
    /// `funding` — how to pay for it, `type` → `url`.
    funding: []const Suggestion = &.{},
    homepage: []const u8 = "",
    source_url: []const u8 = "",
    dev: bool,
};

/// A `name → text` pair, the shape both `suggest` and `funding` take.
pub const Suggestion = struct {
    key: []const u8,
    value: []const u8,
};

fn load(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) ![]const Installed {
    // Read the project's own `config.vendor-dir` before looking for the tree:
    // asking `vendor/` in a project that moved it reports "nothing installed"
    // about a directory that is fully populated.
    const declared = (manifest.read(allocator, io, root_dir) catch null) orelse manifest.Manifest{};
    const lay = try layout.resolve(allocator, null, root_dir, declared);
    const path = try std.fs.path.join(allocator, &.{ lay.vendor, "composer", "installed.json" });

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
            .provides = m.provide,
            .replaces = m.replace,
            .conflicts = m.conflict,
            .suggests = try pairs(allocator, item.object, "suggest"),
            .funding = try funding(allocator, item.object),
            .homepage = strField(item.object, "homepage") orelse "",
            .source_url = sourceUrl(item.object),
            .dev = util.contains(dev_names.items, m.name),
        });
    }

    std.mem.sort(Installed, out.items, {}, byName);
    return out.toOwnedSlice(allocator);
}

/// A `{"key": "value"}` object as a list, preserving the file's order.
fn pairs(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const Suggestion {
    var out: std.ArrayList(Suggestion) = .empty;
    const v = obj.get(key) orelse return out.toOwnedSlice(allocator);
    if (v != .object) return out.toOwnedSlice(allocator);
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        try out.append(allocator, .{ .key = e.key_ptr.*, .value = e.value_ptr.string });
    }
    return out.toOwnedSlice(allocator);
}

/// `funding` is a LIST of `{type, url}` objects, not the `key → value` object
/// `suggest` is. Normalised to the same shape so one report can print both.
fn funding(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const Suggestion {
    var out: std.ArrayList(Suggestion) = .empty;
    const v = obj.get("funding") orelse return out.toOwnedSlice(allocator);
    if (v != .array) return out.toOwnedSlice(allocator);
    for (v.array.items) |item| {
        if (item != .object) continue;
        const url = strField(item.object, "url") orelse continue;
        try out.append(allocator, .{
            .key = strField(item.object, "type") orelse "other",
            .value = url,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn sourceUrl(obj: std.json.ObjectMap) []const u8 {
    const source = obj.get("source") orelse return "";
    if (source != .object) return "";
    return strField(source.object, "url") orelse "";
}

fn byName(_: void, a: Installed, b: Installed) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// ── show ──────────────────────────────────────────────────────────────────────

pub fn show(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, filter: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);

    prompt.intro("ppkg show");

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

    prompt.intro("ppkg why");

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

    prompt.intro("ppkg licenses");

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

    prompt.intro("ppkg outdated");
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
// ── suggests / fund / home / prohibits ───────────────────────────────────────

/// `hkm ppkg suggests` — the optional companions the installed set names.
///
/// Reported by the package that suggests them, and only for what is NOT already
/// installed: a suggestion already satisfied is noise, and a list where most
/// lines are noise is a list nobody reads.
pub fn suggests(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);

    var shown: usize = 0;
    for (packages) |p| {
        var printed_header = false;
        for (p.suggests) |s| {
            if (isInstalled(packages, s.key)) continue;
            if (!printed_header) {
                prompt.section(p.name);
                printed_header = true;
            }
            prompt.item(s.key, if (s.value.len > 72) s.value[0..72] else s.value);
            shown += 1;
        }
    }

    prompt.blank();
    if (shown == 0) {
        prompt.ok("Every suggested package is already installed.");
        return 0;
    }
    prompt.outro(try std.fmt.allocPrint(allocator, "{d} suggestion(s) not installed", .{shown}));
    return 0;
}

/// `hkm ppkg fund` — who to pay, for the packages that say.
pub fn fund(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);

    var shown: usize = 0;
    for (packages) |p| {
        if (p.funding.len == 0) continue;
        prompt.section(p.name);
        for (p.funding) |f| prompt.item(f.key, f.value);
        shown += 1;
    }

    prompt.blank();
    if (shown == 0) {
        prompt.note("None of the installed packages declare funding information.");
        return 0;
    }
    prompt.outro(try std.fmt.allocPrint(allocator, "{d} of {d} package(s) ask for support", .{ shown, packages.len }));
    return 0;
}

/// `hkm ppkg home <pkg>` — the URL to open, printed rather than opened.
///
/// Printed because opening a browser is the host's decision, not a package
/// manager's, and because a printed URL works over ssh where an opened one
/// does not.
pub fn home(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, target: []const u8) !u8 {
    const packages = try load(allocator, io, root_dir);
    for (packages) |p| {
        if (!std.ascii.eqlIgnoreCase(p.name, target)) continue;
        const url = if (p.homepage.len > 0) p.homepage else p.source_url;
        if (url.len == 0) {
            prompt.err(try std.fmt.allocPrint(allocator, "{s} declares no homepage or source url.", .{p.name}));
            return 1;
        }
        prompt.raw(url);
        return 0;
    }
    prompt.err(try std.fmt.allocPrint(allocator, "{s} is not installed.", .{target}));
    return 1;
}

/// `hkm ppkg prohibits <pkg> <version>` — what stands in the way.
///
/// The inverse of `why`: it names each installed package whose `require` or
/// `conflict` would be violated by that version. Composer calls the same
/// command `why-not`, and the question it answers — "I asked for 3.0 and got
/// 2.4, what is holding it back" — has no other way to be answered from a
/// tree that is already installed.
pub fn prohibits(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    target: []const u8,
    version: []const u8,
) !u8 {
    const packages = try load(allocator, io, root_dir);

    var blockers: usize = 0;
    for (packages) |p| {
        for (p.requires) |dep| {
            if (!std.ascii.eqlIgnoreCase(dep.name, target)) continue;
            const c = constraint.parse(allocator, dep.constraint) catch continue;
            if (c.accepts(version)) continue;
            blockers += 1;
            prompt.item(
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ p.name, p.version }),
                try std.fmt.allocPrint(allocator, "requires {s} {s}", .{ target, dep.constraint }),
            );
        }
        for (p.conflicts) |dep| {
            if (!std.ascii.eqlIgnoreCase(dep.name, target)) continue;
            const c = constraint.parse(allocator, dep.constraint) catch continue;
            if (!c.accepts(version)) continue;
            blockers += 1;
            prompt.item(
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ p.name, p.version }),
                try std.fmt.allocPrint(allocator, "conflicts with {s} {s}", .{ target, dep.constraint }),
            );
        }
    }

    prompt.blank();
    if (blockers == 0) {
        prompt.ok(try std.fmt.allocPrint(
            allocator,
            "Nothing installed prevents {s} {s}.",
            .{ target, version },
        ));
        return 0;
    }
    prompt.outro(try std.fmt.allocPrint(allocator, "{d} package(s) stand in the way", .{blockers}));
    return 1;
}

fn isInstalled(packages: []const Installed, name: []const u8) bool {
    for (packages) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return true;
        for (p.provides) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return true;
        for (p.replaces) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return true;
    }
    return false;
}

pub fn validate(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !u8 {
    prompt.intro("ppkg validate");

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

// ── check-platform-reqs ───────────────────────────────────────────────────────

/// Does this machine satisfy every platform requirement in the tree?
///
/// Every requirement, not just the root's. A dependency four levels down that
/// needs `ext-sodium` is the one that will fail, and it will fail at the moment
/// its code first runs rather than at install time — which is why Composer
/// checks the whole installed set here and so does this.
pub fn checkPlatformReqs(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    php_bin: []const u8,
    /// `--ignore-platform-req` — requirements the operator has waived. Waived
    /// ones are COUNTED and named rather than dropped: the point of running
    /// this command is to learn what the machine does and does not satisfy,
    /// and silently passing a requirement nobody checked answers a different
    /// question than the one asked.
    ignore: platform_mod.Ignore,
) !u8 {
    prompt.intro("ppkg check-platform-reqs");

    const root = (try manifest.read(allocator, io, root_dir)) orelse {
        prompt.err("No composer.json here.");
        return 1;
    };

    const plat = platform_mod.detect(allocator, io, env, php_bin, root.config_platform) catch {
        prompt.err(try std.fmt.allocPrint(
            allocator,
            "Could not ask '{s}' about itself. Set config.platform in composer.json, or point at a real interpreter.",
            .{php_bin},
        ));
        return 1;
    };

    if (plat.versionOf("php")) |php| {
        prompt.item("php", try std.fmt.allocPrint(allocator, "{s}{s}", .{
            php.pretty,
            if (php.overridden) "  (from config.platform)" else "",
        }));
    }
    prompt.item("extensions", try std.fmt.allocPrint(allocator, "{d} loaded", .{countExt(plat)}));
    prompt.blank();

    // Root requirements first, then every installed package's — reported
    // together, because the machine either satisfies the tree or it does not.
    var sources: std.ArrayList(struct { who: []const u8, deps: []const manifest.Dep }) = .empty;
    try sources.append(allocator, .{ .who = "__root__", .deps = root.require });
    try sources.append(allocator, .{ .who = "__root__", .deps = root.require_dev });

    const installed = load(allocator, io, root_dir) catch &[_]Installed{};
    for (installed) |pkg| {
        try sources.append(allocator, .{ .who = pkg.name, .deps = pkg.requires });
    }

    var ok_count: usize = 0;
    var provided_count: usize = 0;
    var ignored_count: usize = 0;
    var failures: usize = 0;
    var unchecked: usize = 0;

    // Report each distinct platform package once, the way Composer does. The
    // same `ext-mbstring` required by nine packages is one fact about this
    // machine, and printing it nine times buries the one that fails.
    var seen: std.ArrayList([]const u8) = .empty;

    for (sources.items) |src| {
        for (src.deps) |dep| {
            if (!dep.isPlatform()) continue;
            if (util.contains(seen.items, dep.name)) continue;

            // A polyfill's `provide` settles it before the runtime is asked.
            // Composer prints this as "success provided by <package>", and
            // without it a machine missing an extension it does not need would
            // be told to go and install it.
            if (providerOf(allocator, installed, dep)) |who| {
                try seen.append(allocator, dep.name);
                provided_count += 1;
                prompt.muted(try std.fmt.allocPrint(
                    allocator,
                    "{s} {s} — provided by {s}",
                    .{ dep.name, dep.constraint, who },
                ));
                continue;
            }

            try seen.append(allocator, dep.name);
            switch (plat.checkWith(allocator, dep, ignore)) {
                .satisfied => ok_count += 1,
                .ignored => {
                    ignored_count += 1;
                    prompt.muted(try std.fmt.allocPrint(
                        allocator,
                        "{s} {s} — ignored (--ignore-platform-req)",
                        .{ dep.name, dep.constraint },
                    ));
                },
                .unmodelled => {
                    unchecked += 1;
                    prompt.warn(try std.fmt.allocPrint(
                        allocator,
                        "{s} requires {s} {s} — not checked: no interpreter answered, so this machine was never inspected",
                        .{ src.who, dep.name, dep.constraint },
                    ));
                },
                .missing => {
                    failures += 1;
                    prompt.err(try std.fmt.allocPrint(
                        allocator,
                        "{s} requires {s} {s} — NOT PRESENT",
                        .{ src.who, dep.name, dep.constraint },
                    ));
                },
                .conflict => |c| {
                    failures += 1;
                    prompt.err(try std.fmt.allocPrint(
                        allocator,
                        "{s} requires {s} {s} — this machine has {s}",
                        .{ src.who, dep.name, dep.constraint, c.have },
                    ));
                },
            }
        }
    }

    prompt.blank();
    prompt.item("satisfied", try std.fmt.allocPrint(allocator, "{d}", .{ok_count}));
    if (provided_count > 0) {
        prompt.item("provided by a package", try std.fmt.allocPrint(allocator, "{d}", .{provided_count}));
    }
    if (unchecked > 0) {
        prompt.item("not checked", try std.fmt.allocPrint(allocator, "{d}  (no interpreter answered)", .{unchecked}));
    }
    if (ignored_count > 0) {
        prompt.item("ignored", try std.fmt.allocPrint(allocator, "{d}  (--ignore-platform-req)", .{ignored_count}));
    }
    if (failures > 0) {
        prompt.item("failing", try std.fmt.allocPrint(allocator, "{d}", .{failures}));
        prompt.outro("this machine does not satisfy every requirement");
        return 1;
    }

    // Said differently when some were waived: "every requirement is satisfied"
    // would be a claim about checks that were never made.
    prompt.outro(if (ignored_count > 0)
        "every requirement that was checked is satisfied"
    else
        "every platform requirement is satisfied");
    return 0;
}

fn countExt(p: platform_mod.Platform) usize {
    var n: usize = 0;
    for (p.facts) |f| {
        if (std.mem.startsWith(u8, f.name, "ext-")) n += 1;
    }
    return n;
}

/// Which installed package answers for this platform requirement, if any.
///
/// `provide` and `replace` both count. A version of `*` — the form a polyfill
/// almost always uses — answers anything; a specific one is matched properly,
/// because a polyfill that provides `ext-mbstring` at 7.3 does not satisfy a
/// requirement for ^8.0, and saying otherwise would be worse than not checking.
fn providerOf(
    allocator: std.mem.Allocator,
    installed: []const Installed,
    dep: manifest.Dep,
) ?[]const u8 {
    for (installed) |pkg| {
        for ([_][]const manifest.Dep{ pkg.provides, pkg.replaces }) |list| {
            for (list) |p| {
                if (!std.ascii.eqlIgnoreCase(p.name, dep.name)) continue;
                if (std.mem.eql(u8, p.constraint, "*") or dep.constraint.len == 0 or
                    std.mem.eql(u8, dep.constraint, "*")) return pkg.name;
                const c = constraint.parse(allocator, dep.constraint) catch continue;
                if (c.accepts(p.constraint)) return pkg.name;
            }
        }
    }
    return null;
}
