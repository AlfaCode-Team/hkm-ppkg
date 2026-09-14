//! Writing `composer.lock`.
//!
//! The output has to be byte-identical to Composer's, and that is a stronger
//! requirement than it sounds. A lock is read by humans in code review and
//! diffed on every branch; a file that is *equivalent* but reordered turns one
//! dependency bump into a four-thousand-line diff nobody reads. So the key
//! order here is not a choice — it is `ArrayDumper::dump()` followed by
//! `Locker::lockPackages()`, transcribed.
//!
//! ## The order, and the three edits made to it
//!
//! `ArrayDumper` emits keys in a fixed sequence. `lockPackages` then makes
//! exactly three changes to each package, and all three are easy to miss:
//!
//!   1. `version_normalized` is REMOVED. It is in every packagist metadata
//!      object and in `installed.json`, and it is not in the lock.
//!   2. `installation-source` is REMOVED.
//!   3. `time` is removed and re-appended, so it lands LAST — after `funding`,
//!      after `support`, after everything.
//!
//! Packages are then sorted by name, ties broken by version.
//!
//! ## Why an unknown key is DROPPED, not preserved
//!
//! The package objects come from packagist's v2 metadata, which is close to an
//! `ArrayDumper` output but not equal to it. Composer's path is
//! `ArrayLoader → Package → ArrayDumper`, and the loader keeps only what it
//! understands — so a metadata field it has no property for never reaches the
//! lock. `published-time` is the one that proves it: packagist sends it on
//! every package and no lock in existence contains it.
//!
//! Preserving unknown keys therefore produces a file Composer rewrites on the
//! next command. The canonical list below is the whole contract.

const std = @import("std");
const phpjson = @import("phpjson.zig");
const platform_mod = @import("platform.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// `JsonFile::write`'s default options.
const lock_options: phpjson.Options = .{
    .escape_slashes = false,
    .escape_unicode = false,
    .pretty = true,
    .indent = "    ",
    // The lock is built from PHP arrays Composer never round-trips through
    // `json_decode($s, true)`, so an empty object stays `{}` here — unlike in
    // the content hash, where the same value would be written `[]`.
    .assoc_arrays = false,
};

/// `ArrayDumper::dump()`'s key sequence, with `version_normalized`,
/// `installation-source` and `time` handled separately.
const canonical_order = [_][]const u8{
    "name",
    "version",
    "target-dir",
    "source",
    "dist",
    // Link types, in `BasePackage::$supportedLinkTypes` order — NOT alphabetical.
    "require",
    "conflict",
    "provide",
    "replace",
    "require-dev",
    "suggest",
    "default-branch",
    // `dumpValues` group one.
    "bin",
    "type",
    "extra",
    "autoload",
    "autoload-dev",
    "notification-url",
    "include-path",
    "php-ext",
    "archive",
    // `dumpValues` group two, CompletePackage only.
    "scripts",
    "license",
    "authors",
    "description",
    "homepage",
    "keywords",
    "repositories",
    "support",
    "funding",
    "abandoned",
    "minimum-stability",
    "transport-options",
    // `time` is appended after everything, by lockPackages.
};

/// Keys the lock does not carry, however they arrive.
const dropped = [_][]const u8{ "version_normalized", "installation-source" };

/// `vendor/composer/installed.json`'s key order.
///
/// The SAME `ArrayDumper` sequence, minus the three edits `lockPackages` makes:
/// `version_normalized` stays (right after `version`), `time` stays in its
/// natural place rather than moving to the end, and `installation-source`
/// stays. `install-path` is appended by `FilesystemRepository::write`, so it
/// lands last.
///
/// Two orders for what looks like the same object, and getting them confused
/// produces two files that are each individually plausible.
const installed_order = [_][]const u8{
    "name",             "version",             "version_normalized", "target-dir",
    "source",           "dist",                "require",            "conflict",
    "provide",          "replace",             "require-dev",        "suggest",
    "time",             "default-branch",      "bin",                "type",
    "extra",            "installation-source", "autoload",           "autoload-dev",
    "notification-url", "include-path",        "php-ext",            "archive",
    "scripts",          "license",             "authors",            "description",
    "homepage",         "keywords",            "repositories",       "support",
    "funding",          "abandoned",           "minimum-stability",  "transport-options",
    "install-path",
};

/// The link maps `ArrayDumper` ksorts on the way out.
const ksorted = [_][]const u8{ "require", "conflict", "provide", "replace", "require-dev", "suggest" };

/// `source` and `dist` have their OWN key order, set field by field in
/// `ArrayDumper::dump`. Packagist sends the same fields in a different order,
/// so passing the object through verbatim puts `url` before `type` and
/// `shasum` before `reference` — a diff on every package in the file.
const source_order = [_][]const u8{ "type", "url", "reference", "mirrors" };
const dist_order = [_][]const u8{ "type", "url", "reference", "shasum", "mirrors" };

/// Keys `dumpValues` writes, and therefore keys it SKIPS when the value is an
/// empty array. A `"funding": []` in a lock is the tell that this was missed.
const skip_when_empty = [_][]const u8{
    "bin",          "type",              "extra",        "autoload", "autoload-dev",
    "include-path", "php-ext",           "scripts",      "license",  "authors",
    "homepage",     "keywords",          "repositories", "support",  "funding",
    "archive",      "transport-options",
};

/// Keys `ArrayLoader` guards with PHP's `empty()`, so an empty value never
/// reaches the package object and therefore never reaches the lock.
///
/// This is a LOAD-time filter, not a dump-time one, and it is stricter: PHP's
/// `empty()` is true for `""`, `[]`, `null`, `0`, `"0"` and `false`. Composer's
/// own output for `myclabs/deep-copy` is the proof — packagist sends
/// `"homepage": ""` and no lock contains it.
const skip_when_php_empty = [_][]const u8{
    "description", "homepage", "keywords", "license", "authors", "funding", "archive",
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    /// The complete package object, as packagist or a previous lock spelled it.
    raw: std.json.Value,
    /// Set when the package came from a `composer` repository.
    ///
    /// It is NOT in packagist's per-package metadata — it is a property of the
    /// REPOSITORY, applied by `ComposerRepository` to every package it loads,
    /// and it ends up in the lock. So it has to be supplied here, or every
    /// packagist package differs from Composer's output by one line.
    notification_url: ?[]const u8 = null,
};

pub const Data = struct {
    content_hash: []const u8,
    packages: []const Package,
    /// `null` writes `"packages-dev": null`, which is what a lock produced with
    /// `--no-dev` records. An empty SLICE writes `[]`, which is what a project
    /// with no dev dependencies records. They are different files.
    packages_dev: ?[]const Package = null,
    aliases: []const std.json.Value = &.{},
    minimum_stability: []const u8 = "stable",
    /// name → stability int, or an empty object.
    stability_flags: ?std.json.Value = null,
    prefer_stable: bool = false,
    prefer_lowest: bool = false,
    /// The platform requirements of the root package, split dev / non-dev.
    platform: ?std.json.Value = null,
    platform_dev: ?std.json.Value = null,
    /// Written only when `config.platform` is set.
    platform_overrides: ?std.json.Value = null,
    /// `null` omits the key entirely.
    ///
    /// Composer 2 always writes it, so a lock this package CREATES always has
    /// one. A lock written by Composer 1 does not, and re-rendering one has to
    /// reproduce it exactly — otherwise the round-trip check cannot tell "this
    /// renderer is wrong" from "this file is older than the field".
    plugin_api_version: ?[]const u8 = platform_mod.plugin_api_version,
};

/// The `_readme` block, verbatim.
///
/// Composer splits the third line as `'This file is @gener'.'ated automatically'`
/// so that its own source is not flagged by tools that scan for the annotation.
/// The VALUE is the joined string, and that is what has to be written.
const readme = [_][]const u8{
    "This file locks the dependencies of your project to a known state",
    "Read more about it at https://getcomposer.org/doc/01-basic-usage.md#installing-dependencies",
    "This file is @generated automatically",
};

/// Render a complete composer.lock, including its trailing newline.
pub fn render(allocator: std.mem.Allocator, data: Data) ![]const u8 {
    var root: std.json.ObjectMap = .empty;

    var readme_items: std.ArrayList(std.json.Value) = .empty;
    for (readme) |line| try readme_items.append(allocator, .{ .string = line });
    try root.put(allocator, "_readme", .{ .array = .fromOwnedSlice(allocator, try readme_items.toOwnedSlice(allocator)) });

    try root.put(allocator, "content-hash", .{ .string = data.content_hash });
    try root.put(allocator, "packages", try packagesArray(allocator, data.packages));

    // Order matters: `packages-dev` sits here even when it is null, because
    // Composer seeds the key before deciding whether to fill it.
    if (data.packages_dev) |dev| {
        try root.put(allocator, "packages-dev", try packagesArray(allocator, dev));
    } else {
        try root.put(allocator, "packages-dev", .null);
    }

    try root.put(allocator, "aliases", .{ .array = .fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, data.aliases)) });
    try root.put(allocator, "minimum-stability", .{ .string = data.minimum_stability });
    try root.put(allocator, "stability-flags", data.stability_flags orelse emptyObject());
    try root.put(allocator, "prefer-stable", .{ .bool = data.prefer_stable });
    try root.put(allocator, "prefer-lowest", .{ .bool = data.prefer_lowest });
    try root.put(allocator, "platform", data.platform orelse emptyObject());
    try root.put(allocator, "platform-dev", data.platform_dev orelse emptyObject());
    if (data.platform_overrides) |po| try root.put(allocator, "platform-overrides", po);
    if (data.plugin_api_version) |v| try root.put(allocator, "plugin-api-version", .{ .string = v });

    var out: std.ArrayList(u8) = .empty;
    try phpjson.encode(allocator, &out, .{ .object = root }, lock_options);
    // `JsonFile::write` appends one when pretty-printing. Without it every
    // Composer run rewrites the file and every diff shows a "\ No newline".
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

fn emptyObject() std.json.Value {
    return .{ .object = .empty };
}

fn packagesArray(allocator: std.mem.Allocator, packages: []const Package) !std.json.Value {
    const sorted = try allocator.dupe(Package, packages);
    std.mem.sort(Package, sorted, {}, byNameThenVersion);

    var items: std.ArrayList(std.json.Value) = .empty;
    for (sorted) |p| {
        try items.append(allocator, .{ .object = try canonicalise(allocator, p.raw, p.notification_url) });
    }
    return .{ .array = .fromOwnedSlice(allocator, try items.toOwnedSlice(allocator)) };
}

/// `usort` by name, ties broken by version — `strcmp`, so plain byte order and
/// NOT the version ordering used everywhere else in this package.
fn byNameThenVersion(_: void, a: Package, b: Package) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.version, b.version) == .lt,
    };
}

/// One package object in `installed.json` form.
///
/// `extras` are the keys the installer knows and the metadata does not —
/// `version_normalized`, `installation-source`, `install-path` — merged in so
/// they land in their proper positions rather than being appended.
pub fn canonicaliseInstalled(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    extras: []const Extra,
) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    if (raw != .object) return out;

    var src = try raw.object.clone(allocator);
    for (extras) |e| try src.put(allocator, e.key, .{ .string = e.value });

    for (installed_order) |key| {
        const v = src.get(key) orelse continue;
        if (isEmptyContainer(v) and util.contains(&ksorted, key)) continue;
        if (isEmptyContainer(v) and util.contains(&skip_when_empty, key)) continue;
        if (isPhpEmpty(v) and util.contains(&skip_when_php_empty, key)) continue;

        if (util.contains(&ksorted, key) and v == .object) {
            try out.put(allocator, key, .{ .object = try sortKeys(allocator, v.object) });
            continue;
        }
        if (std.mem.eql(u8, key, "source") and v == .object) {
            try out.put(allocator, key, .{ .object = try reorder(allocator, v.object, &source_order) });
            continue;
        }
        if (std.mem.eql(u8, key, "dist") and v == .object) {
            try out.put(allocator, key, .{ .object = try reorder(allocator, v.object, &dist_order) });
            continue;
        }
        if (std.mem.eql(u8, key, "keywords") and v == .array) {
            try out.put(allocator, key, .{ .array = try sortStrings(allocator, v.array) });
            continue;
        }
        try out.put(allocator, key, v);
    }

    return out;
}

pub const Extra = struct { key: []const u8, value: []const u8 };

/// One package object, reordered into `ArrayDumper`'s sequence.
fn canonicalise(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    notification_url: ?[]const u8,
) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    if (raw != .object) return out;

    var src = raw.object;
    if (notification_url) |url| {
        if (src.get("notification-url") == null) {
            src = try src.clone(allocator);
            try src.put(allocator, "notification-url", .{ .string = url });
        }
    }

    for (canonical_order) |key| {
        const v = src.get(key) orelse continue;

        // `count($links) === 0 → continue`: an empty link map is not written.
        if (isEmptyContainer(v) and util.contains(&ksorted, key)) continue;
        // `dumpValues` skips a value that is an empty array — and in PHP an
        // empty JSON object decodes to exactly that, so both shapes go.
        if (isEmptyContainer(v) and util.contains(&skip_when_empty, key)) continue;
        if (isPhpEmpty(v) and util.contains(&skip_when_php_empty, key)) continue;

        if (util.contains(&ksorted, key) and v == .object) {
            try out.put(allocator, key, .{ .object = try sortKeys(allocator, v.object) });
            continue;
        }
        if (std.mem.eql(u8, key, "source") and v == .object) {
            try out.put(allocator, key, .{ .object = try reorder(allocator, v.object, &source_order) });
            continue;
        }
        if (std.mem.eql(u8, key, "dist") and v == .object) {
            try out.put(allocator, key, .{ .object = try reorder(allocator, v.object, &dist_order) });
            continue;
        }
        if (std.mem.eql(u8, key, "keywords") and v == .array) {
            try out.put(allocator, key, .{ .array = try sortStrings(allocator, v.array) });
            continue;
        }
        // `ArrayLoader`: `is_array($license) ? $license : [$license]`. Packagist
        // always serves an array, so this only ever fires for a manifest read
        // straight off a disk or a git remote — where `"license": "MIT"` is the
        // common spelling and Composer still writes `["MIT"]`.
        if (std.mem.eql(u8, key, "license") and v == .string) {
            var one: std.json.Array = .init(allocator);
            try one.append(v);
            try out.put(allocator, key, .{ .array = one });
            continue;
        }
        try out.put(allocator, key, v);
    }

    // Last, always.
    if (src.get("time")) |t| try out.put(allocator, "time", t);

    return out;
}

/// A PHP array that is empty, however JSON spelled it.
fn isEmptyContainer(v: std.json.Value) bool {
    return switch (v) {
        .object => |o| o.count() == 0,
        .array => |a| a.items.len == 0,
        else => false,
    };
}

/// PHP's `empty()`.
///
/// The surprising members are what make it worth spelling out: the string
/// `"0"`, the integer `0` and `false` are all empty, so a package whose
/// `description` is literally `"0"` has no description as far as Composer is
/// concerned. Faithful beats sensible here — the goal is the same bytes.
fn isPhpEmpty(v: std.json.Value) bool {
    return switch (v) {
        .null => true,
        .bool => |b| !b,
        .integer => |n| n == 0,
        .float => |f| f == 0,
        .string => |str| str.len == 0 or std.mem.eql(u8, str, "0"),
        .number_string => |str| str.len == 0 or std.mem.eql(u8, str, "0"),
        .object => |o| o.count() == 0,
        .array => |a| a.items.len == 0,
    };
}

/// Re-emit an object in a fixed key order, keeping only the keys named.
fn reorder(allocator: std.mem.Allocator, o: std.json.ObjectMap, order: []const []const u8) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    for (order) |key| {
        if (o.get(key)) |v| try out.put(allocator, key, v);
    }
    return out;
}

fn sortKeys(allocator: std.mem.Allocator, o: std.json.ObjectMap) !std.json.ObjectMap {
    var keys: std.ArrayList([]const u8) = .empty;
    var it = o.iterator();
    while (it.next()) |e| try keys.append(allocator, e.key_ptr.*);

    std.mem.sort([]const u8, keys.items, {}, lessBytes);

    var out: std.json.ObjectMap = .empty;
    for (keys.items) |k| try out.put(allocator, k, o.get(k).?);
    return out;
}

fn sortStrings(allocator: std.mem.Allocator, arr: std.json.Array) !std.json.Array {
    const items = try allocator.dupe(std.json.Value, arr.items);
    std.mem.sort(std.json.Value, items, {}, lessJsonString);
    return .fromOwnedSlice(allocator, items);
}

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessJsonString(_: void, a: std.json.Value, b: std.json.Value) bool {
    const sa = if (a == .string) a.string else "";
    const sb = if (b == .string) b.string else "";
    return std.mem.order(u8, sa, sb) == .lt;
}

/// Re-render an existing lock from its own contents.
///
/// The verification this file is built on: parse a lock Composer wrote, feed
/// its packages and settings straight back through `render`, and compare bytes.
/// Anything wrong about the key order, the sorting, the encoder or the trailing
/// newline shows up as a diff against a file this code did not produce.
///
/// It is also a real diagnostic — it answers "is this lock in canonical form,
/// or did something hand-edit it".
pub fn reRender(allocator: std.mem.Allocator, lock_source: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, lock_source, .{});
    if (parsed != .object) return error.MalformedLock;
    const root = parsed.object;

    var data: Data = .{
        .content_hash = strOf(root, "content-hash") orelse "",
        .packages = try packagesOf(allocator, root.get("packages")),
        .minimum_stability = strOf(root, "minimum-stability") orelse "stable",
        .stability_flags = root.get("stability-flags"),
        .prefer_stable = boolOf(root, "prefer-stable"),
        .prefer_lowest = boolOf(root, "prefer-lowest"),
        .platform = root.get("platform"),
        .platform_dev = root.get("platform-dev"),
        .platform_overrides = root.get("platform-overrides"),
        // Absent stays absent — see the field's own note.
        .plugin_api_version = strOf(root, "plugin-api-version"),
    };

    // `null` and `[]` are different files; preserve whichever this one is.
    if (root.get("packages-dev")) |dev| {
        if (dev != .null) data.packages_dev = try packagesOf(allocator, dev);
    }
    if (root.get("aliases")) |al| {
        if (al == .array) data.aliases = al.array.items;
    }

    return render(allocator, data);
}

fn packagesOf(allocator: std.mem.Allocator, v: ?std.json.Value) ![]const Package {
    const val = v orelse return &.{};
    if (val != .array) return &.{};

    var out: std.ArrayList(Package) = .empty;
    for (val.array.items) |item| {
        if (item != .object) continue;
        try out.append(allocator, .{
            .name = strOf(item.object, "name") orelse "",
            .version = strOf(item.object, "version") orelse "",
            .raw = item,
            // Re-rendering must not ADD one; the source either had it or did not.
            .notification_url = null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn strOf(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolOf(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return if (v == .bool) v.bool else false;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the three edits lockPackages makes to a dumped package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\{"name":"a/b","version":"1.0.0","version_normalized":"1.0.0.0",
        \\ "time":"2024-01-01T00:00:00+00:00","installation-source":"dist",
        \\ "type":"library","require":{"z/z":"^1","a/a":"^2"},"description":"x"}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
    const obj = try canonicalise(a, parsed, null);

    var keys: std.ArrayList([]const u8) = .empty;
    var it = obj.iterator();
    while (it.next()) |e| try keys.append(a, e.key_ptr.*);

    // version_normalized and installation-source are gone; time is LAST; the
    // require map is ksorted; and description follows type, not the file order.
    try testing.expectEqualStrings("name", keys.items[0]);
    try testing.expectEqualStrings("version", keys.items[1]);
    try testing.expectEqualStrings("require", keys.items[2]);
    try testing.expectEqualStrings("type", keys.items[3]);
    try testing.expectEqualStrings("description", keys.items[4]);
    try testing.expectEqualStrings("time", keys.items[keys.items.len - 1]);
    try testing.expectEqual(@as(usize, 6), keys.items.len);

    var req_keys = obj.get("require").?.object.iterator();
    try testing.expectEqualStrings("a/a", req_keys.next().?.key_ptr.*);
    try testing.expectEqualStrings("z/z", req_keys.next().?.key_ptr.*);
}

test "an empty link map is omitted, not written as an empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"a/b","version":"1.0.0","require":{},"extra":{}}
    , .{});
    const obj = try canonicalise(a, parsed, null);

    try testing.expect(obj.get("require") == null);
    // And `extra` goes too: `dumpValues` skips any value that is an empty PHP
    // array, which an empty JSON object decodes to. Composer's own output for
    // `psr/container` proved this — it carries no `"funding": []`.
    try testing.expect(obj.get("extra") == null);
}

test "a field Composer does not model is DROPPED" {
    // packagist sends `published-time` on every package and no lock contains
    // it, because Composer's round trip is ArrayLoader → Package →
    // ArrayDumper and the loader has no property for it. Keeping it produces a
    // file Composer rewrites on its next command.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"a/b","version":"1.0.0","published-time":"2021-11-05T16:53:27+00:00"}
    , .{});
    const obj = try canonicalise(a, parsed, null);
    try testing.expect(obj.get("published-time") == null);
    try testing.expectEqual(@as(usize, 2), obj.count());
}

test "source and dist are re-emitted in ArrayDumper's field order" {
    // packagist sends url before type and shasum before reference. Passing the
    // object through verbatim is a diff on every package in the file.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"a/b","version":"1.0.0",
        \\ "source":{"url":"u","type":"git","reference":"r"},
        \\ "dist":{"url":"u","shasum":"","type":"zip","reference":"r"}}
    , .{});
    const obj = try canonicalise(a, parsed, null);

    var src_it = obj.get("source").?.object.iterator();
    try testing.expectEqualStrings("type", src_it.next().?.key_ptr.*);
    try testing.expectEqualStrings("url", src_it.next().?.key_ptr.*);
    try testing.expectEqualStrings("reference", src_it.next().?.key_ptr.*);

    var dist_it = obj.get("dist").?.object.iterator();
    try testing.expectEqualStrings("type", dist_it.next().?.key_ptr.*);
    try testing.expectEqualStrings("url", dist_it.next().?.key_ptr.*);
    try testing.expectEqualStrings("reference", dist_it.next().?.key_ptr.*);
    try testing.expectEqualStrings("shasum", dist_it.next().?.key_ptr.*);
}

test "packages sort by name, ties broken by version, byte-wise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pkgs = [_]Package{
        .{ .name = "b/x", .version = "1.0.0", .raw = .null },
        .{ .name = "a/x", .version = "2.0.0", .raw = .null },
        .{ .name = "a/x", .version = "10.0.0", .raw = .null },
    };
    std.mem.sort(Package, &pkgs, {}, byNameThenVersion);

    try testing.expectEqualStrings("a/x", pkgs[0].name);
    // strcmp, not semver: "10.0.0" sorts BEFORE "2.0.0". Composer does this,
    // and matching it matters more than the ordering being sensible.
    try testing.expectEqualStrings("10.0.0", pkgs[0].version);
    try testing.expectEqualStrings("2.0.0", pkgs[1].version);
    try testing.expectEqualStrings("b/x", pkgs[2].name);
    _ = a;
}

test "packages-dev distinguishes null from empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const without = try render(a, .{ .content_hash = "x", .packages = &.{} });
    try testing.expect(std.mem.indexOf(u8, without, "\"packages-dev\": null") != null);

    const empty = try render(a, .{ .content_hash = "x", .packages = &.{}, .packages_dev = &.{} });
    try testing.expect(std.mem.indexOf(u8, empty, "\"packages-dev\": []") != null);
}

test "a rendered lock ends with exactly one newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try render(a, .{ .content_hash = "x", .packages = &.{} });
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
    try testing.expectEqual(@as(u8, '}'), out[out.len - 2]);
}

test "re-rendering a Composer 1 lock does not invent plugin-api-version" {
    // A real shape: `theseer/tokenizer` ships a lock that predates the field
    // and writes its empty maps as `[]`. Re-rendering it must reproduce it, or
    // the round-trip check reports this renderer as broken every time it meets
    // an older file — 15 times over, in one workspace.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\{
        \\    "_readme": [
        \\        "This file locks the dependencies of your project to a known state",
        \\        "Read more about it at https://getcomposer.org/doc/01-basic-usage.md#installing-dependencies",
        \\        "This file is @generated automatically"
        \\    ],
        \\    "content-hash": "b010f1b3d9d47d431ee1cb54ac1de755",
        \\    "packages": [],
        \\    "packages-dev": [],
        \\    "aliases": [],
        \\    "minimum-stability": "stable",
        \\    "stability-flags": [],
        \\    "prefer-stable": false,
        \\    "prefer-lowest": false,
        \\    "platform": {
        \\        "php": "^7.2 || ^8.0"
        \\    },
        \\    "platform-dev": []
        \\}
        \\
    ;

    try testing.expectEqualStrings(source, try reRender(a, source));
}

test "PHP's empty() drops a homepage that is an empty string" {
    // The last difference between this renderer and Composer's output on a
    // real 37-package tree. `ArrayLoader` guards `homepage` with `!empty()`,
    // so packagist's `"homepage": ""` never reaches the package object — and a
    // dump-time "is it an empty array" check does not catch it, because a
    // string is not an array.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name":"a/b","version":"1.0.0","homepage":"","description":"kept","license":[]}
    , .{});
    const obj = try canonicalise(a, parsed, null);

    try testing.expect(obj.get("homepage") == null);
    try testing.expect(obj.get("license") == null);
    try testing.expect(obj.get("description") != null);
}

test "PHP's empty() is stricter than it looks" {
    try testing.expect(isPhpEmpty(.{ .string = "0" }));
    try testing.expect(isPhpEmpty(.{ .integer = 0 }));
    try testing.expect(isPhpEmpty(.{ .bool = false }));
    try testing.expect(!isPhpEmpty(.{ .string = "0.0" }));
    try testing.expect(!isPhpEmpty(.{ .bool = true }));
}
