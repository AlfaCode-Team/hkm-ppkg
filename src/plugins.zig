//! Composer PLUGINS — what is installed, what would run, and what does not.
//!
//! ## The honest position, stated once
//!
//! Composer plugins are PHP classes that Composer instantiates and hands its own
//! object graph to: `Composer\Composer`, `InstallationManager`,
//! `RepositoryManager`, `IOInterface`, `EventDispatcher`, and the package model
//! underneath all of them. A plugin then calls whatever it likes on that graph.
//!
//! Running one therefore means providing that graph. There are two ways to do
//! that and this package does neither:
//!
//!   * depend on `composer/composer` itself and build a real graph — which
//!     makes a Composer replacement require Composer;
//!   * ship a PHP shim implementing the subset each plugin happens to use —
//!     which works until a plugin touches a method the shim does not have, and
//!     then fails PART WAY THROUGH, having already written some of its output.
//!     A plugin that half-ran is worse than one that did not run: the tree
//!     looks finished and is not.
//!
//! Measured on the three plugins this workspace actually uses, the second
//! option's surface includes `Composer\Semver\Intervals` and the whole
//! constraint object model — so "a small shim" is not what it would be.
//!
//! So: plugins do not run, and this file exists to make that FACT LEGIBLE
//! rather than generic. It names every plugin installed, says whether the
//! project allowed it, and says what that specific plugin would have done, so
//! the reader can decide whether it matters instead of discovering it from a
//! missing file three commands later.
//!
//! ## The one exception
//!
//! `composer/installers` decides where packages GO, and a wrong location is not
//! a missing extra — it is a broken tree. Its root-package mechanism,
//! `extra.installer-paths`, is pure data and IS implemented, natively, in
//! `installers.zig`. Its built-in framework table is not, and a project that
//! relies on that is told so.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const Plugin = struct {
    name: []const u8,
    /// `extra.class` — the entry point Composer would instantiate.
    class: []const u8,
    /// Present in `config.allow-plugins` with a truthy value.
    ///
    /// A plugin that the project has NOT allowed would not run under Composer
    /// either, so it is not a gap; saying so keeps the report honest in both
    /// directions.
    allowed: bool,
    /// What this plugin does, when it is one this package recognises.
    effect: []const u8 = "",
};

/// Every installed package of type `composer-plugin`.
pub fn discover(
    allocator: std.mem.Allocator,
    installed: []const manifest.Manifest,
    root_json: std.json.Value,
) ![]const Plugin {
    var out: std.ArrayList(Plugin) = .empty;
    const allow = allowList(root_json);

    for (installed) |pkg| {
        if (!std.mem.eql(u8, pkg.kind, "composer-plugin")) continue;
        try out.append(allocator, .{
            .name = pkg.name,
            .class = pkg.plugin_class,
            .allowed = isAllowed(allow, pkg.name),
            .effect = effectOf(pkg.name),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// `config.allow-plugins`, as declared.
fn allowList(root_json: std.json.Value) ?std.json.ObjectMap {
    if (root_json != .object) return null;
    const config = root_json.object.get("config") orelse return null;
    if (config != .object) return null;
    const allow = config.object.get("allow-plugins") orelse return null;
    return switch (allow) {
        .object => |o| o,
        // `"allow-plugins": true` allows everything, which is a real (and
        // discouraged) spelling. There is no map to consult, so nothing is
        // recorded and `isAllowed` answers true for every name.
        else => null,
    };
}

fn isAllowed(allow: ?std.json.ObjectMap, name: []const u8) bool {
    const map = allow orelse return true;
    var it = map.iterator();
    while (it.next()) |e| {
        if (!wildcardMatch(e.key_ptr.*, name)) continue;
        return switch (e.value_ptr.*) {
            .bool => |b| b,
            else => false,
        };
    }
    return false;
}

/// `allow-plugins` keys accept `*` — `"acme/*": true` allows a whole vendor.
fn wildcardMatch(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    const head = pattern[0..star];
    const tail = pattern[star + 1 ..];
    if (name.len < head.len + tail.len) return false;
    return std.mem.startsWith(u8, name, head) and std.mem.endsWith(u8, name, tail);
}

/// What a plugin does, for the plugins whose effect is worth naming.
///
/// Deliberately short and specific. "Plugins are not loaded" tells a reader
/// nothing they can act on; "phpstan/extension-installer generates
/// GeneratedConfig.php, so phpstan will not auto-register extensions" tells
/// them exactly what to do instead.
pub fn effectOf(name: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{
            "composer/installers",
            "places packages outside vendor/ by framework type. The root-package mechanism (extra.installer-paths) IS implemented here; its built-in per-framework table is not.",
        },
        .{
            "phpstan/extension-installer",
            "generates vendor/phpstan/extension-installer/src/GeneratedConfig.php. Without it phpstan will not auto-register extensions — list them in phpstan.neon instead.",
        },
        .{
            "infection/extension-installer",
            "generates vendor/infection/extension-installer/src/GeneratedExtensionsConfig.php. Without it infection loads no extensions.",
        },
        .{
            "php-http/discovery",
            "pins a PSR-18 client and injects a generated discovery strategy. Without it discovery falls back to runtime probing, which still works when a client is installed.",
        },
        .{
            "dealerdirect/phpcodesniffer-composer-installer",
            "registers installed coding standards with phpcs. Without it, pass --standard with a path.",
        },
        .{
            "cweagans/composer-patches",
            "applies patch files to installed packages. Without it the packages are UNPATCHED — the one effect here whose absence is silent and material.",
        },
        .{
            "symfony/flex",
            "runs recipes: writes config, .env entries and bundles.php. Without it a new dependency is installed but not wired in.",
        },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return "";
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn rootFrom(allocator: std.mem.Allocator, json: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch unreachable;
}

test "only composer-plugin packages are reported, with their entry class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const installed = [_]manifest.Manifest{
        .{ .name = "psr/log", .kind = "library" },
        .{ .name = "phpstan/extension-installer", .kind = "composer-plugin", .plugin_class = "PHPStan\\ExtensionInstaller\\Plugin" },
    };
    const found = try discover(a, &installed, rootFrom(a,
        \\{"config":{"allow-plugins":{"phpstan/extension-installer": true}}}
    ));

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("phpstan/extension-installer", found[0].name);
    try testing.expectEqualStrings("PHPStan\\ExtensionInstaller\\Plugin", found[0].class);
    try testing.expect(found[0].allowed);
    // And the report says what it would have done, not that "plugins exist".
    try testing.expect(std.mem.indexOf(u8, found[0].effect, "GeneratedConfig.php") != null);
}

test "a plugin the project never allowed is reported as not allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const installed = [_]manifest.Manifest{
        .{ .name = "acme/plugin", .kind = "composer-plugin", .plugin_class = "Acme\\Plugin" },
    };

    // Composer would not run it either, so it is not a gap.
    const denied = try discover(a, &installed, rootFrom(a, "{\"config\":{\"allow-plugins\":{\"other/thing\": true}}}"));
    try testing.expect(!denied[0].allowed);

    const explicitly_off = try discover(a, &installed, rootFrom(a, "{\"config\":{\"allow-plugins\":{\"acme/plugin\": false}}}"));
    try testing.expect(!explicitly_off[0].allowed);

    // No `allow-plugins` block at all is Composer's "ask", which in a
    // non-interactive run means allow — and that is the state a project is in
    // before anyone has thought about it.
    const undeclared = try discover(a, &installed, rootFrom(a, "{}"));
    try testing.expect(undeclared[0].allowed);
}

test "an allow-plugins key may name a whole vendor with a wildcard" {
    try testing.expect(wildcardMatch("*", "anything/at-all"));
    try testing.expect(wildcardMatch("acme/*", "acme/one"));
    try testing.expect(!wildcardMatch("acme/*", "acmecorp/one"));
    try testing.expect(wildcardMatch("acme/one", "acme/one"));
    try testing.expect(!wildcardMatch("acme/one", "acme/two"));
}
