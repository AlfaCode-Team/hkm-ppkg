//! `composer.lock` — the exact set of packages an install must produce.
//!
//! A lock is the reason a native installer needs no dependency solver: every
//! version is already decided and every package carries the URL and reference to
//! fetch it from. `hkm ppkg install` is therefore a DOWNLOAD, not a resolution —
//! which is also why it is untouched by the GitHub API rate limit that makes
//! Composer slow here. Metadata calls are what get throttled; dist downloads
//! redirect to codeload and cost no quota.
//!
//! Each package keeps its RAW json object alongside the parsed fields, because
//! `vendor/composer/installed.json` is very nearly the lock's package objects
//! with three keys added. Re-emitting from the original preserves every field
//! this tool does not model — funding, authors, support, extra — instead of
//! silently dropping them from the installed metadata.

const std = @import("std");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const DistType = enum { zip, tar, path, none };

pub const Dist = struct {
    kind: DistType = .none,
    url: []const u8 = "",
    reference: []const u8 = "",
    shasum: []const u8 = "",
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    kind: []const u8 = "library",
    dist: Dist = .{},
    /// Executables the package publishes, relative to its own directory.
    bin: []const []const u8 = &.{},
    /// True when the package came from `packages-dev`.
    dev: bool = false,
    /// The package object exactly as the lock spells it.
    raw: std.json.Value,

    /// Where this package is installed, relative to the vendor directory.
    pub fn installDir(self: Package, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}", .{self.name});
    }
};

pub const Lock = struct {
    packages: []const Package,
    content_hash: []const u8 = "",
    /// `platform` requirements recorded at lock time (php, ext-*).
    platform: []const Requirement = &.{},

    pub const Requirement = struct { name: []const u8, constraint: []const u8 };

    /// Packages that should be installed for this run.
    pub fn selected(self: Lock, allocator: std.mem.Allocator, with_dev: bool) ![]const Package {
        if (with_dev) return self.packages;

        var out: std.ArrayList(Package) = .empty;
        for (self.packages) |p| {
            if (!p.dev) try out.append(allocator, p);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const Error = error{ NoLockFile, MalformedLock };

/// Read `<dir>/composer.lock`.
pub fn read(allocator: std.mem.Allocator, io: Io, dir: []const u8) !Lock {
    const path = try std.fs.path.join(allocator, &.{ dir, "composer.lock" });
    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch {
        return Error.NoLockFile;
    };
    return parse(allocator, source);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Lock {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
        return Error.MalformedLock;
    };
    if (parsed != .object) return Error.MalformedLock;
    const obj = parsed.object;

    var packages: std.ArrayList(Package) = .empty;
    try collect(allocator, obj, "packages", false, &packages);
    try collect(allocator, obj, "packages-dev", true, &packages);

    return .{
        .packages = try packages.toOwnedSlice(allocator),
        .content_hash = strField(obj, "content-hash") orelse "",
        .platform = try requirements(allocator, obj, "platform"),
    };
}

fn collect(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    dev: bool,
    out: *std.ArrayList(Package),
) !void {
    const raw = obj.get(key) orelse return;
    if (raw != .array) return;

    for (raw.array.items) |item| {
        if (item != .object) continue;
        const name = strField(item.object, "name") orelse continue;
        try out.append(allocator, .{
            .name = name,
            .version = strField(item.object, "version") orelse "",
            .kind = strField(item.object, "type") orelse "library",
            .dist = distOf(item.object),
            .bin = try strList(allocator, item.object, "bin"),
            .dev = dev,
            .raw = item,
        });
    }
}

fn distOf(obj: std.json.ObjectMap) Dist {
    const raw = obj.get("dist") orelse return .{};
    if (raw != .object) return .{};

    const kind_name = strField(raw.object, "type") orelse "";
    return .{
        .kind = if (std.mem.eql(u8, kind_name, "zip"))
            .zip
        else if (std.mem.eql(u8, kind_name, "tar"))
            .tar
        else if (std.mem.eql(u8, kind_name, "path"))
            .path
        else
            .none,
        .url = strField(raw.object, "url") orelse "",
        .reference = strField(raw.object, "reference") orelse "",
        .shasum = strField(raw.object, "shasum") orelse "",
    };
}

fn requirements(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const Lock.Requirement {
    const raw = obj.get(key) orelse return &.{};
    if (raw != .object) return &.{};

    var out: std.ArrayList(Lock.Requirement) = .empty;
    var it = raw.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        try out.append(allocator, .{ .name = e.key_ptr.*, .constraint = e.value_ptr.string });
    }
    return out.toOwnedSlice(allocator);
}

fn strList(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const raw = obj.get(key) orelse return &.{};
    if (raw != .array) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    for (raw.array.items) |item| if (item == .string) try out.append(allocator, item.string);
    return out.toOwnedSlice(allocator);
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── version normalisation ─────────────────────────────────────────────────────

/// Composer's `VersionParser::normalize`, for the subset that appears in a lock.
///
/// `installed.json` carries `version_normalized` while `composer.lock` does not,
/// so it has to be derived. It is not cosmetic: `InstalledVersions::satisfies()`
/// compares against this string at runtime, so a package asking "is X at least
/// 2.1?" gets its answer from here.
///
///     1.2.3        → 1.2.3.0
///     v1.2         → 1.2.0.0
///     1.0.0-beta1  → 1.0.0.0-beta1
///     13.2.x-dev   → 13.2.9999999.9999999-dev
///     dev-master   → dev-master        (unchanged)
pub fn normalizeVersion(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const v = std.mem.trim(u8, version, " \t");
    if (v.len == 0) return allocator.dupe(u8, v);

    // A branch name is its own normal form.
    if (std.mem.startsWith(u8, v, "dev-")) return allocator.dupe(u8, v);

    var body = v;
    if (body.len > 0 and (body[0] == 'v' or body[0] == 'V')) body = body[1..];

    // `1.2.x-dev` / `1.2.*-dev` — a branch alias, padded to the maximum so it
    // sorts above every real release on that branch.
    if (std.mem.endsWith(u8, body, "-dev")) {
        const stem = body[0 .. body.len - 4];
        if (std.mem.endsWith(u8, stem, ".x") or std.mem.endsWith(u8, stem, ".*")) {
            const numeric = stem[0 .. stem.len - 2];
            return std.fmt.allocPrint(allocator, "{s}.9999999.9999999-dev", .{numeric});
        }
    }

    // Split a stability/pre-release suffix off the numeric part.
    var numeric = body;
    var suffix: []const u8 = "";
    if (std.mem.indexOfScalar(u8, body, '-')) |at| {
        numeric = body[0..at];
        suffix = body[at..];
    }

    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, numeric, '.');
    while (it.next()) |_| parts += 1;

    // Not a dotted numeric version at all — hand it back untouched rather than
    // invent a normal form for something unrecognised.
    if (!isNumericVersion(numeric)) return allocator.dupe(u8, v);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, numeric);
    // Composer normalises to exactly four numeric components.
    var pad = parts;
    while (pad < 4) : (pad += 1) try out.appendSlice(allocator, ".0");
    try out.appendSlice(allocator, suffix);
    return out.toOwnedSlice(allocator);
}

fn isNumericVersion(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "version normalisation matches composer's four-component form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("1.2.3.0", try normalizeVersion(a, "1.2.3"));
    try testing.expectEqualStrings("1.2.0.0", try normalizeVersion(a, "v1.2"));
    try testing.expectEqualStrings("14.2.4.0", try normalizeVersion(a, "14.2.4"));
    try testing.expectEqualStrings("1.0.0.0-beta1", try normalizeVersion(a, "1.0.0-beta1"));
}

test "branch aliases pad to the maximum so they outrank releases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("13.2.9999999.9999999-dev", try normalizeVersion(a, "13.2.x-dev"));
    try testing.expectEqualStrings("2.2.9999999.9999999-dev", try normalizeVersion(a, "2.2.x-dev"));
}

test "a dev branch is its own normal form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("dev-master", try normalizeVersion(a, "dev-master"));
    try testing.expectEqualStrings(
        "dev-68f72dbeb9740a814e7c47c937c955b3f130edda",
        try normalizeVersion(a, "dev-68f72dbeb9740a814e7c47c937c955b3f130edda"),
    );
}

test "an unrecognised version is returned untouched, not guessed at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("weird-thing", try normalizeVersion(arena.allocator(), "weird-thing"));
}

test "dev packages are separated from runtime packages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parse(a,
        \\{"packages":[{"name":"a/one","version":"1.0.0","dist":{"type":"zip","url":"u","reference":"r"}}],
        \\ "packages-dev":[{"name":"b/two","version":"2.0.0"}],
        \\ "content-hash":"abc"}
    );

    try testing.expectEqual(@as(usize, 2), l.packages.len);
    try testing.expectEqualStrings("abc", l.content_hash);
    try testing.expect(!l.packages[0].dev);
    try testing.expect(l.packages[1].dev);
    try testing.expectEqual(DistType.zip, l.packages[0].dist.kind);

    const runtime_only = try l.selected(a, false);
    try testing.expectEqual(@as(usize, 1), runtime_only.len);
    try testing.expectEqualStrings("a/one", runtime_only[0].name);
}

test "every version in the kernel's own vendor tree normalises as composer wrote it" {
    // Extracted from vendor/composer/installed.json — 81 distinct
    // (version, version_normalized) pairs as Composer actually produced them.
    // A table of real data rather than invented cases: the failure this guards
    // against is a rule that looks right and disagrees with Composer on some
    // shape nobody thought to imagine.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "1.0.0", "1.0.0.0" },
        .{ "1.0.1", "1.0.1.0" },
        .{ "1.0.3", "1.0.3.0" },
        .{ "1.0.5", "1.0.5.0" },
        .{ "1.1.0", "1.1.0.0" },
        .{ "1.12.1", "1.12.1.0" },
        .{ "1.13.4", "1.13.4.0" },
        .{ "1.17.0", "1.17.0.0" },
        .{ "1.2.0", "1.2.0.0" },
        .{ "1.2.2", "1.2.2.0" },
        .{ "1.3.0", "1.3.0.0" },
        .{ "1.5.13", "1.5.13.0" },
        .{ "1.6.0", "1.6.0.0" },
        .{ "1.7.3", "1.7.3.0" },
        .{ "13.2.x-dev", "13.2.9999999.9999999-dev" },
        .{ "14.2.4", "14.2.4.0" },
        .{ "2.0.1", "2.0.1.0" },
        .{ "2.0.2", "2.0.2.0" },
        .{ "2.0.4", "2.0.4.0" },
        .{ "2.10.2", "2.10.2.0" },
        .{ "2.13.0", "2.13.0.0" },
        .{ "2.2.x-dev", "2.2.9999999.9999999-dev" },
        .{ "2.5.2", "2.5.2.0" },
        .{ "2.9.2", "2.9.2.0" },
        .{ "3.0.0", "3.0.0.0" },
        .{ "3.0.2", "3.0.2.0" },
        .{ "3.0.3", "3.0.3.0" },
        .{ "3.0.5", "3.0.5.0" },
        .{ "3.2.1", "3.2.1.0" },
        .{ "3.31.0", "3.31.0.0" },
        .{ "3.35.2", "3.35.2.0" },
        .{ "3.390.5", "3.390.5.0" },
        .{ "3.4.0", "3.4.0.0" },
        .{ "3.4.4", "3.4.4.0" },
        .{ "5.0.1", "5.0.1.0" },
        .{ "5.0.2", "5.0.2.0" },
        .{ "6.0.0", "6.0.0.0" },
        .{ "6.10.0", "6.10.0.0" },
        .{ "7.0.0", "7.0.0.0" },
        .{ "7.0.1", "7.0.1.0" },
        .{ "7.15.3", "7.15.3.0" },
        .{ "8.0.0", "8.0.0.0" },
        .{ "8.0.1", "8.0.1.0" },
        .{ "8.1.1", "8.1.1.0" },
        .{ "8.1.x-dev", "8.1.9999999.9999999-dev" },
        .{ "8.3.0", "8.3.0.0" },
        .{ "9.0.0", "9.0.0.0" },
        .{ "9.0.1", "9.0.1.0" },
        .{ "9.3.2", "9.3.2.0" },
        .{ "dev-68f72dbeb9740a814e7c47c937c955b3f130edda", "dev-68f72dbeb9740a814e7c47c937c955b3f130edda" },
        .{ "dev-main", "dev-main" },
        .{ "dev-master", "dev-master" },
        .{ "v0.1.1", "0.1.1.0" },
        .{ "v0.6.7", "0.6.7.0" },
        .{ "v1.14.0", "1.14.0.0" },
        .{ "v1.17.0", "1.17.0.0" },
        .{ "v1.2.0", "1.2.0.0" },
        .{ "v1.2.7", "1.2.7.0" },
        .{ "v1.24.1", "1.24.1.0" },
        .{ "v1.3.0", "1.3.0.0" },
        .{ "v1.37.0", "1.37.0.0" },
        .{ "v1.38.0", "1.38.0.0" },
        .{ "v1.38.1", "1.38.1.0" },
        .{ "v1.38.2", "1.38.2.0" },
        .{ "v1.4.0", "1.4.0.0" },
        .{ "v1.40.0", "1.40.0.0" },
        .{ "v1.41.0", "1.41.0.0" },
        .{ "v1.6.0", "1.6.0.0" },
        .{ "v3.0.2", "3.0.2.0" },
        .{ "v3.3.0", "3.3.0.0" },
        .{ "v3.7.1", "3.7.1.0" },
        .{ "v3.95.18", "3.95.18.0" },
        .{ "v4.7.2", "4.7.2.0" },
        .{ "v5.8.0", "5.8.0.0" },
        .{ "v7.1.0", "7.1.0.0" },
        .{ "v7.4.14", "7.4.14.0" },
        .{ "v7.4.15", "7.4.15.0" },
        .{ "v8.1.0", "8.1.0.0" },
        .{ "v8.1.1", "8.1.1.0" },
        .{ "v8.1.2", "8.1.2.0" },
        .{ "v8.1.3", "8.1.3.0" },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for (cases) |c| {
        const got = try normalizeVersion(arena.allocator(), c[0]);
        testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("normalising '{s}': expected '{s}', got '{s}'\n", .{ c[0], c[1], got });
            return e;
        };
    }
}
