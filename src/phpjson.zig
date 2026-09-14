//! PHP's `json_encode`, reproduced exactly.
//!
//! Two files need this and they need it configured DIFFERENTLY, which is the
//! whole reason it is one file rather than two encoders that drift:
//!
//!   * `contenthash` calls it with options `0` — slashes escaped, unicode
//!     escaped, no pretty printing — because that is what `getContentHash`
//!     passes, and the result is fed to md5.
//!   * `lockwrite` calls it with `JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT |
//!     JSON_UNESCAPED_UNICODE`, which is `JsonFile::write`'s default.
//!
//! Those two configurations disagree about every `/` and every non-ASCII
//! character in the same project, three lines apart in Composer's own source.
//! Writing one encoder and "adjusting" it later is how a lock file ends up with
//! `https:\/\/` in it.

const std = @import("std");

pub const Options = struct {
    /// `/` → `\/`. ON unless JSON_UNESCAPED_SLASHES.
    escape_slashes: bool = true,
    /// Non-ASCII → `\uXXXX`. ON unless JSON_UNESCAPED_UNICODE.
    escape_unicode: bool = true,
    /// JSON_PRETTY_PRINT.
    pretty: bool = false,
    /// One level of indentation. PHP hard-codes four spaces; Composer's
    /// `JsonFile` can rewrite it, and does not for the lock.
    indent: []const u8 = "    ",
    /// Treat objects the way a value that came through `json_decode($s, true)`
    /// behaves: an empty one encodes as `[]`, and one keyed exactly `0..n-1`
    /// encodes as an array. TRUE for the content hash, whose input is decoded
    /// that way; FALSE for the lock, which Composer builds as PHP arrays it
    /// never round-trips.
    assoc_arrays: bool = false,
};

pub fn encode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    v: std.json.Value,
    opts: Options,
) !void {
    try write(allocator, out, v, opts, 0);
}

fn write(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    v: std.json.Value,
    opts: Options,
    depth: usize,
) !void {
    switch (v) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .float => |f| try writeFloat(allocator, out, f),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try writeString(allocator, out, s, opts),
        .array => |items| {
            if (items.items.len == 0) {
                try out.appendSlice(allocator, "[]");
                return;
            }
            try out.append(allocator, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try newlineIndent(allocator, out, opts, depth + 1);
                try write(allocator, out, item, opts, depth + 1);
            }
            try newlineIndent(allocator, out, opts, depth);
            try out.append(allocator, ']');
        },
        .object => |o| {
            if (o.count() == 0) {
                try out.appendSlice(allocator, if (opts.assoc_arrays) "[]" else "{}");
                return;
            }
            if (opts.assoc_arrays and isList(o)) {
                try out.append(allocator, '[');
                var it = o.iterator();
                var i: usize = 0;
                while (it.next()) |e| : (i += 1) {
                    if (i > 0) try out.append(allocator, ',');
                    try newlineIndent(allocator, out, opts, depth + 1);
                    try write(allocator, out, e.value_ptr.*, opts, depth + 1);
                }
                try newlineIndent(allocator, out, opts, depth);
                try out.append(allocator, ']');
                return;
            }

            try out.append(allocator, '{');
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                try newlineIndent(allocator, out, opts, depth + 1);
                try writeString(allocator, out, e.key_ptr.*, opts);
                try out.append(allocator, ':');
                if (opts.pretty) try out.append(allocator, ' ');
                try write(allocator, out, e.value_ptr.*, opts, depth + 1);
            }
            try newlineIndent(allocator, out, opts, depth);
            try out.append(allocator, '}');
        },
    }
}

fn newlineIndent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    opts: Options,
    depth: usize,
) !void {
    if (!opts.pretty) return;
    try out.append(allocator, '\n');
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, opts.indent);
}

/// Would PHP have turned this object into a list?
///
/// `json_decode($s, true)` casts a key that is a canonical decimal integer to
/// an int; `json_encode` then writes an array when those ints are exactly
/// 0,1,…,n-1 in order. A gap, a reorder, or a key like "01" or "-1" that PHP
/// does NOT cast keeps it an object.
pub fn isList(o: std.json.ObjectMap) bool {
    var it = o.iterator();
    var expected: usize = 0;
    while (it.next()) |e| : (expected += 1) {
        const key = e.key_ptr.*;
        if (key.len == 0) return false;
        if (key.len > 1 and key[0] == '0') return false;
        for (key) |ch| {
            if (!std.ascii.isDigit(ch)) return false;
        }
        const n = std.fmt.parseInt(usize, key, 10) catch return false;
        if (n != expected) return false;
    }
    return true;
}

/// PHP writes a whole-valued float as `1.0`, not `1`.
fn writeFloat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), f: f64) !void {
    if (f == @trunc(f) and @abs(f) < 1e15) {
        try out.print(allocator, "{d}.0", .{@as(i64, @intFromFloat(f))});
        return;
    }
    try out.print(allocator, "{d}", .{f});
}

fn writeString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
    opts: Options,
) !void {
    try out.append(allocator, '"');

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => {
                try out.appendSlice(allocator, "\\\"");
                i += 1;
            },
            '\\' => {
                try out.appendSlice(allocator, "\\\\");
                i += 1;
            },
            '/' => {
                try out.appendSlice(allocator, if (opts.escape_slashes) "\\/" else "/");
                i += 1;
            },
            0x08 => {
                try out.appendSlice(allocator, "\\b");
                i += 1;
            },
            0x0C => {
                try out.appendSlice(allocator, "\\f");
                i += 1;
            },
            '\n' => {
                try out.appendSlice(allocator, "\\n");
                i += 1;
            },
            '\r' => {
                try out.appendSlice(allocator, "\\r");
                i += 1;
            },
            '\t' => {
                try out.appendSlice(allocator, "\\t");
                i += 1;
            },
            else => {
                if (c < 0x20) {
                    try out.print(allocator, "\\u{x:0>4}", .{c});
                    i += 1;
                } else if (c < 0x80) {
                    try out.append(allocator, c);
                    i += 1;
                } else if (!opts.escape_unicode) {
                    try out.append(allocator, c);
                    i += 1;
                } else {
                    // A UTF-16 escape, with a surrogate PAIR above the BMP —
                    // `\ud83d\ude00` for an emoji, never `\u1f600`.
                    const len = std.unicode.utf8ByteSequenceLength(c) catch {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    };
                    if (i + len > s.len) {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    };
                    if (cp < 0x10000) {
                        try out.print(allocator, "\\u{x:0>4}", .{cp});
                    } else {
                        const v = cp - 0x10000;
                        try out.print(allocator, "\\u{x:0>4}\\u{x:0>4}", .{
                            0xD800 + (v >> 10),
                            0xDC00 + (v & 0x3FF),
                        });
                    }
                    i += len;
                }
            },
        }
    }

    try out.append(allocator, '"');
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn render(a: std.mem.Allocator, src: []const u8, opts: Options) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
    var out: std.ArrayList(u8) = .empty;
    try encode(a, &out, v, opts);
    return out.toOwnedSlice(a);
}

test "the two configurations disagree about slashes and unicode, as PHP does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\{"u":"https://x/y","w":"café"}
    ;
    // options 0 — what getContentHash passes.
    try testing.expectEqualStrings(
        "{\"u\":\"https:\\/\\/x\\/y\",\"w\":\"caf\\u00e9\"}",
        try render(a, src, .{}),
    );
    // JsonFile::write's default — what the lock file gets.
    try testing.expectEqualStrings(
        "{\n    \"u\": \"https://x/y\",\n    \"w\": \"café\"\n}",
        try render(a, src, .{ .escape_slashes = false, .escape_unicode = false, .pretty = true }),
    );
}

test "an empty object is [] only when the value came through json_decode assoc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The lock's `stability-flags` is an explicit stdClass and must stay `{}`.
    try testing.expectEqualStrings("{\"x\":{}}", try render(a,
        \\{"x":{}}
    , .{}));
    try testing.expectEqualStrings("{\"x\":[]}", try render(a,
        \\{"x":{}}
    , .{ .assoc_arrays = true }));
}

test "pretty printing matches PHP: four spaces, colon-space, empty containers inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a,
        \\{"a":[1,2],"b":{"c":true},"d":[],"e":{}}
    , .{ .escape_slashes = false, .escape_unicode = false, .pretty = true });

    try testing.expectEqualStrings(
        \\{
        \\    "a": [
        \\        1,
        \\        2
        \\    ],
        \\    "b": {
        \\        "c": true
        \\    },
        \\    "d": [],
        \\    "e": {}
        \\}
    , got);
}
