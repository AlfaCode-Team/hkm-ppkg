//! `composer.lock`'s `content-hash` — the field that decides whether Composer
//! says "the lock file is not up to date with the latest changes".
//!
//! It is an md5 over a SUBSET of composer.json, re-encoded by PHP. Reproducing
//! it means reproducing PHP's encoder, not writing a reasonable one, because
//! the hash is a byte comparison and a defensible difference is still a
//! difference. Three of those bytes-level details decide it:
//!
//!   1. **`json_encode($data, 0)`** — no pretty printing, and specifically NOT
//!      `JSON_UNESCAPED_SLASHES` or `JSON_UNESCAPED_UNICODE`, which Composer's
//!      `JsonFile::encode` uses everywhere ELSE. So `/` is written `\/` and
//!      every non-ASCII character becomes a `\uXXXX` escape here, and does not
//!      in the lock file three lines away.
//!
//!   2. **An empty object becomes an empty ARRAY.** `JsonFile::parseJson` uses
//!      `json_decode($s, true)`, so `{}` arrives as an empty PHP array and goes
//!      back out as `[]`. A project with `"require-dev": {}` hashes it as
//!      `"require-dev":[]`.
//!
//!   3. **An object whose keys are exactly "0".."n-1" becomes an array too**,
//!      for the same reason: PHP casts decimal-integer string keys to ints, and
//!      `json_encode` writes a list when the int keys form a gapless sequence
//!      from zero. `"repositories"` written as a JSON object with numeric keys
//!      is the shape that hits this in practice.
//!
//! Key ORDER is `ksort` — plain byte order over the selected top-level keys.
//! Nested objects keep the order they had in the file, because PHP arrays
//! preserve insertion order and nothing sorts them.

const std = @import("std");
const phpjson = @import("phpjson.zig");

/// The composer.json keys that participate, from `Locker::getContentHash`.
///
/// Everything else — `autoload`, `scripts`, `description`, `config` beyond
/// `platform` — is deliberately excluded: editing them does not invalidate a
/// resolution, so it must not invalidate the lock.
const relevant = [_][]const u8{
    "name",
    "version",
    "require",
    "require-dev",
    "conflict",
    "replace",
    "provide",
    "minimum-stability",
    "prefer-stable",
    "repositories",
    "extra",
};

pub const Error = error{MalformedManifest};

/// Compute the `content-hash` for a composer.json source.
pub fn of(allocator: std.mem.Allocator, composer_json: []const u8) ![]const u8 {
    const encoded = try relevantJson(allocator, composer_json);

    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(encoded, &digest, .{});

    const hex = try allocator.alloc(u8, digest.len * 2);
    _ = std.fmt.bufPrint(hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

/// The exact byte string Composer hashes. Exposed because when a hash
/// disagrees, this is the thing worth diffing — the digest tells you nothing.
pub fn relevantJson(allocator: std.mem.Allocator, composer_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, composer_json, .{}) catch
        return Error.MalformedManifest;
    if (parsed != .object) return Error.MalformedManifest;
    const root = parsed.object;

    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(std.json.Value) = .empty;

    for (relevant) |key| {
        if (root.get(key)) |v| {
            try keys.append(allocator, key);
            try values.append(allocator, v);
        }
    }

    // `config` enters ONLY as `config.platform`, and only when present. The
    // rest of config is a machine's preferences, not a description of what was
    // resolved — a different `vendor-dir` must not invalidate a lock.
    if (root.get("config")) |cfg| {
        if (cfg == .object) {
            if (cfg.object.get("platform")) |plat| {
                var wrapper: std.json.ObjectMap = .empty;
                try wrapper.put(allocator, "platform", plat);
                try keys.append(allocator, "config");
                try values.append(allocator, .{ .object = wrapper });
            }
        }
    }

    // ksort — plain byte order, which for these ASCII keys is what PHP does.
    var i: usize = 1;
    while (i < keys.items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, keys.items[j - 1], keys.items[j]) == .gt) : (j -= 1) {
            std.mem.swap([]const u8, &keys.items[j - 1], &keys.items[j]);
            std.mem.swap(std.json.Value, &values.items[j - 1], &values.items[j]);
        }
    }

    var out: std.ArrayList(u8) = .empty;

    // An empty selection is an empty PHP array, and PHP writes that as `[]`.
    if (keys.items.len == 0) {
        try out.appendSlice(allocator, "[]");
        return out.toOwnedSlice(allocator);
    }

    try out.append(allocator, '{');
    for (keys.items, values.items, 0..) |k, v, n| {
        if (n > 0) try out.append(allocator, ',');
        try encodeString(allocator, &out, k);
        try out.append(allocator, ':');
        try encode(allocator, &out, v);
    }
    try out.append(allocator, '}');

    return out.toOwnedSlice(allocator);
}

/// The options `getContentHash` implies: `json_encode($data, 0)` over a value
/// that arrived through `json_decode($s, true)`.
const php_options: phpjson.Options = .{
    .escape_slashes = true,
    .escape_unicode = true,
    .pretty = false,
    .assoc_arrays = true,
};

fn encode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    try phpjson.encode(allocator, out, v, php_options);
}

fn encodeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try phpjson.encode(allocator, out, .{ .string = s }, php_options);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn hashOf(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    return of(a, src);
}

test "only the relevant keys participate, in byte order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const j = try relevantJson(a,
        \\{"autoload":{"psr-4":{"A\\":"src/"}},"require":{"php":"^8.1"},"name":"a/b","description":"x"}
    );
    // autoload and description are gone; name sorts before require.
    try testing.expectEqualStrings("{\"name\":\"a\\/b\",\"require\":{\"php\":\"^8.1\"}}", j);
}

test "an empty object is hashed as an empty ARRAY" {
    // The detail that makes a hand-rolled encoder disagree with PHP on any
    // project that has an empty require-dev.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const j = try relevantJson(a,
        \\{"name":"a/b","require-dev":{}}
    );
    try testing.expectEqualStrings("{\"name\":\"a\\/b\",\"require-dev\":[]}", j);
}

test "slashes are escaped and non-ASCII becomes a \\u escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const j = try relevantJson(a,
        \\{"name":"a/b","extra":{"url":"https://example.com/x","who":"café","emoji":"😀"}}
    );
    try testing.expectEqualStrings(
        "{\"extra\":{\"url\":\"https:\\/\\/example.com\\/x\",\"who\":\"caf\\u00e9\",\"emoji\":\"\\ud83d\\ude00\"},\"name\":\"a\\/b\"}",
        j,
    );
}

test "an object keyed 0..n-1 is a list, and one with a gap is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = try relevantJson(a,
        \\{"extra":{"0":"a","1":"b"}}
    );
    try testing.expectEqualStrings("{\"extra\":[\"a\",\"b\"]}", list);

    const gap = try relevantJson(a,
        \\{"extra":{"0":"a","2":"b"}}
    );
    try testing.expectEqualStrings("{\"extra\":{\"0\":\"a\",\"2\":\"b\"}}", gap);

    // "01" is not a canonical integer, so PHP keeps it as a string key.
    const padded = try relevantJson(a,
        \\{"extra":{"0":"a","01":"b"}}
    );
    try testing.expectEqualStrings("{\"extra\":{\"0\":\"a\",\"01\":\"b\"}}", padded);
}

test "config enters only through platform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A vendor-dir change must NOT invalidate a lock.
    const without = try relevantJson(a,
        \\{"name":"a/b","config":{"vendor-dir":"lib"}}
    );
    try testing.expectEqualStrings("{\"name\":\"a\\/b\"}", without);

    const with = try relevantJson(a,
        \\{"name":"a/b","config":{"vendor-dir":"lib","platform":{"php":"8.1.0"}}}
    );
    try testing.expectEqualStrings("{\"config\":{\"platform\":{\"php\":\"8.1.0\"}},\"name\":\"a\\/b\"}", with);
}

test "the digest is 32 lowercase hex characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try hashOf(a,
        \\{"name":"a/b"}
    );
    try testing.expectEqual(@as(usize, 32), h.len);
    for (h) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

test "201 real composer.json files hash exactly as Composer hashes them" {
    // The test of record for this file, and the only one that can catch a
    // defensible-but-different encoder.
    //
    // Every row is a real composer.json from a working tree, reduced to the
    // keys the hash reads plus two DECOY keys the hash must ignore, paired with
    // the answer produced by running `Composer\Package\Locker::getContentHash`
    // over the ORIGINAL file. The reduction was verified not to change
    // Composer's own answer before the row was recorded, so a row that fails
    // here is this implementation disagreeing with Composer — not a corpus
    // artefact.
    //
    // Regenerate with the script in CONTRIBUTING.md. An answer you decided
    // yourself instead of reading off Composer defeats the entire mechanism.
    const corpus = @embedFile("testdata/contenthash_corpus.json");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, corpus, .{});
    try testing.expect(parsed == .array);
    try testing.expect(parsed.array.items.len > 150);

    var checked: usize = 0;
    for (parsed.array.items) |row| {
        const pair = row.array.items;
        const source = pair[0].string;
        const expected = pair[1].string;

        const got = try of(a, source);
        testing.expectEqualStrings(expected, got) catch |e| {
            // The digest says nothing about what differed; the encoded string
            // is the thing worth reading, so print it rather than a hex pair.
            std.debug.print(
                "\ncontent-hash disagreement\n  source:  {s}\n  encoded: {s}\n",
                .{ source, try relevantJson(a, source) },
            );
            return e;
        };
        checked += 1;
    }

    try testing.expectEqual(parsed.array.items.len, checked);
}
