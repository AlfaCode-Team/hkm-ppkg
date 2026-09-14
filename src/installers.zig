//! `extra.installer-paths` — putting a package somewhere other than `vendor/`.
//!
//! ## Why this is here and not in `compat`'s refusal list
//!
//! This is the one composer PLUGIN behaviour that cannot be reported and
//! skipped. Every other plugin generates a file, prints a notice or registers a
//! command: skipping it leaves a tree that is correct and missing something.
//! `composer/installers` decides WHERE PACKAGES GO. Skip it and the tree is
//! wrong — a WordPress project's plugins land in `vendor/` while the
//! application looks for them in `web/app/plugins/`, and every symptom of that
//! points at the application rather than at the installer.
//!
//! So the mechanism is implemented natively, because it is pure data: the root
//! package declares a map of destination path to selection criteria, and a
//! package's install path is the first entry that matches it. There is no PHP
//! semantics in that, and it can be verified against Composer's own output.
//!
//! ## What is implemented, exactly
//!
//! `composer/installers`' ROOT-PACKAGE mechanism:
//!
//!     "extra": { "installer-paths": {
//!         "web/app/plugins/{$name}/": ["type:wordpress-plugin"],
//!         "web/app/themes/{$name}/":  ["vendor:acme"],
//!         "special/place/":           ["acme/one-off"]
//!     }}
//!
//! Criteria are `type:<x>`, `vendor:<x>`, or a literal `vendor/package`. The
//! first PATH whose criteria list matches wins, and the map's declaration order
//! is what "first" means — so a specific rule must be written above a general
//! one, exactly as with Composer.
//!
//! Placeholders are `{$name}`, `{$vendor}` and `{$type}`.
//!
//! ## What is NOT implemented
//!
//! `composer/installers`' BUILT-IN table — its hundred-odd framework classes
//! that place a `drupal-module` under `web/modules/contrib/` with no
//! `installer-paths` entry at all. That table is not data this package can read;
//! it is a hundred PHP classes, several with their own name inflection, and
//! guessing at it would produce a tree that is wrong in a way nothing reports.
//! A project relying on the built-in table is told so by `compat`.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const Rule = struct {
    /// The destination, with placeholders unexpanded: `web/app/plugins/{$name}/`.
    path: []const u8,
    /// `type:wordpress-plugin`, `vendor:acme`, `acme/thing`.
    criteria: []const []const u8,
};

/// Read `extra.installer-paths` from a root manifest's raw JSON.
///
/// Declaration order is preserved and load-bearing: the first matching path
/// wins, which is how a rule for one package overrides a rule for its type.
pub fn rulesOf(allocator: std.mem.Allocator, root_json: std.json.Value) ![]const Rule {
    if (root_json != .object) return &.{};
    const extra = root_json.object.get("extra") orelse return &.{};
    if (extra != .object) return &.{};
    const paths = extra.object.get("installer-paths") orelse return &.{};
    if (paths != .object) return &.{};

    var out: std.ArrayList(Rule) = .empty;
    var it = paths.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .array) continue;
        var criteria: std.ArrayList([]const u8) = .empty;
        for (entry.value_ptr.*.array.items) |c| {
            if (c == .string) try criteria.append(allocator, c.string);
        }
        if (criteria.items.len == 0) continue;
        try out.append(allocator, .{
            .path = entry.key_ptr.*,
            .criteria = try criteria.toOwnedSlice(allocator),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Where a package goes, relative to the project root, or null for `vendor/`.
pub fn pathFor(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    name: []const u8,
    kind: []const u8,
) !?[]const u8 {
    for (rules) |rule| {
        if (!matches(rule.criteria, name, kind)) continue;
        return try expand(allocator, rule.path, name, kind);
    }
    return null;
}

fn matches(criteria: []const []const u8, name: []const u8, kind: []const u8) bool {
    for (criteria) |c| {
        if (std.mem.startsWith(u8, c, "type:")) {
            if (std.mem.eql(u8, c["type:".len..], kind)) return true;
            continue;
        }
        if (std.mem.startsWith(u8, c, "vendor:")) {
            const want = c["vendor:".len..];
            const slash = std.mem.indexOfScalar(u8, name, '/') orelse continue;
            if (std.mem.eql(u8, name[0..slash], want)) return true;
            continue;
        }
        // Anything else is a literal package name.
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

/// Substitute `{$name}`, `{$vendor}` and `{$type}`, and drop the trailing slash.
///
/// The trailing slash is Composer's convention in the declaration and is NOT
/// part of the path: `installed.json` records `../../web/app/plugins/akismet`,
/// with no slash, and a stray one would put an empty segment in every generated
/// autoload path built from it.
fn expand(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    name: []const u8,
    kind: []const u8,
) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, name, '/');
    const vendor = if (slash) |at| name[0..at] else "";
    const short = if (slash) |at| name[at + 1 ..] else name;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '{' and i + 1 < pattern.len and pattern[i + 1] == '$') {
            const close = std.mem.indexOfScalarPos(u8, pattern, i, '}') orelse {
                try out.append(allocator, pattern[i]);
                i += 1;
                continue;
            };
            const key = pattern[i + 2 .. close];
            if (std.mem.eql(u8, key, "name")) {
                try out.appendSlice(allocator, short);
            } else if (std.mem.eql(u8, key, "vendor")) {
                try out.appendSlice(allocator, vendor);
            } else if (std.mem.eql(u8, key, "type")) {
                try out.appendSlice(allocator, kind);
            } else {
                // An unknown placeholder is left exactly as written rather than
                // silently deleted — a path with a visible `{$foo}` in it is a
                // mistake someone can see.
                try out.appendSlice(allocator, pattern[i .. close + 1]);
            }
            i = close + 1;
            continue;
        }
        try out.append(allocator, pattern[i]);
        i += 1;
    }

    const trimmed = std.mem.trimEnd(u8, out.items, "/");
    return allocator.dupe(u8, trimmed);
}

/// Does this project rely on `composer/installers`' BUILT-IN table?
///
/// That is: the plugin is installed, but the root declares no
/// `installer-paths`. Then every placement decision comes from the plugin's own
/// hundred framework classes, none of which are implemented here — and the
/// result would be a tree in the wrong place rather than a tree with something
/// missing. Reported by `compat` as blocking.
pub fn needsBuiltinTable(rules: []const Rule, installed_names: []const []const u8) bool {
    if (rules.len > 0) return false;
    for (installed_names) |n| {
        if (std.mem.eql(u8, n, "composer/installers")) return true;
        if (std.mem.eql(u8, n, "oomphinc/composer-installers-extender")) return true;
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn rulesFrom(allocator: std.mem.Allocator, json: []const u8) []const Rule {
    const v = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch unreachable;
    return rulesOf(allocator, v) catch unreachable;
}

test "a package is placed by the first rule that matches it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rules = rulesFrom(a,
        \\{"extra":{"installer-paths":{
        \\  "web/app/mu-plugins/{$name}/": ["acme/must-use"],
        \\  "web/app/plugins/{$name}/":    ["type:wordpress-plugin"],
        \\  "web/app/themes/{$name}/":     ["type:wordpress-theme"]
        \\}}}
    );
    try testing.expectEqual(@as(usize, 3), rules.len);

    try testing.expectEqualStrings(
        "web/app/plugins/akismet",
        (try pathFor(a, rules, "wpackagist-plugin/akismet", "wordpress-plugin")).?,
    );
    try testing.expectEqualStrings(
        "web/app/themes/twenty",
        (try pathFor(a, rules, "wpackagist-theme/twenty", "wordpress-theme")).?,
    );

    // A literal package name beats the type rule below it, because the map's
    // order is the precedence — the same as Composer's.
    try testing.expectEqualStrings(
        "web/app/mu-plugins/must-use",
        (try pathFor(a, rules, "acme/must-use", "wordpress-plugin")).?,
    );

    // Nothing matches: the package stays in vendor/, which is what null means.
    try testing.expect((try pathFor(a, rules, "psr/log", "library")) == null);
}

test "vendor: matches every package from one vendor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rules = rulesFrom(a,
        \\{"extra":{"installer-paths":{"local/{$vendor}/{$name}/": ["vendor:acme"]}}}
    );
    try testing.expectEqualStrings("local/acme/one", (try pathFor(a, rules, "acme/one", "library")).?);
    try testing.expectEqualStrings("local/acme/two", (try pathFor(a, rules, "acme/two", "library")).?);
    // And not a vendor that merely starts the same way.
    try testing.expect((try pathFor(a, rules, "acmecorp/three", "library")) == null);
}

test "every placeholder is substituted, and an unknown one is left visible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("a/library/acme/thing", try expand(a, "a/{$type}/{$vendor}/{$name}/", "acme/thing", "library"));
    // Deleting an unknown placeholder would produce a plausible-looking wrong
    // path; leaving it makes the mistake visible in the tree.
    try testing.expectEqualStrings("x/{$branch}/thing", try expand(a, "x/{$branch}/{$name}", "acme/thing", "library"));
}

test "the built-in table is only claimed when there is no declaration to use instead" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const declared = rulesFrom(a, "{\"extra\":{\"installer-paths\":{\"p/{$name}/\":[\"type:x\"]}}}");
    try testing.expect(!needsBuiltinTable(declared, &.{"composer/installers"}));

    // Installed, and nothing declared for it to read — every placement would
    // come from the table this does not implement.
    try testing.expect(needsBuiltinTable(&.{}, &.{"composer/installers"}));
    try testing.expect(!needsBuiltinTable(&.{}, &.{"psr/log"}));
}

test "a malformed declaration contributes nothing rather than a broken rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), rulesFrom(a, "{}").len);
    try testing.expectEqual(@as(usize, 0), rulesFrom(a, "{\"extra\":{\"installer-paths\":\"nope\"}}").len);
    // A path with an empty criteria list matches nothing, so it is dropped
    // rather than kept as a rule that would match everything.
    try testing.expectEqual(@as(usize, 0), rulesFrom(a, "{\"extra\":{\"installer-paths\":{\"p/\":[]}}}").len);
}
