//! Unpacking a package distribution into `vendor/`.
//!
//! A GitHub zipball wraps everything in one generated directory —
//! `guzzlehttp-guzzle-7f2b1e4/` — which is not part of the package and must not
//! appear in `vendor/guzzlehttp/guzzle/`. `std.zip` reports that common prefix
//! through its `Diagnostics`, so the archive is expanded into a staging
//! directory and the inner directory is then MOVED into place.
//!
//! Staging is not just tidiness. A half-extracted package left at the final path
//! is indistinguishable from a complete one — the next run would find the
//! directory present and skip it — so the move, which is atomic on one
//! filesystem, is what makes an interrupted install safe to re-run.
//!
//! ## Formats
//!
//! zip, tar, tar.gz/tgz and tar.xz, chosen by SNIFFING the first bytes rather
//! than by trusting the extension. Composer records `"dist": {"type": "tar"}`
//! for every one of the tarball spellings, and a `package` repository may name
//! a `.tgz` `type: zip` by mistake, so an extension-driven dispatch picks the
//! wrong unpacker on real input. The magic number cannot be wrong.

const std = @import("std");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Error = error{
    ExtractFailed,
    EmptyArchive,
    UnknownFormat,
};

/// What the bytes say the archive is.
pub const Format = enum { zip, tar, tar_gz, tar_xz };

/// Recognise an archive from its leading bytes.
///
/// Deliberately not from the filename: the type recorded in a lock and the
/// suffix on a URL are both things a package author writes by hand, and both
/// are wrong in the wild. A GitHub "zipball" really is a zip; a packagist
/// `dist.type: tar` really is a gzipped tar; but a self-hosted mirror serving
/// `foo.zip` that is actually a tarball only fails at the extractor.
pub fn detect(head: []const u8) ?Format {
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "PK\x03\x04")) return .zip;
    // An empty zip, which `git archive` of an empty tree produces.
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "PK\x05\x06")) return .zip;
    if (head.len >= 2 and head[0] == 0x1f and head[1] == 0x8b) return .tar_gz;
    if (head.len >= 6 and std.mem.eql(u8, head[0..6], "\xfd7zXZ\x00")) return .tar_xz;
    // POSIX tar puts `ustar` at offset 257; the GNU variant follows it with a
    // space rather than a NUL, so only the five letters are compared.
    if (head.len >= 262 and std.mem.eql(u8, head[257..262], "ustar")) return .tar;
    return null;
}

/// Expand `archive` so that its contents land at `dest`, replacing whatever is
/// there.
pub fn unpackTo(
    allocator: std.mem.Allocator,
    io: Io,
    archive: []const u8,
    dest: []const u8,
) !void {
    const parent = util.parentOf(dest) orelse return Error.ExtractFailed;
    try Dir.cwd().createDirPath(io, parent);

    // Beside the destination rather than in a system temp dir, so the final
    // rename stays within one filesystem and cannot fall back to a copy.
    const staging = try std.fmt.allocPrint(allocator, "{s}.ppkg-unpack", .{dest});
    Dir.cwd().deleteTree(io, staging) catch {};
    try Dir.cwd().createDirPath(io, staging);
    errdefer Dir.cwd().deleteTree(io, staging) catch {};

    var root_dir: []const u8 = "";
    {
        var file = Dir.cwd().openFile(io, archive, .{}) catch return Error.ExtractFailed;
        defer file.close(io);

        var head: [512]u8 = undefined;
        const head_len = file.readPositionalAll(io, &head, 0) catch return Error.ExtractFailed;
        const format = detect(head[0..head_len]) orelse return Error.UnknownFormat;

        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buf);
        reader.seekTo(0) catch return Error.ExtractFailed;

        var staging_dir = Dir.cwd().openDir(io, staging, .{}) catch return Error.ExtractFailed;
        defer staging_dir.close(io);

        // Path traversal is rejected by the STANDARD LIBRARY, in both
        // extractors: `std.zip`'s `isBadFilename` refuses an absolute path, any
        // `..` segment and any backslash and fails the whole archive on one,
        // and `std.tar` returns an error rather than write outside `dir`. That
        // is their guarantee, NOT this file's — anything that replaces either
        // extractor inherits the responsibility, and an entry named
        // `../../.ssh/authorized_keys` is what it is protecting against.
        root_dir = switch (format) {
            .zip => blk: {
                var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
                std.zip.extract(staging_dir, &reader, .{ .diagnostics = &diagnostics }) catch return Error.ExtractFailed;
                break :blk try allocator.dupe(u8, diagnostics.root_dir);
            },
            .tar => try untar(allocator, io, staging_dir, &reader.interface),
            .tar_gz => blk: {
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var gz: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
                break :blk try untar(allocator, io, staging_dir, &gz.reader);
            },
            .tar_xz => blk: {
                // xz sizes its dictionary per block, so `Decompress` takes an
                // allocator and grows the buffer it is given.
                const window = allocator.alloc(u8, 1 << 20) catch return Error.ExtractFailed;
                var xz = std.compress.xz.Decompress.init(&reader.interface, allocator, window) catch return Error.ExtractFailed;
                break :blk try untar(allocator, io, staging_dir, &xz.reader);
            },
        };
    }

    // An archive whose entries share one top directory is unwrapped by moving
    // that directory; one without (rare, but a `path` mirror can produce it) is
    // moved whole.
    const source = if (root_dir.len > 0)
        try std.fs.path.join(allocator, &.{ staging, root_dir })
    else
        staging;

    if (!util.dirExists(Dir.cwd(), io, source)) {
        Dir.cwd().deleteTree(io, staging) catch {};
        return Error.EmptyArchive;
    }

    Dir.cwd().deleteTree(io, dest) catch {};
    Dir.cwd().rename(source, Dir.cwd(), dest, io) catch {
        Dir.cwd().deleteTree(io, staging) catch {};
        return Error.ExtractFailed;
    };

    if (root_dir.len > 0) Dir.cwd().deleteTree(io, staging) catch {};
}

fn untar(
    allocator: std.mem.Allocator,
    io: Io,
    dest: Dir,
    reader: *std.Io.Reader,
) ![]const u8 {
    var diagnostics: std.tar.Diagnostics = .{ .allocator = allocator };
    std.tar.extract(io, dest, reader, .{
        .diagnostics = &diagnostics,
        // The wrapping directory is stripped by MOVING it afterwards, exactly
        // as the zip path does, so that both formats reach `dest` by the same
        // route and an archive with no wrapper is handled once rather than
        // twice.
        .strip_components = 0,
        .exclude_empty_directories = false,
    }) catch return Error.ExtractFailed;
    return allocator.dupe(u8, diagnostics.root_dir);
}

/// Point `dest` at `target` — how a `path` repository is installed.
///
/// Composer symlinks path repositories by default, and the kernel's vendor tree
/// relies on it: `vendor/alfacode-team/http` is a link to `modules/http`, so an
/// edit in the module is live without a reinstall. Copying instead would produce
/// a tree that looks right and silently stops tracking the source.
pub fn linkTo(
    allocator: std.mem.Allocator,
    io: Io,
    dest: []const u8,
    target_abs: []const u8,
    vendor_dir: []const u8,
) !void {
    const parent = util.parentOf(dest) orelse return Error.ExtractFailed;
    try Dir.cwd().createDirPath(io, parent);
    Dir.cwd().deleteTree(io, dest) catch {};

    // Relative, like Composer's, so the whole tree can be relocated or shared
    // without every link breaking.
    const rel = try relativeFrom(allocator, parent, target_abs, vendor_dir);
    Dir.cwd().symLink(io, rel, dest, .{ .is_directory = true }) catch return Error.ExtractFailed;
}

/// A `../`-prefixed path from `from_dir` to `target`, both absolute.
fn relativeFrom(
    allocator: std.mem.Allocator,
    from_dir: []const u8,
    target: []const u8,
    _: []const u8,
) ![]const u8 {
    var from_it = std.mem.tokenizeScalar(u8, from_dir, '/');
    var to_it = std.mem.tokenizeScalar(u8, target, '/');

    var from_parts: std.ArrayList([]const u8) = .empty;
    var to_parts: std.ArrayList([]const u8) = .empty;
    while (from_it.next()) |p| try from_parts.append(allocator, p);
    while (to_it.next()) |p| try to_parts.append(allocator, p);

    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len and
        std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) : (common += 1)
    {}

    var out: std.ArrayList(u8) = .empty;
    var up = from_parts.items.len - common;
    while (up > 0) : (up -= 1) try out.appendSlice(allocator, "../");
    for (to_parts.items[common..], 0..) |part, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    if (out.items.len == 0) try out.append(allocator, '.');
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an archive is recognised by its bytes, not by its name" {
    // The four leading-byte forms Composer's dists actually arrive in.
    try testing.expectEqual(Format.zip, detect("PK\x03\x04rest").?);
    try testing.expectEqual(Format.zip, detect("PK\x05\x06").?); // an empty zip
    try testing.expectEqual(Format.tar_gz, detect("\x1f\x8b\x08\x00").?);
    try testing.expectEqual(Format.tar_xz, detect("\xfd7zXZ\x00").?);

    var ustar: [512]u8 = @splat(0);
    @memcpy(ustar[257..262], "ustar");
    try testing.expectEqual(Format.tar, detect(&ustar).?);

    // Nothing recognisable is refused rather than guessed at. A truncated
    // download used to reach `std.zip` and fail with `ExtractFailed`, which
    // reads as "this package is broken" rather than "this is not an archive".
    try testing.expect(detect("<!DOCTYPE html>") == null);
    try testing.expect(detect("") == null);
    try testing.expect(detect("PK") == null);
}

test "a gzipped tar unpacks with its wrapper directory stripped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // `tmpDir` roots itself under the local cache; the sub-path is the only
    // handle on it that the Io.Dir API exposes.
    const base = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    // A tarball shaped like a real one: every entry under a generated wrapper
    // directory that is not part of the package.
    const tarball = try std.fs.path.join(a, &.{ base, "pkg.tar.gz" });
    {
        var raw: std.ArrayList(u8) = .empty;
        {
            var plain: std.Io.Writer.Allocating = .init(a);
            var tw: std.tar.Writer = .{ .underlying_writer = &plain.writer };
            try tw.writeFileBytes("acme-thing-abc123/src/Thing.php", "<?php\n", .{});
            try tw.writeFileBytes("acme-thing-abc123/composer.json", "{\"name\":\"acme/thing\"}", .{});
            try tw.finishPedantically();

            var gz: std.Io.Writer.Allocating = try .initCapacity(a, 64 * 1024);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var comp = try std.compress.flate.Compress.init(&gz.writer, &window, .gzip, .default);
            try comp.writer.writeAll(plain.written());
            try comp.finish();
            try raw.appendSlice(a, gz.written());
        }
        try util.writeFileAtomic(io, tarball, raw.items);
    }

    const dest = try std.fs.path.join(a, &.{ base, "vendor", "acme", "thing" });
    try unpackTo(a, io, tarball, dest);

    // The wrapper is gone and the files sit where the package declares them.
    const manifest_path = try std.fs.path.join(a, &.{ dest, "composer.json" });
    const got = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(4096));
    try testing.expectEqualStrings("{\"name\":\"acme/thing\"}", got);
    try testing.expect(util.fileExists(io, try std.fs.path.join(a, &.{ dest, "src", "Thing.php" })));
}

test "a path repository links out of vendor with a relative target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // What the kernel's own tree contains:
    //   vendor/alfacode-team/http -> ../../modules/http
    const rel = try relativeFrom(a, "/p/vendor/alfacode-team", "/p/modules/http", "/p/vendor");
    try testing.expectEqualStrings("../../modules/http", rel);
}

test "a target inside the same directory needs no climb" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const rel = try relativeFrom(arena.allocator(), "/p/vendor", "/p/vendor/thing", "/p/vendor");
    try testing.expectEqualStrings("thing", rel);
}

test "a deeply nested target keeps every remaining segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const rel = try relativeFrom(arena.allocator(), "/a/b/c/d", "/a/x/y/z", "/a");
    try testing.expectEqualStrings("../../../x/y/z", rel);
}
