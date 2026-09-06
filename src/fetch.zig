//! Downloading package distributions, with a content-addressed cache.
//!
//! ## Why this does not hit the rate limit that makes Composer slow here
//!
//! A lock's dist URLs are `api.github.com/repos/<o>/<r>/zipball/<sha>`, which
//! LOOKS like the API that returns 403 after 60 unauthenticated requests an
//! hour. It is not the same thing: that endpoint 302-redirects to
//! `codeload.github.com`, which serves the archive and costs no quota. What the
//! quota actually pays for is METADATA — listing refs, reading a composer.json
//! off a branch — which is exactly what dependency resolution does and what
//! installing from a lock never does at all.
//!
//! Measured on this machine: downloading a zipball moved the remaining quota by
//! zero.
//!
//! ## Cache
//!
//! Keyed by the dist REFERENCE — an immutable commit sha — so a cached entry can
//! never be stale for its key, and two projects locking the same version of a
//! package download it once between them.

const std = @import("std");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    DownloadFailed,
    ChecksumMismatch,
    NoCacheDir,
};

pub const Result = struct {
    /// Absolute path of the archive on disk.
    path: []const u8,
    /// True when it was already cached and no request was made.
    cached: bool,
    bytes: usize,
};

/// Where downloaded archives are kept.
///
/// `HKM_PKG_CACHE` wins, then the platform cache dir, then a directory beside
/// the project — never nothing, because failing to find a cache should slow an
/// install down, not stop it.
pub fn cacheRoot(allocator: std.mem.Allocator, env: *EnvMap, fallback: []const u8) ![]const u8 {
    if (env.get("HKM_PKG_CACHE")) |v| {
        if (v.len > 0) return allocator.dupe(u8, util.trimSlash(v));
    }
    if (env.get("HOME")) |home| {
        if (home.len > 0) {
            const platform_sub = switch (@import("builtin").os.tag) {
                .macos => "Library/Caches/hkm/pkg",
                else => ".cache/hkm/pkg",
            };
            return std.fs.path.join(allocator, &.{ util.trimSlash(home), platform_sub });
        }
    }
    return std.fs.path.join(allocator, &.{ fallback, ".hkm-pkg-cache" });
}

/// Fetch `url` into the cache, or report the cached copy.
///
/// `key` must identify the CONTENT — a commit sha or a checksum — not the name,
/// or a cache entry could outlive the bytes it claims to hold.
pub fn intoCache(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    url: []const u8,
    key: []const u8,
    expected_sha1: []const u8,
) !Result {
    // Two levels of fan-out: a flat directory of several thousand entries is
    // slow to stat on some filesystems and unreadable in an `ls`.
    const shard = if (key.len >= 2) key[0..2] else "00";
    const dir = try std.fs.path.join(allocator, &.{ cache_dir, shard });
    Dir.cwd().createDirPath(io, dir) catch {};

    const path = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.zip", .{key}) });

    if (util.fileExists(io, path)) {
        const size = fileSize(io, path) orelse 0;
        if (size > 0) return .{ .path = path, .cached = true, .bytes = size };
    }

    const body = try download(allocator, io, url);
    if (expected_sha1.len > 0) try verifySha1(body, expected_sha1);

    try util.writeFileAtomic(io, path, body);
    return .{ .path = path, .cached = false, .bytes = body.len };
}

/// GET `url`, following redirects, returning the body.
pub fn download(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        // GitHub's zipball endpoint redirects to codeload; a client that does
        // not follow redirects downloads an empty body and reports success.
        .redirect_behavior = @enumFromInt(5),
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "hkm-pkg" },
            .{ .name = "accept", .value = "*/*" },
        },
    }) catch return Error.DownloadFailed;

    if (result.status != .ok) return Error.DownloadFailed;

    const owned = try allocator.dupe(u8, body.written());
    return owned;
}

fn verifySha1(body: []const u8, expected_hex: []const u8) !void {
    var digest: [20]u8 = undefined;
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(body);
    h.final(&digest);

    var buf: [40]u8 = undefined;
    const got = std.fmt.bufPrint(&buf, "{x}", .{&digest}) catch return Error.ChecksumMismatch;
    if (!std.ascii.eqlIgnoreCase(got, expected_hex)) return Error.ChecksumMismatch;
}

fn fileSize(io: Io, path: []const u8) ?usize {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(st.size);
}

// ── parallel prefetch ─────────────────────────────────────────────────────────

/// One archive to have on disk before placement begins.
pub const Want = struct {
    url: []const u8,
    /// Content identity — a commit sha, never a name.
    key: []const u8,
    sha1: []const u8 = "",
};

/// Download everything in `wants` that is not already cached, concurrently.
///
/// Only the NETWORK is parallelised. Unpacking and every other filesystem
/// change stays on the calling thread, which keeps the shared mutable state down
/// to two atomics and makes the concurrency easy to reason about: each worker
/// touches exactly one cache file, named after content it alone is fetching.
///
/// This is the one place Composer was genuinely faster. A cold install is ~100
/// sequential round trips to codeload, which is latency, not bandwidth — the
/// process sat at 2% CPU for three and a half minutes. Composer issues them in
/// parallel through curl_multi and finishes in a fraction of that.
pub fn prefetch(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    wants: []const Want,
    workers: usize,
    progress: ?*const fn (done: usize, total: usize, url: []const u8) void,
) usize {
    if (wants.len == 0) return 0;

    var shared: Shared = .{
        .io = io,
        .cache_dir = cache_dir,
        .wants = wants,
        .next = .init(0),
        .fetched = .init(0),
        .bytes = .init(0),
        .progress = progress,
    };

    const n = @min(@max(workers, 1), wants.len);

    // A single worker needs no threads at all — and this is also the fallback
    // when the OS refuses to spawn one, so a machine that cannot thread still
    // installs rather than failing.
    if (n == 1) {
        work(&shared);
        return shared.bytes.load(.monotonic);
    }

    var threads: [max_workers]std.Thread = undefined;
    var started: usize = 0;
    while (started < n) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, work, .{&shared}) catch break;
    }

    // Whatever could not be spawned is done by this thread, so the queue always
    // drains even if the pool is short.
    work(&shared);
    for (threads[0..started]) |t| t.join();

    _ = allocator;
    return shared.bytes.load(.monotonic);
}

pub const max_workers = 16;

/// Default concurrency: enough to hide latency, low enough to stay polite to
/// the host serving the archives.
pub fn workerCount(env: *EnvMap) usize {
    if (env.get("HKM_PKG_JOBS")) |v| {
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch 0;
        if (n > 0) return @min(n, max_workers);
    }
    return 8;
}

const Shared = struct {
    io: Io,
    cache_dir: []const u8,
    wants: []const Want,
    next: std.atomic.Value(usize),
    fetched: std.atomic.Value(usize),
    bytes: std.atomic.Value(usize),
    progress: ?*const fn (done: usize, total: usize, url: []const u8) void,
};

fn work(shared: *Shared) void {
    // Each worker allocates from its own arena off the page allocator: the
    // caller's allocator is not shared safely across threads, and an arena per
    // worker also means the whole thread's garbage is released in one call.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.wants.len) return;

        const want = shared.wants[i];
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const got = intoCache(a, shared.io, shared.cache_dir, want.url, want.key, want.sha1) catch {
            // Reported by the placement pass, which knows the package name; a
            // failure here just means the cache stays cold for that entry.
            continue;
        };
        if (!got.cached) _ = shared.bytes.fetchAdd(got.bytes, .monotonic);

        const done = shared.fetched.fetchAdd(1, .monotonic) + 1;
        if (shared.progress) |cb| cb(done, shared.wants.len, want.url);
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an explicit cache location wins over the platform default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: EnvMap = .init(arena.allocator());
    try env.put("HKM_PKG_CACHE", "/custom/spot/");
    try env.put("HOME", "/home/someone");

    // The trailing slash is dropped so joins do not produce a double separator.
    try testing.expectEqualStrings("/custom/spot", try cacheRoot(arena.allocator(), &env, "/proj"));
}

test "with no cache variable the platform directory is used" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: EnvMap = .init(arena.allocator());
    try env.put("HOME", "/home/someone");

    const got = try cacheRoot(arena.allocator(), &env, "/proj");
    const want = switch (@import("builtin").os.tag) {
        .macos => "/home/someone/Library/Caches/hkm/pkg",
        else => "/home/someone/.cache/hkm/pkg",
    };
    try testing.expectEqualStrings(want, got);
}

test "with no home at all it still resolves somewhere writable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: EnvMap = .init(arena.allocator());
    try testing.expectEqualStrings("/proj/.hkm-pkg-cache", try cacheRoot(arena.allocator(), &env, "/proj"));
}

test "worker count is bounded and overridable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var env: EnvMap = .init(arena.allocator());
    try testing.expectEqual(@as(usize, 8), workerCount(&env));

    try env.put("HKM_PKG_JOBS", "3");
    try testing.expectEqual(@as(usize, 3), workerCount(&env));

    // A request for more than the cap is clamped rather than honoured: this
    // opens that many concurrent connections to one host.
    try env.put("HKM_PKG_JOBS", "999");
    try testing.expectEqual(@as(usize, max_workers), workerCount(&env));

    // Nonsense falls back to the default instead of disabling downloads.
    try env.put("HKM_PKG_JOBS", "zero");
    try testing.expectEqual(@as(usize, 8), workerCount(&env));
}

test "sha1 verification accepts the right digest and rejects any other" {
    // sha1("hello") — a known vector, so the test fails if the hash function or
    // the hex formatting changes underneath it.
    try verifySha1("hello", "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    try verifySha1("hello", "AAF4C61DDCC5E8A2DABEDE0F3B482CD9AEA9434D"); // case-insensitive
    try testing.expectError(Error.ChecksumMismatch, verifySha1("hello!", "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"));
}
