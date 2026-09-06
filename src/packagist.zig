//! Packagist v2 metadata — the list of versions a package actually has.
//!
//! This is the half of Composer the rate limit punishes. Resolution needs to
//! know every version of every candidate, and the v2 API answers that in one
//! request per package from a CDN, with no GitHub API call at all — which is
//! why a resolver built on it is not subject to the 60-requests-an-hour cap
//! that makes Composer's VCS driver crawl on this project.
//!
//!     https://repo.packagist.org/p2/<vendor>/<name>.json        tagged releases
//!     https://repo.packagist.org/p2/<vendor>/<name>~dev.json    dev branches
//!
//! ## The minified format, and why it cannot be ignored
//!
//! A v2 response is marked `"minified": "composer/2.0"`, and only the FIRST
//! version entry is complete: every later one lists just the fields that differ
//! from the entry before it, with the string `"__unset"` meaning "remove this
//! key". Reading the array as-is therefore yields versions with no `require`
//! and no `dist` — they look like packages with no dependencies, which a
//! resolver would happily accept and then install nothing.

const std = @import("std");
const fetch = @import("fetch.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const default_repo = "https://repo.packagist.org";

pub const Error = error{
    MetadataUnavailable,
    MalformedMetadata,
};

/// One candidate version of a package, fully expanded.
pub const Candidate = struct {
    name: []const u8,
    version: []const u8,
    version_normalized: []const u8,
    kind: []const u8 = "library",
    /// The complete, expanded package object — what a lock entry is written from.
    raw: std.json.Value,

    pub fn field(self: Candidate, key: []const u8) ?std.json.Value {
        if (self.raw != .object) return null;
        return self.raw.object.get(key);
    }

    pub fn requires(self: Candidate, allocator: std.mem.Allocator) ![]const Requirement {
        return requirementsOf(allocator, self.raw, "require");
    }

    pub fn conflicts(self: Candidate, allocator: std.mem.Allocator) ![]const Requirement {
        return requirementsOf(allocator, self.raw, "conflict");
    }

    pub fn replaces(self: Candidate, allocator: std.mem.Allocator) ![]const Requirement {
        return requirementsOf(allocator, self.raw, "replace");
    }

    pub fn provides(self: Candidate, allocator: std.mem.Allocator) ![]const Requirement {
        return requirementsOf(allocator, self.raw, "provide");
    }

    /// The version a constraint should be matched against, when the package
    /// declares `extra.branch-alias` for the branch it is on.
    ///
    /// This is not a nicety. `alfacode-team/http` is installed as `dev-master`,
    /// and the kernel requires it at `^1.0`. A branch compares equal only to
    /// itself, so without the alias — `{"dev-master": "1.0.x-dev"}` — that
    /// requirement can never be satisfied and the package looks uninstallable.
    pub fn branchAlias(self: Candidate) ?[]const u8 {
        if (self.raw != .object) return null;
        const extra = self.raw.object.get("extra") orelse return null;
        if (extra != .object) return null;
        const aliases = extra.object.get("branch-alias") orelse return null;
        if (aliases != .object) return null;
        const hit = aliases.object.get(self.version) orelse return null;
        return switch (hit) {
            .string => |v| v,
            else => null,
        };
    }
};

pub const Requirement = struct { name: []const u8, constraint: []const u8 };

fn requirementsOf(allocator: std.mem.Allocator, raw: std.json.Value, key: []const u8) ![]const Requirement {
    if (raw != .object) return &.{};
    const section = raw.object.get(key) orelse return &.{};
    if (section != .object) return &.{};

    var out: std.ArrayList(Requirement) = .empty;
    var it = section.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        try out.append(allocator, .{ .name = e.key_ptr.*, .constraint = e.value_ptr.string });
    }
    return out.toOwnedSlice(allocator);
}

pub const Options = struct {
    /// Include dev branches (`~dev.json`). Off unless a constraint needs one,
    /// since it doubles the requests for a resolution that usually wants tags.
    dev: bool = false,
    /// How long a cached metadata file is trusted, in seconds.
    ///
    /// Metadata is MUTABLE — a new release changes it — so unlike an archive
    /// (keyed by an immutable sha) it cannot be cached forever. An hour keeps a
    /// multi-package resolution to one request per package while staying fresh
    /// enough that a release published this morning is visible this afternoon.
    ttl_seconds: i64 = 3600,
    repo: []const u8 = default_repo,
};

/// Every known version of `name`, newest first.
pub fn versionsOf(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    name: []const u8,
    opts: Options,
) ![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;

    try collectInto(allocator, io, cache_dir, name, opts, false, &out);
    if (opts.dev) try collectInto(allocator, io, cache_dir, name, opts, true, &out);

    if (out.items.len == 0) return Error.MetadataUnavailable;
    return out.toOwnedSlice(allocator);
}

fn collectInto(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    name: []const u8,
    opts: Options,
    dev: bool,
    out: *std.ArrayList(Candidate),
) !void {
    const body = metadataBody(allocator, io, cache_dir, name, opts, dev) catch return;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return Error.MalformedMetadata;
    };
    if (parsed != .object) return Error.MalformedMetadata;

    const packages = parsed.object.get("packages") orelse return Error.MalformedMetadata;
    if (packages != .object) return Error.MalformedMetadata;

    const list = packages.object.get(name) orelse return;
    if (list != .array) return;

    const minified = if (parsed.object.get("minified")) |m| m == .string else false;
    try expand(allocator, name, list.array.items, minified, out);
}

/// Walk the version array, carrying forward fields the minified form omits.
fn expand(
    allocator: std.mem.Allocator,
    name: []const u8,
    items: []const std.json.Value,
    minified: bool,
    out: *std.ArrayList(Candidate),
) !void {
    // The accumulator every later entry is a diff against.
    var current: std.json.ObjectMap = .empty;
    var have_current = false;

    for (items) |item| {
        if (item != .object) continue;

        var merged: std.json.ObjectMap = undefined;
        if (!minified or !have_current) {
            merged = try item.object.clone(allocator);
            have_current = true;
        } else {
            merged = try current.clone(allocator);
            var it = item.object.iterator();
            while (it.next()) |e| {
                // `"__unset"` is a deletion, not a value — storing it would give
                // the version a `require` of the literal string "__unset".
                if (e.value_ptr.* == .string and std.mem.eql(u8, e.value_ptr.string, "__unset")) {
                    _ = merged.orderedRemove(e.key_ptr.*);
                    continue;
                }
                try merged.put(allocator, e.key_ptr.*, e.value_ptr.*);
            }
        }
        current = merged;

        const value: std.json.Value = .{ .object = merged };
        try out.append(allocator, .{
            .name = strOf(merged, "name") orelse name,
            .version = strOf(merged, "version") orelse continue,
            .version_normalized = strOf(merged, "version_normalized") orelse "",
            .kind = strOf(merged, "type") orelse "library",
            .raw = value,
        });
    }
}

fn strOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// The metadata document, from cache when fresh enough, else from the network.
fn metadataBody(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    name: []const u8,
    opts: Options,
    dev: bool,
) ![]const u8 {
    const dir = try std.fs.path.join(allocator, &.{ cache_dir, "metadata" });
    Dir.cwd().createDirPath(io, dir) catch {};

    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}.json", .{
        try flatten(allocator, name),
        if (dev) "~dev" else "",
    });
    const path = try std.fs.path.join(allocator, &.{ dir, file_name });

    if (fresh(io, path, opts.ttl_seconds)) {
        if (Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch null) |cached| {
            return cached;
        }
    }

    const url = try std.fmt.allocPrint(allocator, "{s}/p2/{s}{s}.json", .{
        util.trimSlash(opts.repo),
        name,
        if (dev) "~dev" else "",
    });

    const body = fetch.download(allocator, io, url) catch {
        // A stale copy beats no copy: the network may simply be absent, and a
        // resolution against yesterday's metadata is far more useful than a
        // failure.
        if (Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch null) |stale| {
            return stale;
        }
        return Error.MetadataUnavailable;
    };

    util.writeFileAtomic(io, path, body) catch {};
    return body;
}

/// `vendor/name` → `vendor-name`, so it is one flat filename.
fn flatten(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, name);
    for (out) |*c| if (c.* == '/') {
        c.* = '-';
    };
    return out;
}

fn fresh(io: Io, path: []const u8, ttl_seconds: i64) bool {
    if (ttl_seconds <= 0) return false;
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const age_ns = now - @as(i96, st.mtime.nanoseconds);
    if (age_ns < 0) return true; // clock skew — trust it rather than refetch
    return age_ns < @as(i96, ttl_seconds) * std.time.ns_per_s;
}

// ── parallel warm ─────────────────────────────────────────────────────────────

/// Fetch metadata for many packages concurrently, into the cache.
///
/// The solver looks packages up one at a time as it discovers them, and each
/// miss is a round trip. On a 107-package graph that is ~200 sequential
/// requests — the same latency problem the archive downloader had, with the
/// same fix. Nothing here changes what the solver decides; it only means the
/// lookups hit a warm cache.
///
/// Failures are silent by design: a name that does not exist on Packagist (a
/// path repository, a private package) is not an error at this stage, and the
/// solver will report it properly if it turns out to matter.
pub fn warm(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    names: []const []const u8,
    opts: Options,
    workers: usize,
) usize {
    if (names.len == 0) return 0;

    var shared: Warm = .{
        .io = io,
        .cache_dir = cache_dir,
        .names = names,
        .opts = opts,
        .next = .init(0),
        .done = .init(0),
    };

    const n = @min(@max(workers, 1), names.len);
    if (n == 1) {
        warmWork(&shared);
        return shared.done.load(.monotonic);
    }

    var threads: [fetch.max_workers]std.Thread = undefined;
    var started: usize = 0;
    while (started < n and started < fetch.max_workers) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, warmWork, .{&shared}) catch break;
    }
    warmWork(&shared);
    for (threads[0..started]) |t| t.join();

    _ = allocator;
    return shared.done.load(.monotonic);
}

const Warm = struct {
    io: Io,
    cache_dir: []const u8,
    names: []const []const u8,
    opts: Options,
    next: std.atomic.Value(usize),
    done: std.atomic.Value(usize),
};

fn warmWork(shared: *Warm) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.names.len) return;

        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const name = shared.names[i];

        _ = metadataBody(a, shared.io, shared.cache_dir, name, shared.opts, false) catch {};
        if (shared.opts.dev) {
            _ = metadataBody(a, shared.io, shared.cache_dir, name, shared.opts, true) catch {};
        }
        _ = shared.done.fetchAdd(1, .monotonic);
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expandOf(a: std.mem.Allocator, src: []const u8, minified: bool) ![]const Candidate {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
    var out: std.ArrayList(Candidate) = .empty;
    try expand(a, "acme/lib", parsed.array.items, minified, &out);
    return out.toOwnedSlice(a);
}

test "minified entries inherit the fields they omit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exactly the shape packagist returns: the first entry complete, the rest
    // diffs. Without expansion, 2.0.0 would look like a package that requires
    // nothing at all.
    const got = try expandOf(a,
        \\[{"name":"acme/lib","version":"3.0.0","type":"library","require":{"php":">=8.0"},
        \\  "dist":{"type":"zip","url":"u3"}},
        \\ {"version":"2.0.0","dist":{"type":"zip","url":"u2"}}]
    , true);

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("2.0.0", got[1].version);
    try testing.expectEqualStrings("acme/lib", got[1].name);

    const reqs = try got[1].requires(a);
    try testing.expectEqual(@as(usize, 1), reqs.len);
    try testing.expectEqualStrings("php", reqs[0].name);
    try testing.expectEqualStrings(">=8.0", reqs[0].constraint);
}

test "__unset removes an inherited field rather than setting it to a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try expandOf(a,
        \\[{"name":"acme/lib","version":"2.0.0","require":{"php":">=8.0"}},
        \\ {"version":"1.0.0","require":"__unset"}]
    , true);

    try testing.expectEqual(@as(usize, 0), (try got[1].requires(a)).len);
    // And the earlier version keeps what it declared.
    try testing.expectEqual(@as(usize, 1), (try got[0].requires(a)).len);
}

test "a non-minified document is taken at face value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try expandOf(a,
        \\[{"name":"acme/lib","version":"2.0.0","require":{"php":">=8.0"}},
        \\ {"name":"acme/lib","version":"1.0.0"}]
    , false);

    // No inheritance: 1.0.0 genuinely declares nothing.
    try testing.expectEqual(@as(usize, 0), (try got[1].requires(a)).len);
}

test "package names flatten to one cache filename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("psr-log", try flatten(arena.allocator(), "psr/log"));
}
