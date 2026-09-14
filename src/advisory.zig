//! `audit`, `search`, `fund` and `suggests` — the three packagist endpoints
//! that answer a question about packages rather than fetching one.
//!
//! `audit` is the one that matters. It asks packagist which of the versions in
//! this project's lock have a published security advisory against them, and it
//! is the reason a fast installer is not enough on its own: an install that
//! completes in a second and pins a package with a known RCE has not done the
//! user a favour.
//!
//! The advisory endpoint takes the package NAMES only, never the versions —
//! matching a version against `affectedVersions` happens here, with the same
//! constraint algebra the resolver uses. That keeps the request from being a
//! description of the project's dependency graph sent to a third party.

const std = @import("std");
const fetch = @import("fetch.zig");
const lockfile = @import("lock.zig");
const manifest = @import("manifest.zig");
const constraint = @import("constraint.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const default_repo = "https://packagist.org";

pub const Severity = enum {
    critical,
    high,
    medium,
    low,
    unknown,

    pub fn of(text: []const u8) Severity {
        if (std.ascii.eqlIgnoreCase(text, "critical")) return .critical;
        if (std.ascii.eqlIgnoreCase(text, "high")) return .high;
        if (std.ascii.eqlIgnoreCase(text, "medium")) return .medium;
        if (std.ascii.eqlIgnoreCase(text, "low")) return .low;
        return .unknown;
    }

    /// Most severe first, so the worst finding is the first line read.
    pub fn rank(self: Severity) u8 {
        return switch (self) {
            .critical => 0,
            .high => 1,
            .medium => 2,
            .low => 3,
            .unknown => 4,
        };
    }
};

pub const Advisory = struct {
    package: []const u8,
    /// The version installed here, which the constraint below matched.
    version: []const u8,
    title: []const u8,
    cve: []const u8,
    link: []const u8,
    affected: []const u8,
    severity: Severity,
};

pub const Options = struct {
    dev: bool = true,
    repo: []const u8 = default_repo,
    /// Report and exit 0 even when something was found. For a `install` that
    /// audits as a courtesy rather than as a gate.
    advisory_only: bool = false,
};

/// `hkm ppkg audit` — every advisory that applies to a LOCKED version.
pub fn audit(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    opts: Options,
) !u8 {
    const lock = lockfile.read(allocator, io, root_dir) catch {
        prompt.err("No composer.lock here. `audit` reports on the versions a lock pins.");
        return 1;
    };
    const packages = try lock.selected(allocator, opts.dev);
    if (packages.len == 0) {
        prompt.note("Nothing locked; nothing to audit.");
        return 0;
    }

    const body = request(allocator, io, env, opts.repo, packages) catch {
        prompt.err("Could not reach the advisory database.");
        return 1;
    };

    const found = try match(allocator, body, packages);
    if (found.len == 0) {
        prompt.ok(try std.fmt.allocPrint(
            allocator,
            "No known security advisories against the {d} locked package(s).",
            .{packages.len},
        ));
        return 0;
    }

    prompt.section("Security advisories");
    for (found) |a| {
        prompt.item(
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ a.package, a.version }),
            try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ @tagName(a.severity), a.title }),
        );
        if (a.cve.len > 0) prompt.muted(try std.fmt.allocPrint(allocator, "      {s}  ·  affects {s}", .{ a.cve, a.affected }));
        if (a.link.len > 0) prompt.muted(try std.fmt.allocPrint(allocator, "      {s}", .{a.link}));
    }
    prompt.blank();
    prompt.warn(try std.fmt.allocPrint(allocator, "{d} advisory(ies) match a locked version.", .{found.len}));

    // Non-zero by default, so a CI step that runs this FAILS. An audit that
    // always exits 0 is a log line, not a gate.
    return if (opts.advisory_only) 0 else 1;
}

/// The advisories in `body` that apply to a version actually locked here.
pub fn match(
    allocator: std.mem.Allocator,
    body: []const u8,
    packages: []const lockfile.Package,
) ![]const Advisory {
    var out: std.ArrayList(Advisory) = .empty;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch
        return out.toOwnedSlice(allocator);
    if (parsed != .object) return out.toOwnedSlice(allocator);
    const advisories = parsed.object.get("advisories") orelse return out.toOwnedSlice(allocator);
    if (advisories != .object) return out.toOwnedSlice(allocator);

    for (packages) |pkg| {
        const list = advisories.object.get(pkg.name) orelse continue;
        if (list != .array) continue;

        for (list.array.items) |entry| {
            if (entry != .object) continue;
            const affected = str(entry.object, "affectedVersions");
            // `affectedVersions` uses `|` for OR, which this constraint parser
            // already reads as the legacy single-pipe alternative.
            const c = constraint.parse(allocator, affected) catch continue;
            if (!c.accepts(pkg.version)) continue;

            try out.append(allocator, .{
                .package = pkg.name,
                .version = pkg.version,
                .title = str(entry.object, "title"),
                .cve = str(entry.object, "cve"),
                .link = str(entry.object, "link"),
                .affected = affected,
                .severity = Severity.of(str(entry.object, "severity")),
            });
        }
    }

    std.mem.sort(Advisory, out.items, {}, moreSevere);
    return out.toOwnedSlice(allocator);
}

fn moreSevere(_: void, a: Advisory, b: Advisory) bool {
    if (a.severity.rank() != b.severity.rank()) return a.severity.rank() < b.severity.rank();
    return std.mem.order(u8, a.package, b.package) == .lt;
}

/// Ask the advisory endpoint about these package NAMES.
///
/// Names only. Sending the versions too would let the endpoint do the matching
/// and save a little work here, at the cost of handing a third party a complete
/// inventory of what this project runs.
fn request(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    repo: []const u8,
    packages: []const lockfile.Package,
) ![]const u8 {
    _ = env;
    var url: std.ArrayList(u8) = .empty;
    try url.appendSlice(allocator, repo);
    try url.appendSlice(allocator, "/api/security-advisories/?");
    for (packages, 0..) |pkg, i| {
        if (i > 0) try url.append(allocator, '&');
        try url.appendSlice(allocator, "packages%5B%5D=");
        try appendEncoded(allocator, &url, pkg.name);
    }
    return fetch.download(allocator, io, url.items);
}

// ── search ────────────────────────────────────────────────────────────────────

pub const Hit = struct {
    name: []const u8,
    description: []const u8,
    url: []const u8,
    downloads: i64,
    stars: i64,
};

/// `hkm ppkg search <terms>` — packagist's search index.
pub fn search(
    allocator: std.mem.Allocator,
    io: Io,
    query: []const u8,
    limit: usize,
    repo: []const u8,
) !u8 {
    var url: std.ArrayList(u8) = .empty;
    try url.appendSlice(allocator, repo);
    try url.appendSlice(allocator, "/search.json?q=");
    try appendEncoded(allocator, &url, query);
    try url.print(allocator, "&per_page={d}", .{limit});

    const body = fetch.download(allocator, io, url.items) catch {
        prompt.err("Could not reach the package index.");
        return 1;
    };

    const hits = try parseHits(allocator, body);
    if (hits.len == 0) {
        prompt.note(try std.fmt.allocPrint(allocator, "Nothing matched '{s}'.", .{query}));
        return 0;
    }

    prompt.section(try std.fmt.allocPrint(allocator, "{d} result(s) for '{s}'", .{ hits.len, query }));
    for (hits) |h| {
        prompt.item(h.name, h.description);
        prompt.muted(try std.fmt.allocPrint(
            allocator,
            "      {d} installs  ·  {d} stars",
            .{ h.downloads, h.stars },
        ));
    }
    prompt.blank();
    return 0;
}

pub fn parseHits(allocator: std.mem.Allocator, body: []const u8) ![]const Hit {
    var out: std.ArrayList(Hit) = .empty;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch
        return out.toOwnedSlice(allocator);
    if (parsed != .object) return out.toOwnedSlice(allocator);
    const results = parsed.object.get("results") orelse return out.toOwnedSlice(allocator);
    if (results != .array) return out.toOwnedSlice(allocator);

    for (results.array.items) |item| {
        if (item != .object) continue;
        try out.append(allocator, .{
            .name = str(item.object, "name"),
            .description = str(item.object, "description"),
            .url = str(item.object, "url"),
            .downloads = num(item.object, "downloads"),
            .stars = num(item.object, "favers"),
        });
    }
    return out.toOwnedSlice(allocator);
}

// ── shared ────────────────────────────────────────────────────────────────────

fn str(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn num(o: std.json.ObjectMap, key: []const u8) i64 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

/// Percent-encode everything that is not unreserved.
///
/// A package name is `vendor/name` and a search term is whatever was typed;
/// both go into a query string, and pasting them in raw is how a `&` in a
/// search term becomes a second parameter.
fn appendEncoded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an advisory matches only the versions its constraint covers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The real shape packagist returns, including the `|` alternation.
    const body =
        \\{"advisories":{"guzzlehttp/guzzle":[{
        \\  "title":"Noncanonical host can bypass host-based checks",
        \\  "cve":"CVE-2026-69246","link":"https://example/advisory",
        \\  "affectedVersions":">=8.0.0,<8.0.1|<7.15.2","severity":"high"
        \\}]}}
    ;

    const vulnerable = try match(a, body, &.{
        .{ .name = "guzzlehttp/guzzle", .version = "7.9.2", .raw = .null },
    });
    try testing.expectEqual(@as(usize, 1), vulnerable.len);
    try testing.expectEqual(Severity.high, vulnerable[0].severity);
    try testing.expectEqualStrings("CVE-2026-69246", vulnerable[0].cve);

    // A patched version is not reported, which is the whole point.
    const patched = try match(a, body, &.{
        .{ .name = "guzzlehttp/guzzle", .version = "7.15.2", .raw = .null },
    });
    try testing.expectEqual(@as(usize, 0), patched.len);

    // Neither is a package the advisory is not about.
    const unrelated = try match(a, body, &.{
        .{ .name = "psr/log", .version = "1.0.0", .raw = .null },
    });
    try testing.expectEqual(@as(usize, 0), unrelated.len);
}

test "findings come back worst-first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body =
        \\{"advisories":{
        \\  "a/low":[{"title":"l","affectedVersions":"*","severity":"low"}],
        \\  "b/critical":[{"title":"c","affectedVersions":"*","severity":"critical"}],
        \\  "c/medium":[{"title":"m","affectedVersions":"*","severity":"medium"}]
        \\}}
    ;
    const found = try match(a, body, &.{
        .{ .name = "a/low", .version = "1.0.0", .raw = .null },
        .{ .name = "b/critical", .version = "1.0.0", .raw = .null },
        .{ .name = "c/medium", .version = "1.0.0", .raw = .null },
    });
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(Severity.critical, found[0].severity);
    try testing.expectEqual(Severity.medium, found[1].severity);
    try testing.expectEqual(Severity.low, found[2].severity);
}

test "a query string cannot be widened by what is put in it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    try appendEncoded(a, &out, "guzzlehttp/guzzle");
    try testing.expectEqualStrings("guzzlehttp%2Fguzzle", out.items);

    var evil: std.ArrayList(u8) = .empty;
    try appendEncoded(a, &evil, "x&packages[]=y");
    try testing.expectEqualStrings("x%26packages%5B%5D%3Dy", evil.items);
}

test "search results are read out of packagist's shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hits = try parseHits(a,
        \\{"results":[{"name":"psr/log","description":"Common interface for logging libraries",
        \\ "url":"https://packagist.org/packages/psr/log","downloads":1273947254,"favers":10603}]}
    );
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("psr/log", hits[0].name);
    try testing.expectEqual(@as(i64, 10603), hits[0].stars);

    // A malformed body is an empty result, not a crash: this is network input.
    try testing.expectEqual(@as(usize, 0), (try parseHits(a, "not json")).len);
    try testing.expectEqual(@as(usize, 0), (try parseHits(a, "{}")).len);
}
