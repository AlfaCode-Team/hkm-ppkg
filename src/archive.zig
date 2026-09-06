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

const std = @import("std");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Error = error{
    ExtractFailed,
    EmptyArchive,
};

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
    const staging = try std.fmt.allocPrint(allocator, "{s}.hkm-unpack", .{dest});
    Dir.cwd().deleteTree(io, staging) catch {};
    try Dir.cwd().createDirPath(io, staging);
    errdefer Dir.cwd().deleteTree(io, staging) catch {};

    var root_dir: []const u8 = "";
    {
        var file = Dir.cwd().openFile(io, archive, .{}) catch return Error.ExtractFailed;
        defer file.close(io);

        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buf);

        var staging_dir = Dir.cwd().openDir(io, staging, .{}) catch return Error.ExtractFailed;
        defer staging_dir.close(io);

        var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
        std.zip.extract(staging_dir, &reader, .{ .diagnostics = &diagnostics }) catch return Error.ExtractFailed;
        root_dir = try allocator.dupe(u8, diagnostics.root_dir);
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
