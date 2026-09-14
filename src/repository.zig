//! `repository` — reading and editing `composer.json`'s `repositories`.
//!
//! The one command that edits this list rather than reading it. It exists
//! because the list is the most security-relevant thing in a manifest: a
//! repository entry decides where code comes from, and hand-editing JSON to add
//! one is how a project ends up with a malformed entry that silently resolves
//! to Packagist instead.
//!
//! ## Two shapes, and why the array one is written
//!
//! Composer accepts `repositories` as an array or as an object keyed by name.
//! Both are read here. The ARRAY form is what gets written, because that is
//! what Composer's own `repository add` writes — down to the `[{` / `},{`
//! bracket style, which looks odd and is reproduced exactly so that a project
//! using both tools does not see the file churn between them.
//!
//! ## Order is priority
//!
//! A repository added with `add` goes to the FRONT, because Composer resolves
//! in declaration order and the reason to add one is almost always to have it
//! take precedence over Packagist. `--append` puts it last, and `--before` /
//! `--after` place it next to a named entry.

const std = @import("std");
const manifest = @import("manifest.zig");
const jsonedit = @import("jsonedit.zig");
const phpjson = @import("phpjson.zig");
const util = @import("util.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// The implicit repository every project has unless it turns it off.
pub const packagist_name = "packagist.org";
pub const packagist_url = "https://repo.packagist.org";

pub const Error = error{
    NoManifest,
    MalformedManifest,
    NotFound,
    BadDefinition,
};

/// Where a new entry goes.
pub const Placement = union(enum) {
    /// Front — highest priority. The default, and why `add` is normally used.
    prepend,
    /// Back — lowest priority.
    append,
    /// Immediately before the named entry.
    before: []const u8,
    /// Immediately after the named entry.
    after: []const u8,
};

pub const Entry = struct {
    /// The `name` key, or the object-form key. Composer generates
    /// `<type>-<index>` style names for unnamed array entries when it needs
    /// one; an unnamed entry here simply has none, and is addressed by URL.
    name: []const u8 = "",
    kind: []const u8 = "",
    url: []const u8 = "",
    /// `{"packagist.org": false}` — a repository being switched off rather
    /// than declared. It has no type or url, and must survive an edit intact.
    disabled_name: []const u8 = "",

    pub fn isDisableEntry(self: Entry) bool {
        return self.disabled_name.len > 0;
    }
};

/// Every repository this project declares, in priority order, with the
/// implicit Packagist entry appended unless it was switched off.
pub fn list(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) ![]const Entry {
    const doc = try readDoc(allocator, io, root_dir);
    const entries = try entriesOf(allocator, doc);

    var out: std.ArrayList(Entry) = .empty;
    var disabled: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (e.isDisableEntry()) {
            try disabled.append(allocator, e.disabled_name);
            continue;
        }
        try out.append(allocator, e);
    }

    // Composer lists Packagist because it is really there: a project that
    // declares nothing still resolves against it, and a listing that omitted
    // it would answer "where do packages come from" with the wrong answer.
    // A disabled one is listed too, as disabled — the difference between "you
    // turned this off" and "this was never here" is the whole reason someone
    // runs this command.
    if (!util.contains(disabled.items, packagist_name)) {
        try out.append(allocator, .{ .name = packagist_name, .kind = "composer", .url = packagist_url });
    }
    for (disabled.items) |name| {
        try out.append(allocator, .{ .name = name, .disabled_name = name });
    }
    return out.toOwnedSlice(allocator);
}

/// Add a repository. `definition` is either a bare type (with `url`) or a JSON
/// object, which is how a repository with options — `only`, `exclude`,
/// `canonical`, per-type keys — is declared.
pub fn add(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    name: []const u8,
    definition: []const u8,
    url: ?[]const u8,
    placement: Placement,
) !void {
    const path = try manifestPath(allocator, root_dir);
    const source = try readSource(allocator, io, path);

    var obj: std.json.ObjectMap = .empty;
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, definition, " \t"), "{")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, definition, .{}) catch
            return Error.BadDefinition;
        if (parsed != .object) return Error.BadDefinition;
        // Name first, then whatever the definition declared. Composer writes
        // the name into the object rather than keying by it, so an entry
        // remains addressable after a hand edit reorders the list.
        try obj.put(allocator, "name", .{ .string = name });
        var it = parsed.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "name")) continue;
            try obj.put(allocator, e.key_ptr.*, e.value_ptr.*);
        }
    } else {
        const target = url orelse return Error.BadDefinition;
        try obj.put(allocator, "name", .{ .string = name });
        try obj.put(allocator, "type", .{ .string = definition });
        try obj.put(allocator, "url", .{ .string = target });
    }

    var values = try rawValues(allocator, source);
    // Replacing rather than duplicating: `add` on an existing name is how a
    // definition is corrected, and two entries with one name is a state
    // Composer resolves by declaration order — i.e. invisibly.
    var replaced = false;
    for (values.items, 0..) |v, idx| {
        if (nameOf(v)) |n| {
            if (std.mem.eql(u8, n, name)) {
                values.items[idx] = .{ .object = obj };
                replaced = true;
                break;
            }
        }
    }

    if (!replaced) try insert(allocator, &values, .{ .object = obj }, placement);
    try writeBack(allocator, io, path, source, values.items);
}

/// Remove a repository by name.
pub fn remove(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    name: []const u8,
) !void {
    const path = try manifestPath(allocator, root_dir);
    const source = try readSource(allocator, io, path);
    const values = try rawValues(allocator, source);

    var kept: std.ArrayList(std.json.Value) = .empty;
    var found = false;
    for (values.items) |v| {
        const matches = if (nameOf(v)) |n| std.mem.eql(u8, n, name) else false;
        if (matches) {
            found = true;
            continue;
        }
        try kept.append(allocator, v);
    }
    if (!found) return Error.NotFound;
    try writeBack(allocator, io, path, source, kept.items);
}

/// `enable` / `disable`.
///
/// Disabling writes `{"<name>": false}`, which is Composer's spelling and the
/// only way to switch off a repository the project did not declare — Packagist
/// being the one that matters.
pub fn setEnabled(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    name: []const u8,
    enabled: bool,
) !void {
    const path = try manifestPath(allocator, root_dir);
    const source = try readSource(allocator, io, path);
    const values = try rawValues(allocator, source);

    var kept: std.ArrayList(std.json.Value) = .empty;
    for (values.items) |v| {
        if (disabledNameOf(v)) |n| {
            if (std.mem.eql(u8, n, name)) continue; // drop the old switch
        }
        try kept.append(allocator, v);
    }

    if (!enabled) {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(allocator, name, .{ .bool = false });
        // At the front: a disable that sits after the entry it disables is
        // still honoured by Composer, but reading the file top to bottom
        // should not show a repository whose next line takes it away.
        try kept.insert(allocator, 0, .{ .object = obj });
    }

    try writeBack(allocator, io, path, source, kept.items);
}

/// The URL of a named repository.
pub fn urlOf(allocator: std.mem.Allocator, io: Io, root_dir: []const u8, name: []const u8) ![]const u8 {
    for (try list(allocator, io, root_dir)) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.url;
    }
    return Error.NotFound;
}

/// Change a named repository's URL, leaving every other key alone.
pub fn setUrl(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    name: []const u8,
    url: []const u8,
) !void {
    const path = try manifestPath(allocator, root_dir);
    const source = try readSource(allocator, io, path);
    var values = try rawValues(allocator, source);

    var found = false;
    for (values.items, 0..) |v, idx| {
        if (v != .object) continue;
        const n = nameOf(v) orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;

        var obj: std.json.ObjectMap = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "url")) continue;
            try obj.put(allocator, e.key_ptr.*, e.value_ptr.*);
        }
        try obj.put(allocator, "url", .{ .string = url });
        values.items[idx] = .{ .object = obj };
        found = true;
        break;
    }
    if (!found) return Error.NotFound;

    try writeBack(allocator, io, path, source, values.items);
}

// ── reading ───────────────────────────────────────────────────────────────────

fn manifestPath(allocator: std.mem.Allocator, root_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
}

fn readSource(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    return Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch
        Error.NoManifest;
}

fn readDoc(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !std.json.Value {
    const source = try readSource(allocator, io, try manifestPath(allocator, root_dir));
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch
        return Error.MalformedManifest;
    if (parsed != .object) return Error.MalformedManifest;
    return parsed;
}

/// The `repositories` value, as a list, from either declaration shape.
fn rawValues(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(std.json.Value) {
    var out: std.ArrayList(std.json.Value) = .empty;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch
        return Error.MalformedManifest;
    if (parsed != .object) return Error.MalformedManifest;

    const repos = parsed.object.get("repositories") orelse return out;
    switch (repos) {
        .array => |a| for (a.items) |item| try out.append(allocator, item),
        .object => |o| {
            // The keyed form. Converting to the array form on write is what
            // Composer does too, and it keeps one shape in the file rather
            // than a project that has both.
            var it = o.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .bool) {
                    var obj: std.json.ObjectMap = .empty;
                    try obj.put(allocator, e.key_ptr.*, e.value_ptr.*);
                    try out.append(allocator, .{ .object = obj });
                    continue;
                }
                if (e.value_ptr.* != .object) continue;
                var obj: std.json.ObjectMap = .empty;
                try obj.put(allocator, "name", .{ .string = e.key_ptr.* });
                var inner = e.value_ptr.object.iterator();
                while (inner.next()) |kv| try obj.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
                try out.append(allocator, .{ .object = obj });
            }
        },
        else => {},
    }
    return out;
}

fn entriesOf(allocator: std.mem.Allocator, doc: std.json.Value) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    const repos = doc.object.get("repositories") orelse return out.toOwnedSlice(allocator);

    switch (repos) {
        .array => |a| for (a.items) |item| {
            if (entryOf(item, "")) |e| try out.append(allocator, e);
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                if (entryOf(kv.value_ptr.*, kv.key_ptr.*)) |e| try out.append(allocator, e);
            }
        },
        else => {},
    }
    return out.toOwnedSlice(allocator);
}

fn entryOf(value: std.json.Value, key: []const u8) ?Entry {
    if (value == .bool) {
        // `{"packagist.org": false}` in the object form.
        return if (!value.bool) Entry{ .disabled_name = key } else null;
    }
    if (value != .object) return null;

    if (disabledNameOf(value)) |n| return Entry{ .disabled_name = n };

    return Entry{
        .name = if (key.len > 0) key else strOf(value.object, "name") orelse "",
        .kind = strOf(value.object, "type") orelse "",
        .url = strOf(value.object, "url") orelse "",
    };
}

/// Is this the one-key `{"name": false}` shape?
fn disabledNameOf(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.count() != 1) return null;
    var it = value.object.iterator();
    const first = it.next() orelse return null;
    if (first.value_ptr.* != .bool or first.value_ptr.bool) return null;
    return first.key_ptr.*;
}

fn nameOf(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (disabledNameOf(value) != null) return null;
    return strOf(value.object, "name");
}

fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn insert(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(std.json.Value),
    value: std.json.Value,
    placement: Placement,
) !void {
    switch (placement) {
        .prepend => try values.insert(allocator, 0, value),
        .append => try values.append(allocator, value),
        .before => |who| {
            for (values.items, 0..) |v, idx| {
                if (nameOf(v)) |n| {
                    if (std.mem.eql(u8, n, who)) return values.insert(allocator, idx, value);
                }
            }
            return Error.NotFound;
        },
        .after => |who| {
            for (values.items, 0..) |v, idx| {
                if (nameOf(v)) |n| {
                    if (std.mem.eql(u8, n, who)) return values.insert(allocator, idx + 1, value);
                }
            }
            return Error.NotFound;
        },
    }
}

// ── writing ───────────────────────────────────────────────────────────────────

/// Replace the `repositories` key with `values`, rendered Composer's way.
fn writeBack(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    source: []const u8,
    values: []const std.json.Value,
) !void {
    var doc = jsonedit.Document.init(allocator, source) catch return Error.MalformedManifest;

    if (values.len == 0) {
        _ = try doc.removeMainKey("repositories");
        return util.writeFileAtomic(io, path, try doc.output());
    }

    const rendered = try render(allocator, values, doc.indent, doc.newline);
    _ = try doc.setMainKeyRaw("repositories", rendered);
    try util.writeFileAtomic(io, path, try doc.output());
}

/// Composer's array-of-objects style, bracket placement included.
///
///     "repositories": [{
///         "name": "foo",
///         "type": "vcs",
///         "url": "…"
///     },{
///         …
///     }]
///
/// The `},{` looks like a typo and is not: `JsonManipulator` writes it, so
/// reproducing it is what keeps a file edited by both tools from churning.
fn render(
    allocator: std.mem.Allocator,
    values: []const std.json.Value,
    indent: []const u8,
    newline: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "[");

    for (values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{");

        if (value == .object) {
            var it = value.object.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try out.appendSlice(allocator, ",");
                first = false;
                try out.appendSlice(allocator, newline);
                try out.appendSlice(allocator, indent);
                try out.appendSlice(allocator, indent);
                try encode(allocator, &out, .{ .string = e.key_ptr.* });
                try out.appendSlice(allocator, ": ");
                try encode(allocator, &out, e.value_ptr.*);
            }
        }

        try out.appendSlice(allocator, newline);
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "}");
    }

    try out.appendSlice(allocator, "]");
    return out.toOwnedSlice(allocator);
}

fn encode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    try phpjson.encode(allocator, out, value, .{ .escape_slashes = false, .escape_unicode = false });
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "render reproduces Composer's bracket style" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var one: std.json.ObjectMap = .empty;
    try one.put(a, "name", .{ .string = "foo" });
    try one.put(a, "type", .{ .string = "vcs" });
    try one.put(a, "url", .{ .string = "https://example.com/foo" });

    var two: std.json.ObjectMap = .empty;
    try two.put(a, "name", .{ .string = "zips" });
    try two.put(a, "type", .{ .string = "artifact" });
    try two.put(a, "url", .{ .string = "/tmp/zips" });

    const out = try render(a, &.{ .{ .object = one }, .{ .object = two } }, "    ", "\n");

    try testing.expectEqualStrings(
        \\[{
        \\        "name": "foo",
        \\        "type": "vcs",
        \\        "url": "https://example.com/foo"
        \\    },{
        \\        "name": "zips",
        \\        "type": "artifact",
        \\        "url": "/tmp/zips"
        \\    }]
    , out);
}

test "a disable switch is recognised in both shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"packagist.org": false}
    , .{});
    try testing.expectEqualStrings("packagist.org", disabledNameOf(parsed).?);

    // A two-key object is a declaration, not a switch — the count check is
    // what keeps `{"name": "x", "canonical": false}` from being read as one.
    const decl = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name": "x", "canonical": false}
    , .{});
    try testing.expect(disabledNameOf(decl) == null);
}

test "the keyed object form is read as well as the array form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const values = try rawValues(a,
        \\{"repositories": {"foo": {"type": "vcs", "url": "u"}, "packagist.org": false}}
    );
    try testing.expectEqual(@as(usize, 2), values.items.len);
    try testing.expectEqualStrings("foo", nameOf(values.items[0]).?);
    try testing.expectEqualStrings("packagist.org", disabledNameOf(values.items[1]).?);
}
