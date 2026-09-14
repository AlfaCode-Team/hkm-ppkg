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
const auth = @import("auth.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    DownloadFailed,
    ChecksumMismatch,
    NoCacheDir,
    NoChecksum,
    /// Plain HTTP, with `config.secure-http` on. Its own error rather than a
    /// download failure: "the network is down" and "this project forbids
    /// fetching code over an unauthenticated channel" send a reader to two
    /// completely different places.
    InsecureUrl,
};

pub const Result = struct {
    /// Absolute path of the archive on disk.
    path: []const u8,
    /// True when it was already cached and no request was made.
    cached: bool,
    bytes: usize,
    /// Downloaded with NO checksum to check it against.
    ///
    /// Not an error — Composer behaves the same way, and GitHub publishes no
    /// digest for a generated zipball, so refusing would refuse every `vcs`
    /// package. But it was silent, and "some of this tree arrived unverified"
    /// is a fact an operator is entitled to know before they deploy it.
    unverified: bool = false,
};

/// Refuse a dist that carries no checksum, rather than reporting it.
///
/// Off by default because it would refuse every GitHub `vcs` package, which is
/// most of what this tool installs. On, it is the switch for a build that is
/// not allowed to ship a byte nobody vouched for.
pub var require_checksums: bool = false;

/// `--no-cache` — never read a cached archive, and never write one.
///
/// Composer's flag, and it means both halves. Reading only would still leave
/// the run writing entries a caller has just said they do not want kept; the
/// case for it is a build container whose cache directory is somebody else's
/// and must come out unchanged.
pub var bypass_cache: bool = false;

/// `config.secure-http` — refuse plain HTTP.
///
/// ON by default, as Composer has it. A package fetched over http is a package
/// any host on the path may replace, and this one is about to be executed.
/// Turning it off is a decision an operator makes for a specific private
/// mirror; it is not a default anything should ship with.
pub var secure_http: bool = true;

/// `config.cafile` — verify against this CA bundle rather than the system's.
pub var ca_file: ?[]const u8 = null;
/// `config.capath` — a directory of CA certificates.
pub var ca_path: ?[]const u8 = null;
/// `config.cache-dir`, when the project or the machine set one.
pub var configured_cache_dir: ?[]const u8 = null;

/// `config.process-timeout` — seconds a spawned command may run.
///
/// Enforced on the ONE spawned process this module owns: `curl`, via
/// `--max-time`. Scripts and the VCS tools are spawned elsewhere and are not
/// bounded by it; `compat` says so rather than leaving a project to assume a
/// setting it configured is in force everywhere.
pub var process_timeout: u32 = 300;

/// `config.disable-tls` — do not verify certificates.
///
/// Separate from `secure_http` because they are different retreats: one drops
/// to plaintext, the other keeps the tunnel and stops checking who is at the
/// other end. Both are reported by `diagnose` when set.
pub var disable_tls: bool = false;

/// Apply the merged `config` block to this module's transport settings.
///
/// Called by each command once, from the settings it loaded. A module-level
/// variable rather than a parameter because the download path is reached from
/// a worker pool whose functions take a fixed context — and because these are
/// process-wide facts about how this machine talks to the network, not facts
/// about one request.
pub fn applySettings(
    secure: bool,
    cafile: ?[]const u8,
    capath: ?[]const u8,
    no_tls: bool,
    cache_dir: ?[]const u8,
    timeout: u32,
) void {
    secure_http = secure;
    ca_file = cafile;
    ca_path = capath;
    disable_tls = no_tls;
    configured_cache_dir = cache_dir;
    process_timeout = timeout;
}

/// Is this URL allowed by `secure-http`?
///
/// Composer permits plain HTTP to localhost regardless, because a loopback
/// address cannot be intercepted by a third party on the path — the one case
/// where the rule protects nothing and blocks a legitimate local mirror.
pub fn allowedUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http://")) return true;
    if (!secure_http) return true;

    const rest = url["http://".len..];
    const host_end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
    const host = rest[0..host_end];
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.endsWith(u8, host, ".localhost");
}

/// Where downloaded archives are kept.
///
/// `HKM_PKG_CACHE` wins, then the platform cache dir, then a directory beside
/// the project — never nothing, because failing to find a cache should slow an
/// install down, not stop it.
pub fn cacheRoot(allocator: std.mem.Allocator, env: *EnvMap, fallback: []const u8) ![]const u8 {
    if (env.get("HKM_PKG_CACHE")) |v| {
        if (v.len > 0) return allocator.dupe(u8, util.trimSlash(v));
    }
    // `config.cache-dir`, and `COMPOSER_CACHE_DIR` through it. Below the
    // tool's own variable and above the platform default, which is where
    // Composer puts it too.
    if (configured_cache_dir) |v| {
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

    if (!bypass_cache and util.fileExists(io, path)) {
        const size = fileSize(io, path) orelse 0;
        // A cached entry is not re-reported as unverified: it is keyed by the
        // commit sha or the checksum, so whatever was true when it was written
        // is still true, and counting it again would make the number grow with
        // re-runs rather than with risk.
        if (size > 0) return .{ .path = path, .cached = true, .bytes = size };
    }

    if (expected_sha1.len == 0 and require_checksums) return Error.NoChecksum;

    const body = try download(allocator, io, url);
    if (expected_sha1.len > 0) try verifySha1(body, expected_sha1);

    try util.writeFileAtomic(io, path, body);
    return .{
        .path = path,
        .cached = false,
        .bytes = body.len,
        .unverified = expected_sha1.len == 0,
    };
}

/// Credentials for private hosts, loaded once before any work begins.
///
/// A global rather than a parameter because every download in this file may run
/// on one of `max_workers` threads, and threading a store through the worker
/// queue would buy nothing: it is written once by the host at startup and only
/// ever read afterwards. `install` and `resolve` set it; nothing else writes it.
pub var credentials: auth.Store = .{};

/// GET `url`, following redirects, returning the body.
///
/// ## Why the redirects are followed by hand
///
/// `std.http.Client` has a `privileged_headers` field documented as "stripped
/// when following a redirect to a different domain", which is exactly the
/// protection a credential needs. It does not work: in 0.16 the send path emits
/// `extra_headers` only, and `privileged_headers` are validated, stored, and
/// cleared on a cross-domain redirect without ever being written to the wire.
/// A credential put there is silently dropped on every request — which is how
/// this was found, by a local server that refused a request the tool believed
/// it had authenticated.
///
/// So the credential goes in `extra_headers`, where it is actually sent, and
/// the redirect chain is walked here. That turns out to be the better rule
/// anyway: the credential is looked up FRESH for each hop's URL, so it can
/// never travel to a host the operator did not configure, and a hop into a
/// host that has its own credential gets that one. std's parent-domain
/// heuristic would have sent a github.com token to any `*.github.com`.
pub fn download(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    // Refused before a socket is opened, not after: the point of the check is
    // that the bytes never arrive.
    if (!allowedUrl(url)) return Error.InsecureUrl;

    // Mutual TLS is not something `std.crypto.tls.Client` can do — its
    // `Options` has no client-certificate field at all — so a host configured
    // with one is fetched through `curl`, which does. The same applies to a
    // custom CA bundle and to `disable-tls`: std's client verifies against a
    // bundle it loads itself, with no hook for either. Confined to exactly the
    // hosts and settings that need it; everything else takes the ordinary path.
    if (credentials.clientCertificate(url)) |cert| {
        return curlFetch(allocator, io, url, cert);
    }
    if (ca_file != null or ca_path != null or disable_tls) {
        return curlFetch(allocator, io, url, null);
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var target = url;
    var hops: usize = 0;
    // GitHub's zipball endpoint redirects to codeload and codeload may redirect
    // again; five is what the previous behaviour allowed and what a dist URL
    // has ever needed.
    while (hops < 5) : (hops += 1) {
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(allocator, .{ .name = "user-agent", .value = "hkm-pkg" });
        try headers.append(allocator, .{ .name = "accept", .value = "*/*" });
        for (credentials.headersFor(allocator, target)) |h| {
            try headers.append(allocator, .{ .name = h.name, .value = h.value });
        }

        const result = client.fetch(.{
            .location = .{ .url = target },
            .response_writer = &body.writer,
            // Handled here instead — see above.
            .redirect_behavior = .unhandled,
            .extra_headers = headers.items,
        }) catch return Error.DownloadFailed;

        if (result.status.class() == .redirect) {
            // `fetch` discards the head, so the hop target comes from a second
            // request issued with the same rules. Cheap: a redirect body is
            // empty, and this only happens on the dist path.
            target = try redirectTarget(allocator, io, &client, target, headers.items) orelse
                return Error.DownloadFailed;
            continue;
        }

        if (result.status != .ok) return Error.DownloadFailed;
        return allocator.dupe(u8, body.written());
    }
    return Error.DownloadFailed;
}

/// The absolute URL a redirect points at.
fn redirectTarget(
    allocator: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    from: []const u8,
    headers: []const std.http.Header,
) !?[]const u8 {
    _ = io;
    var req = client.request(.GET, std.Uri.parse(from) catch return null, .{
        .redirect_behavior = .unhandled,
        .extra_headers = headers,
    }) catch return null;
    defer req.deinit();

    req.sendBodiless() catch return null;
    const response = req.receiveHead(&.{}) catch return null;
    const location = response.head.location orelse return null;

    // A relative Location is legal and common. Resolving it against the current
    // URL is what keeps the host — and therefore the credential lookup —
    // correct on the next hop.
    if (std.mem.indexOf(u8, location, "://") != null) return try allocator.dupe(u8, location);

    const base = std.Uri.parse(from) catch return null;
    const scheme = base.scheme;
    const host = switch (base.host orelse return null) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    if (location.len > 0 and location[0] == '/') {
        return try std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ scheme, host, location });
    }
    return try std.fmt.allocPrint(allocator, "{s}://{s}/{s}", .{ scheme, host, location });
}

/// GET through `curl`, for a host that requires a client certificate.
///
/// The one request path that is not `std.http.Client`. It exists because Zig's
/// TLS client cannot present a certificate, and the alternative to shelling out
/// is telling an operator with a perfectly ordinary mTLS repository that their
/// setup is unsupported.
///
/// `--fail-with-body` rather than `--fail`: an HTTP error still exits non-zero,
/// so the caller sees a failure, but the body comes back too, which is where a
/// server puts the reason it refused.
fn curlFetch(
    allocator: std.mem.Allocator,
    io: Io,
    url: []const u8,
    cert: ?auth.Credential,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{
        "curl", "--silent", "--show-error", "--location", "--user-agent", "hkm-pkg",
    });
    if (cert) |c| {
        try argv.appendSlice(allocator, &.{ "--cert", c.cert });
        if (c.key.len > 0) try argv.appendSlice(allocator, &.{ "--key", c.key });
    }
    if (ca_file) |f| try argv.appendSlice(allocator, &.{ "--cacert", f });
    if (ca_path) |d| try argv.appendSlice(allocator, &.{ "--capath", d });
    // `--insecure` is what `disable-tls` asks for and it is spelled out here
    // rather than hidden behind a helper, because a reader auditing this file
    // should meet the words "do not verify" at the point it happens.
    if (disable_tls) try argv.append(allocator, "--insecure");
    if (process_timeout > 0) {
        try argv.appendSlice(allocator, &.{
            "--max-time",
            try std.fmt.allocPrint(allocator, "{d}", .{process_timeout}),
        });
    }

    // A credential still has to reach a request that curl is making — the
    // header path below is skipped entirely when std's client is not used.
    for (credentials.headersFor(allocator, url)) |h| {
        try argv.appendSlice(allocator, &.{
            "--header",
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.name, h.value }),
        });
    }
    // Via stdin, not argv: an argument is visible in `ps` to every user on the
    // machine, and a key passphrase is exactly the thing that must not be.
    const passphrase: []const u8 = if (cert) |c| c.passphrase else "";
    if (passphrase.len > 0) try argv.appendSlice(allocator, &.{ "--pass", "-" });
    try argv.append(allocator, url);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = if (passphrase.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return Error.DownloadFailed;

    if (child.stdin) |f| {
        var buf: [256]u8 = undefined;
        var writer = f.writer(io, &buf);
        writer.interface.writeAll(passphrase) catch {};
        writer.interface.flush() catch {};
        f.close(io);
        child.stdin = null;
    }

    var out: std.ArrayList(u8) = .empty;
    if (child.stdout) |f| {
        var buf: [64 * 1024]u8 = undefined;
        var reader = f.reader(io, &buf);
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch break;
            out.appendSlice(allocator, chunk) catch break;
            reader.interface.toss(chunk.len);
        }
    }

    const term = child.wait(io) catch return Error.DownloadFailed;
    switch (term) {
        .exited => |code| if (code != 0) return Error.DownloadFailed,
        else => return Error.DownloadFailed,
    }
    if (out.items.len == 0) return Error.DownloadFailed;
    return out.toOwnedSlice(allocator);
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
        .unverified = .init(0),
        .progress = progress,
    };

    const n = @min(@max(workers, 1), wants.len);

    // A single worker needs no threads at all — and this is also the fallback
    // when the OS refuses to spawn one, so a machine that cannot thread still
    // installs rather than failing.
    if (n == 1) {
        work(&shared);
        last_unverified = shared.unverified.load(.monotonic);
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
    last_unverified = shared.unverified.load(.monotonic);
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
    unverified: std.atomic.Value(usize),
    progress: ?*const fn (done: usize, total: usize, url: []const u8) void,
};

/// How many archives the last `prefetch` downloaded with no checksum.
///
/// A counter rather than a return value because `prefetch` already returns the
/// byte total and the callers that care about this are reporting a summary, not
/// making a decision mid-run.
pub var last_unverified: usize = 0;

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
        if (got.unverified) _ = shared.unverified.fetchAdd(1, .monotonic);

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
