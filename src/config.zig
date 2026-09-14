//! `config` and `init` — reading and writing `composer.json` itself.
//!
//! `config` is the command that keeps a manifest edit out of an editor: setting
//! `config.vendor-dir` by hand is easy to get wrong in a file that already has
//! a `config` block, and the whole point of `jsonedit.zig` is that doing it
//! this way changes one line rather than reformatting the file.
//!
//! The key space is Composer's, and it is not flat. `vendor-dir` means
//! `config.vendor-dir`; `name` means the top-level `name`. A key naming a
//! section this package does not know is still settable — the manifest is the
//! project's, not this tool's, and refusing to write a key because it is not on
//! a list would make `config` useless the day Composer adds one.

const std = @import("std");
const jsonedit = @import("jsonedit.zig");
const manifest = @import("manifest.zig");
const phpjson = @import("phpjson.zig");
const util = @import("util.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Top-level keys that are NOT nested under `config`.
///
/// Everything else a bare key names goes to `config.<key>`, which is what
/// `composer config vendor-dir lib/vendor` does.
const root_level = [_][]const u8{
    "name",              "description",   "version",              "type",
    "keywords",          "homepage",      "readme",               "time",
    "license",           "authors",       "support",              "funding",
    "minimum-stability", "prefer-stable", "autoload",             "autoload-dev",
    "repositories",      "extra",         "scripts",              "bin",
    "archive",           "abandoned",     "non-feature-branches",
};

/// The dotted path a key resolves to.
///
/// `["config", "vendor-dir"]` for `vendor-dir`, `["name"]` for `name`,
/// `["extra", "branch-alias"]` for `extra.branch-alias`.
pub fn pathOf(allocator: std.mem.Allocator, key: []const u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |p| if (p.len > 0) try parts.append(allocator, p);
    if (parts.items.len == 0) return parts.toOwnedSlice(allocator);

    const head = parts.items[0];
    for (root_level) |r| {
        if (std.mem.eql(u8, head, r)) return parts.toOwnedSlice(allocator);
    }
    if (std.mem.eql(u8, head, "config")) return parts.toOwnedSlice(allocator);

    // A bare key is a `config` key.
    var prefixed: std.ArrayList([]const u8) = .empty;
    try prefixed.append(allocator, "config");
    try prefixed.appendSlice(allocator, parts.items);
    return prefixed.toOwnedSlice(allocator);
}

/// `hkm ppkg config <key>` — print one value.
pub fn get(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, key: []const u8) !u8 {
    const source = try read(allocator, io, root_dir) orelse return 1;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
        prompt.err("composer.json could not be parsed.");
        return 1;
    };

    const path = try pathOf(allocator, key);
    var cursor = parsed;
    for (path) |segment| {
        if (cursor != .object) {
            prompt.err(try std.fmt.allocPrint(allocator, "'{s}' is not set.", .{key}));
            return 1;
        }
        cursor = cursor.object.get(segment) orelse {
            prompt.err(try std.fmt.allocPrint(allocator, "'{s}' is not set.", .{key}));
            return 1;
        };
    }

    prompt.raw(try render(allocator, cursor));
    return 0;
}

/// `hkm ppkg config --list` — every key that is set, in dotted form.
pub fn list(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !u8 {
    const source = try read(allocator, io, root_dir) orelse return 1;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
        prompt.err("composer.json could not be parsed.");
        return 1;
    };
    if (parsed != .object) return 1;

    prompt.section("composer.json");
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        // One level of nesting is expanded, which is where every settable key
        // lives; a deeper tree is printed as the JSON it is rather than
        // flattened into paths nothing can set.
        if (e.value_ptr.* == .object and isFlat(e.value_ptr.object)) {
            var inner = e.value_ptr.object.iterator();
            while (inner.next()) |sub| {
                prompt.item(
                    try std.fmt.allocPrint(allocator, "{s}.{s}", .{ e.key_ptr.*, sub.key_ptr.* }),
                    try render(allocator, sub.value_ptr.*),
                );
            }
            continue;
        }
        prompt.item(e.key_ptr.*, try render(allocator, e.value_ptr.*));
    }
    prompt.blank();
    return 0;
}

/// `hkm ppkg config <key> <value>` — set one value.
///
/// The value is read as JSON when it parses as JSON (`true`, `42`, `["a"]`) and
/// as a string otherwise, which is how `config sort-packages true` sets a bool
/// and `config vendor-dir lib/vendor` sets a string without either needing
/// quoting rules of its own.
pub fn set(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    key: []const u8,
    raw_value: []const u8,
) !u8 {
    const path = try pathOf(allocator, key);
    if (path.len == 0 or path.len > 2) {
        prompt.err("config: only top-level keys and one level of nesting can be set.");
        return 2;
    }

    const source = try read(allocator, io, root_dir) orelse return 1;
    var doc = jsonedit.Document.init(allocator, source) catch {
        prompt.err("composer.json is not a JSON object.");
        return 1;
    };

    const value = parseValue(allocator, raw_value);
    const ok = if (path.len == 1)
        try doc.addMainKey(path[0], value)
    else
        try doc.addSubNode(path[0], path[1], value);

    if (!ok) {
        prompt.err(try std.fmt.allocPrint(allocator, "config: could not set '{s}'.", .{key}));
        return 1;
    }

    try util.writeFileAtomic(io, try path_of(allocator, root_dir), try doc.output());
    prompt.item(key, try render(allocator, value));
    return 0;
}

/// `hkm ppkg config --unset <key>`.
pub fn unset(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, key: []const u8) !u8 {
    const path = try pathOf(allocator, key);
    if (path.len == 0 or path.len > 2) {
        prompt.err("config: only top-level keys and one level of nesting can be unset.");
        return 2;
    }

    const source = try read(allocator, io, root_dir) orelse return 1;
    var doc = jsonedit.Document.init(allocator, source) catch {
        prompt.err("composer.json is not a JSON object.");
        return 1;
    };

    if (path.len == 1) {
        _ = try doc.removeMainKey(path[0]);
    } else {
        _ = try doc.removeSubNode(path[0], path[1]);
        // An emptied `config` block is noise; Composer's own `--unset` leaves
        // it, but leaving `"config": {}` behind is a diff for no reason.
        _ = try doc.removeMainKeyIfEmpty(path[0]);
    }

    try util.writeFileAtomic(io, try path_of(allocator, root_dir), try doc.output());
    prompt.item(key, "unset");
    return 0;
}

// ── init ──────────────────────────────────────────────────────────────────────

pub const InitOptions = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    kind: []const u8 = "",
    license: []const u8 = "",
    homepage: []const u8 = "",
    author: []const u8 = "",
    /// `--require vendor/pkg:^1.0`, already split.
    require: []const manifest.Dep = &.{},
    require_dev: []const manifest.Dep = &.{},
    /// `--autoload src/` → a psr-4 rule for a namespace derived from the name.
    autoload: []const u8 = "",
    stability: []const u8 = "",
    /// Overwrite an existing composer.json.
    force: bool = false,
};

/// `hkm ppkg init` — write a new `composer.json`.
///
/// Composer's `init` is interactive and guesses the vendor name from the
/// directory and the author from `git config`. This writes exactly what it is
/// given, and refuses to overwrite: a project's manifest is the one file whose
/// accidental replacement loses information nothing else holds.
pub fn init(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    opts: InitOptions,
) !u8 {
    const target = try path_of(allocator, root_dir);
    if (!opts.force and util.fileExists(io, target)) {
        prompt.err("composer.json already exists here. Pass --force to replace it.");
        return 1;
    }

    if (opts.name.len == 0 or std.mem.indexOfScalar(u8, opts.name, '/') == null) {
        prompt.err("init: --name must be given as vendor/package.");
        return 2;
    }

    // Built as a value and pretty-printed, NOT assembled with `jsonedit`.
    // That module exists to preserve formatting a human chose; a file that does
    // not exist yet has no formatting to preserve, and Composer's own `init`
    // writes through `JsonFile::encode` for the same reason.
    //
    // The key ORDER below is Composer's, recorded from `composer init -n` with
    // every option supplied. It is not the order the options are documented in,
    // and it is not alphabetical — `license` lands after `require-dev` and
    // `minimum-stability` last — so it is copied rather than reasoned about.
    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "name", .{ .string = opts.name });
    if (opts.description.len > 0) try root.put(allocator, "description", .{ .string = opts.description });
    if (opts.kind.len > 0) try root.put(allocator, "type", .{ .string = opts.kind });
    if (opts.homepage.len > 0) try root.put(allocator, "homepage", .{ .string = opts.homepage });

    if (opts.require.len > 0) try root.put(allocator, "require", try linkObject(allocator, opts.require));
    if (opts.require_dev.len > 0) try root.put(allocator, "require-dev", try linkObject(allocator, opts.require_dev));

    if (opts.license.len > 0) try root.put(allocator, "license", .{ .string = opts.license });

    if (opts.autoload.len > 0) {
        // `acme/my-app` + `src/` → `Acme\MyApp\` => `src/`, which is the rule
        // Composer's interactive init offers and almost everyone accepts.
        var psr4: std.json.ObjectMap = .empty;
        try psr4.put(allocator, try namespaceFor(allocator, opts.name), .{ .string = opts.autoload });
        var block: std.json.ObjectMap = .empty;
        try block.put(allocator, "psr-4", .{ .object = psr4 });
        try root.put(allocator, "autoload", .{ .object = block });
    }

    if (opts.author.len > 0) {
        var author: std.json.ObjectMap = .empty;
        const parsed = splitAuthor(opts.author);
        try author.put(allocator, "name", .{ .string = parsed.name });
        if (parsed.email.len > 0) try author.put(allocator, "email", .{ .string = parsed.email });
        var arr: std.ArrayList(std.json.Value) = .empty;
        try arr.append(allocator, .{ .object = author });
        try root.put(allocator, "authors", .{ .array = .fromOwnedSlice(allocator, try arr.toOwnedSlice(allocator)) });
    }

    if (opts.stability.len > 0) try root.put(allocator, "minimum-stability", .{ .string = opts.stability });

    var out: std.ArrayList(u8) = .empty;
    try phpjson.encode(allocator, &out, .{ .object = root }, .{
        .escape_slashes = false,
        .escape_unicode = false,
        .pretty = true,
    });
    try out.append(allocator, '\n');

    try util.writeFileAtomic(io, target, out.items);
    prompt.ok(try std.fmt.allocPrint(allocator, "Wrote {s}", .{target}));
    prompt.raw(out.items);
    return 0;
}

/// `acme/my-app` → `Acme\MyApp\` — each `-` or `_` separated word capitalised.
pub fn namespaceFor(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        var words = std.mem.splitAny(u8, segment, "-_.");
        while (words.next()) |word| {
            if (word.len == 0) continue;
            try out.append(allocator, std.ascii.toUpper(word[0]));
            try out.appendSlice(allocator, word[1..]);
        }
        try out.appendSlice(allocator, "\\");
    }
    return out.toOwnedSlice(allocator);
}

/// `[{name, constraint}]` → `{"name": "constraint"}`, in the order given.
fn linkObject(allocator: std.mem.Allocator, deps: []const manifest.Dep) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (deps) |dep| try obj.put(allocator, dep.name, .{ .string = dep.constraint });
    return .{ .object = obj };
}

const Author = struct { name: []const u8, email: []const u8 };

/// `Jane Doe <jane@example.com>` — the form Composer's `--author` takes.
fn splitAuthor(raw: []const u8) Author {
    const open = std.mem.indexOfScalar(u8, raw, '<') orelse return .{ .name = raw, .email = "" };
    const close = std.mem.lastIndexOfScalar(u8, raw, '>') orelse return .{ .name = raw, .email = "" };
    if (close < open) return .{ .name = raw, .email = "" };
    return .{
        .name = std.mem.trim(u8, raw[0..open], " \t"),
        .email = std.mem.trim(u8, raw[open + 1 .. close], " \t"),
    };
}

// ── shared ────────────────────────────────────────────────────────────────────

fn path_of(allocator: std.mem.Allocator, root_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
}

fn read(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !?[]const u8 {
    const path = try path_of(allocator, root_dir);
    return Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch {
        prompt.err("No composer.json here.");
        return null;
    };
}

/// `true` / `42` / `["a","b"]` are read as JSON; anything else is a string.
fn parseValue(allocator: std.mem.Allocator, raw: []const u8) std.json.Value {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .{ .string = raw };

    const looks_structured = trimmed[0] == '{' or trimmed[0] == '[' or
        std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false") or
        std.mem.eql(u8, trimmed, "null") or
        (std.ascii.isDigit(trimmed[0]) or trimmed[0] == '-');
    if (!looks_structured) return .{ .string = raw };

    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{}) catch
        .{ .string = raw };
}

fn render(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    if (v == .string) return v.string;
    var out: std.ArrayList(u8) = .empty;
    try phpjson.encode(allocator, &out, v, .{ .escape_slashes = false, .escape_unicode = false });
    return out.toOwnedSlice(allocator);
}

/// An object with no object or array values in it — safe to print as `a.b`.
fn isFlat(o: std.json.ObjectMap) bool {
    var it = o.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .object or e.value_ptr.* == .array) return false;
    }
    return true;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a bare key means config.<key>, a known root key means itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vendor = try pathOf(a, "vendor-dir");
    try testing.expectEqual(@as(usize, 2), vendor.len);
    try testing.expectEqualStrings("config", vendor[0]);
    try testing.expectEqualStrings("vendor-dir", vendor[1]);

    const name = try pathOf(a, "name");
    try testing.expectEqual(@as(usize, 1), name.len);
    try testing.expectEqualStrings("name", name[0]);

    // Already spelled out, and a nested non-config section.
    const explicit = try pathOf(a, "config.sort-packages");
    try testing.expectEqualStrings("config", explicit[0]);
    try testing.expectEqualStrings("sort-packages", explicit[1]);

    const extra = try pathOf(a, "extra.branch-alias");
    try testing.expectEqualStrings("extra", extra[0]);
    try testing.expectEqualStrings("branch-alias", extra[1]);
}

test "a value is JSON when it parses as JSON, and a string otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(parseValue(a, "true").bool);
    try testing.expectEqual(@as(i64, 42), parseValue(a, "42").integer);
    try testing.expectEqual(@as(usize, 2), parseValue(a, "[\"a\",\"b\"]").array.items.len);

    // The cases that must NOT be read as JSON: a path, a version, a word.
    try testing.expectEqualStrings("lib/vendor", parseValue(a, "lib/vendor").string);
    try testing.expectEqualStrings("php-only", parseValue(a, "php-only").string);
    // A bare version looks numeric and is not valid JSON; it stays a string.
    try testing.expectEqualStrings("8.4.1", parseValue(a, "8.4.1").string);
}

test "a namespace is derived from the package name the way init offers it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("Acme\\MyApp\\", try namespaceFor(a, "acme/my-app"));
    try testing.expectEqualStrings("AlfacodeTeam\\Http\\", try namespaceFor(a, "alfacode-team/http"));
    try testing.expectEqualStrings("Psr\\Log\\", try namespaceFor(a, "psr/log"));
}

test "an author splits into name and email" {
    const full = splitAuthor("Jane Doe <jane@example.com>");
    try testing.expectEqualStrings("Jane Doe", full.name);
    try testing.expectEqualStrings("jane@example.com", full.email);

    const bare = splitAuthor("Jane Doe");
    try testing.expectEqualStrings("Jane Doe", bare.name);
    try testing.expectEqualStrings("", bare.email);
}
