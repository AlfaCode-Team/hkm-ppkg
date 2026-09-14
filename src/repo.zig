//! The two repository kinds that publish packages without a server:
//! `package` (the definition is written inline) and `artifact` (a directory of
//! archives).
//!
//! ## `package` — a definition, not a location
//!
//! Every other repository type answers the question "where do I get this?".
//! A `package` repository answers "what IS this?" — the entry contains the
//! package object itself, exactly as it would appear in packagist metadata, and
//! nothing is fetched to discover it. It is what a project uses to depend on a
//! library whose author never published one: a zip on an internal file server,
//! a tag in a repository with no composer.json of its own.
//!
//! Because nothing validates it, a `package` entry is the one place where a
//! silent mistake is cheapest to make. Two are rejected here rather than
//! carried into a lock:
//!
//!   * no `name` or no `version` — Composer errors, and a candidate with an
//!     empty version normalises to something that satisfies nothing, so the
//!     package would simply never be chosen and never be reported;
//!   * neither `dist` nor `source` — resolvable, lockable, and then
//!     uninstallable, which is the worst of the three outcomes because it fails
//!     on a different machine than the one that wrote the lock.
//!
//! ## `artifact` — a directory of archives
//!
//! Composer scans the directory for archives and reads each one's composer.json
//! to learn what it is. The version comes from the FILE, not from the filename:
//! `mylib-1.0.0.zip` containing a manifest that says `2.0.0` is `2.0.0`, and
//! guessing from the name is how a build ends up pinning a version that does
//! not exist.
//!
//! Reading a manifest out of an archive means unpacking it, so the result is
//! cached against the archive's own size and mtime. A directory of fifty
//! artifacts is unpacked once and then costs one `stat` each.

const std = @import("std");
const manifest = @import("manifest.zig");
const packagist = @import("packagist.zig");
const lock = @import("lock.zig");
const archive = @import("archive.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Error = error{
    NotADirectory,
};

/// One rejected entry, with the reason, so a mistake is reported rather than
/// silently dropped.
pub const Rejection = struct {
    subject: []const u8,
    reason: []const u8,
};

pub const Result = struct {
    candidates: []const packagist.Candidate = &.{},
    rejected: []const Rejection = &.{},
};

// ── package repositories ──────────────────────────────────────────────────────

/// Every package a `package` repository declares.
///
/// Composer accepts the `package` key as either one object or a list of them,
/// and both spellings appear in real manifests.
pub fn inlinePackages(allocator: std.mem.Allocator, repo: manifest.Repo) !Result {
    const raw = repo.raw orelse return .{};
    if (raw != .object) return .{};
    const entry = raw.object.get("package") orelse return .{};

    var candidates: std.ArrayList(packagist.Candidate) = .empty;
    var rejected: std.ArrayList(Rejection) = .empty;

    switch (entry) {
        .object => try one(allocator, entry, &candidates, &rejected),
        .array => |items| for (items.items) |item| try one(allocator, item, &candidates, &rejected),
        else => return .{},
    }

    return .{
        .candidates = try candidates.toOwnedSlice(allocator),
        .rejected = try rejected.toOwnedSlice(allocator),
    };
}

fn one(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    candidates: *std.ArrayList(packagist.Candidate),
    rejected: *std.ArrayList(Rejection),
) !void {
    if (value != .object) {
        try rejected.append(allocator, .{ .subject = "package", .reason = "is not an object" });
        return;
    }
    const obj = value.object;

    const name = stringAt(obj, "name") orelse {
        try rejected.append(allocator, .{ .subject = "package", .reason = "has no \"name\"" });
        return;
    };
    const version = stringAt(obj, "version") orelse {
        try rejected.append(allocator, .{ .subject = name, .reason = "has no \"version\"" });
        return;
    };

    // The check that pays for itself: a definition with neither a dist nor a
    // source resolves and locks, and then fails to install — on whichever
    // machine runs `install` next, not on the one that wrote the lock.
    if (obj.get("dist") == null and obj.get("source") == null) {
        try rejected.append(allocator, .{
            .subject = name,
            .reason = "declares neither \"dist\" nor \"source\", so nothing could install it",
        });
        return;
    }

    try candidates.append(allocator, .{
        .name = name,
        .version = version,
        .version_normalized = lock.normalizeVersion(allocator, version) catch version,
        .kind = stringAt(obj, "type") orelse "library",
        .origin = .declared,
        .raw = value,
    });
}

// ── artifact repositories ─────────────────────────────────────────────────────

/// Every package in a directory of archives.
///
/// `dir` is the repository's `url`, resolved against the project root when it
/// is relative — which is how it is nearly always written.
pub fn artifacts(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    cache_dir: []const u8,
    repo: manifest.Repo,
) !Result {
    if (repo.url.len == 0) return .{};

    const dir_path = if (std.fs.path.isAbsolute(repo.url))
        repo.url
    else
        try std.fs.path.join(allocator, &.{ root_dir, repo.url });

    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return .{ .rejected = try allocator.dupe(Rejection, &.{.{
            .subject = repo.url,
            .reason = "is not a readable directory",
        }}) };
    };
    defer dir.close(io);

    var candidates: std.ArrayList(packagist.Candidate) = .empty;
    var rejected: std.ArrayList(Rejection) = .empty;

    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        if (item.kind != .file) continue;
        if (!looksLikeArchive(item.name)) continue;

        const full = try std.fs.path.join(allocator, &.{ dir_path, item.name });
        const source = manifestIn(allocator, io, cache_dir, full) orelse {
            try rejected.append(allocator, .{
                .subject = item.name,
                .reason = "contains no readable composer.json",
            });
            continue;
        };

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
            try rejected.append(allocator, .{ .subject = item.name, .reason = "has an unparseable composer.json" });
            continue;
        };
        if (parsed != .object) continue;

        const name = stringAt(parsed.object, "name") orelse {
            try rejected.append(allocator, .{ .subject = item.name, .reason = "declares no package name" });
            continue;
        };
        // The version comes from the manifest INSIDE the archive. Composer
        // reads it there too; taking it from the filename is how a build pins a
        // version that does not exist.
        const version = stringAt(parsed.object, "version") orelse {
            try rejected.append(allocator, .{
                .subject = item.name,
                .reason = "declares no \"version\" — an artifact must carry one, since there is no tag to read it from",
            });
            continue;
        };

        var obj = try parsed.object.clone(allocator);
        var dist: std.json.ObjectMap = .empty;
        try dist.put(allocator, "type", .{ .string = distTypeOf(item.name) });
        // A path, not a URL: the installer recognises it as a local file and
        // unpacks it where it lies rather than trying to fetch it.
        //
        // Written the way the repository was DECLARED — relative stays
        // relative — because that is what Composer records (`getPathname()` on
        // an iterator rooted at the declared url) and a lock full of one
        // machine's absolute paths is a lock nobody else can install from.
        try dist.put(allocator, "url", .{ .string = try std.fs.path.join(allocator, &.{ repo.url, item.name }) });
        // Composer records no `reference` for an artifact and does record a
        // sha1 of the file. The sha1 is also what makes a replaced artifact
        // reinstall: `install` stamps it, so swapping the file behind an
        // unchanged version number is noticed.
        try dist.put(allocator, "shasum", .{ .string = sha1Of(allocator, io, full) orelse "" });
        try obj.put(allocator, "dist", .{ .object = dist });

        try candidates.append(allocator, .{
            .name = name,
            .version = version,
            .version_normalized = lock.normalizeVersion(allocator, version) catch version,
            .kind = stringAt(obj, "type") orelse "library",
            .origin = .declared,
            .raw = .{ .object = obj },
        });
    }

    return .{
        .candidates = try candidates.toOwnedSlice(allocator),
        .rejected = try rejected.toOwnedSlice(allocator),
    };
}

fn looksLikeArchive(name: []const u8) bool {
    for ([_][]const u8{ ".zip", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }
    return false;
}

fn distTypeOf(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".zip")) "zip" else "tar";
}

/// A cheap identity for an artifact file, for the MANIFEST cache only.
///
/// Size and mtime, not a hash: this answers "is the composer.json I extracted
/// from this file last time still the right one", and it is asked once per
/// archive per resolve. The lock records a real sha1 instead — see `sha1Of` —
/// because that value is read by other machines, where an mtime means nothing.
fn identityOf(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return "";
    return std.fmt.allocPrint(allocator, "{d}-{d}", .{ st.size, @as(i128, st.mtime.nanoseconds) });
}

/// `hash_file('sha1', …)`, which is what Composer writes as an artifact's
/// `shasum`.
fn sha1Of(allocator: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    const body = Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024)) catch return null;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(body, &digest, .{});
    return std.fmt.allocPrint(allocator, "{x}", .{&digest}) catch null;
}

/// The composer.json inside an archive, cached against the archive's identity.
fn manifestIn(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    path: []const u8,
) ?[]const u8 {
    const reference = identityOf(allocator, io, path) catch return null;

    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(path);
    h.update(reference);
    h.final(&digest);

    const key = std.fmt.allocPrint(allocator, "{x}.json", .{digest[0..10]}) catch return null;
    const cached_path = std.fs.path.join(allocator, &.{ cache_dir, "artifact", key }) catch return null;

    if (Dir.cwd().readFileAlloc(io, cached_path, allocator, .limited(1024 * 1024)) catch null) |cached| {
        // A recorded miss is empty, so an archive with no manifest is not
        // unpacked again on every resolve.
        return if (cached.len == 0) null else cached;
    }

    const staging = std.fmt.allocPrint(allocator, "{s}.probe", .{cached_path}) catch return null;
    defer Dir.cwd().deleteTree(io, staging) catch {};

    const found: []const u8 = blk: {
        archive.unpackTo(allocator, io, path, staging) catch break :blk "";
        const inner = std.fs.path.join(allocator, &.{ staging, "composer.json" }) catch break :blk "";
        break :blk Dir.cwd().readFileAlloc(io, inner, allocator, .limited(1024 * 1024)) catch "";
    };

    if (util.parentOf(cached_path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
    util.writeFileAtomic(io, cached_path, found) catch {};
    return if (found.len == 0) null else found;
}

fn stringAt(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn repoFrom(allocator: std.mem.Allocator, json: []const u8) manifest.Repo {
    const v = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch unreachable;
    return .{ .kind = .package, .url = "", .raw = v };
}

test "an inline package becomes a candidate carrying its whole definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try inlinePackages(a, repoFrom(a,
        \\{"type":"package","package":{
        \\  "name":"acme/legacy","version":"1.4.0","type":"library",
        \\  "dist":{"type":"zip","url":"https://files.internal/legacy-1.4.0.zip"},
        \\  "autoload":{"classmap":["src/"]}
        \\}}
    ));

    try testing.expectEqual(@as(usize, 1), r.candidates.len);
    try testing.expectEqual(@as(usize, 0), r.rejected.len);
    try testing.expectEqualStrings("acme/legacy", r.candidates[0].name);
    try testing.expectEqualStrings("1.4.0.0", r.candidates[0].version_normalized);
    // The definition survives whole — the autoload block is what the generated
    // autoloader is built from, and dropping it produces a package that
    // installs and cannot be used.
    try testing.expect(r.candidates[0].field("autoload") != null);
}

test "a list of packages in one repository is accepted, like Composer's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try inlinePackages(a, repoFrom(a,
        \\{"type":"package","package":[
        \\  {"name":"a/one","version":"1.0.0","dist":{"type":"zip","url":"u"}},
        \\  {"name":"a/two","version":"2.0.0","source":{"type":"git","url":"u","reference":"abc"}}
        \\]}
    ));
    try testing.expectEqual(@as(usize, 2), r.candidates.len);
}

test "a definition that could never install is rejected, with the reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Resolvable, lockable, and then uninstallable on a different machine.
    const no_source = try inlinePackages(a, repoFrom(a,
        \\{"type":"package","package":{"name":"acme/x","version":"1.0.0"}}
    ));
    try testing.expectEqual(@as(usize, 0), no_source.candidates.len);
    try testing.expectEqual(@as(usize, 1), no_source.rejected.len);
    try testing.expect(std.mem.indexOf(u8, no_source.rejected[0].reason, "install") != null);

    // A version-less definition matches no constraint, so it would silently
    // never be chosen.
    const no_version = try inlinePackages(a, repoFrom(a,
        \\{"type":"package","package":{"name":"acme/x","dist":{"type":"zip","url":"u"}}}
    ));
    try testing.expectEqual(@as(usize, 0), no_version.candidates.len);
    try testing.expectEqualStrings("acme/x", no_version.rejected[0].subject);
}

test "an archive name maps to the dist type the installer will sniff anyway" {
    try testing.expectEqualStrings("zip", distTypeOf("thing-1.0.0.zip"));
    try testing.expectEqualStrings("tar", distTypeOf("thing-1.0.0.tar.gz"));
    try testing.expect(looksLikeArchive("thing-1.0.0.tgz"));
    try testing.expect(!looksLikeArchive("README.md"));
    try testing.expect(!looksLikeArchive("thing.zip.bak"));
}
