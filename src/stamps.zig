//! Which reference each installed package directory is holding.
//!
//! `install` skips a package whose directory already holds the locked
//! reference. Answering that needs a record of what was put there, because the
//! directory itself does not say: a tree from a different lock is present and
//! wrong, which is exactly the case a `dirExists` check gets backwards.
//!
//! ## Why this is not a file inside the package
//!
//! It used to be — a `.ppkg-ref` in every installed package directory. That
//! worked and cost one divergence per package: a vendor tree with a file in it
//! that Composer never writes. It shows up in `git status` for anyone who
//! commits their vendor directory, in a `diff -r` against a Composer-built
//! tree, in an `archive`, and in any deployment that verifies the tree by
//! checksum. A package manager whose claim is byte-identical output does not
//! get to leave a marker in every package.
//!
//! So the record lives in the CACHE instead, one file per vendor directory,
//! and the vendor tree is left exactly as Composer would have written it. The
//! trade is that clearing the cache loses the record — and the failure mode of
//! that is one slow install, which re-extracts archives that were already
//! correct. That is the right direction to fail in.

const std = @import("std");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// One package's recorded state.
pub const Stamp = struct {
    name: []const u8,
    reference: []const u8,
};

pub const Table = struct {
    entries: []const Stamp = &.{},

    pub const empty: Table = .{};

    pub fn get(self: Table, name: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.reference;
        }
        return null;
    }

    /// Does this package's directory hold `reference`?
    pub fn holds(self: Table, name: []const u8, reference: []const u8) bool {
        if (reference.len == 0) return false;
        const recorded = self.get(name) orelse return false;
        return std.mem.eql(u8, recorded, reference);
    }
};

/// Where the record for `vendor_dir` lives.
///
/// Keyed by a hash of the ABSOLUTE vendor path, so two checkouts of the same
/// project — a worktree and its origin, two branches built side by side — do
/// not share one record and conclude that the other's packages are in place.
pub fn pathFor(allocator: std.mem.Allocator, cache_dir: []const u8, vendor_dir: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(vendor_dir);
    h.final(&digest);

    const name = try std.fmt.allocPrint(allocator, "{x}.json", .{digest[0..8]});
    return std.fs.path.join(allocator, &.{ cache_dir, "refs", name });
}

/// Read the record. A missing or unreadable one is an EMPTY table, never an
/// error: not knowing what is installed means installing it, which is correct
/// and merely slower.
pub fn read(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    vendor_dir: []const u8,
) Table {
    const path = pathFor(allocator, cache_dir, vendor_dir) catch return .empty;
    const body = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch return .empty;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return .empty;
    if (parsed != .object) return .empty;

    var out: std.ArrayList(Stamp) = .empty;
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        out.append(allocator, .{ .name = e.key_ptr.*, .reference = e.value_ptr.string }) catch return .empty;
    }
    return .{ .entries = out.items };
}

/// Write the record. Best-effort: a cache that cannot be written costs one
/// slow install and nothing else, so it must never fail a run that succeeded.
pub fn write(
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    vendor_dir: []const u8,
    stamps: []const Stamp,
) void {
    const path = pathFor(allocator, cache_dir, vendor_dir) catch return;
    if (util.parentOf(path)) |parent| Dir.cwd().createDirPath(io, parent) catch return;

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(allocator, "{\n") catch return;
    for (stamps, 0..) |s, i| {
        if (i > 0) out.appendSlice(allocator, ",\n") catch return;
        out.print(allocator, "    {f}: {f}", .{
            std.json.fmt(s.name, .{}),
            std.json.fmt(s.reference, .{}),
        }) catch return;
    }
    out.appendSlice(allocator, "\n}\n") catch return;

    util.writeFileAtomic(io, path, out.items) catch {};
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a table answers only for the reference it recorded" {
    const table: Table = .{ .entries = &.{
        .{ .name = "acme/one", .reference = "abc123" },
        .{ .name = "acme/two", .reference = "def456" },
    } };

    try testing.expect(table.holds("acme/one", "abc123"));
    // A directory left over from a different lock: present, and wrong.
    try testing.expect(!table.holds("acme/one", "zzz999"));
    try testing.expect(!table.holds("acme/three", "abc123"));
    // No reference to compare against is not a match — an install with nothing
    // to verify must do the work rather than assume it was already done.
    try testing.expect(!table.holds("acme/one", ""));
}

test "two vendor directories never share a record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try pathFor(a, "/cache", "/projects/app/vendor");
    const two = try pathFor(a, "/cache", "/projects/app-worktree/vendor");

    try testing.expect(!std.mem.eql(u8, one, two));
    // Same path, same answer — the record has to be findable again.
    try testing.expectEqualStrings(one, try pathFor(a, "/cache", "/projects/app/vendor"));
}

test "an unreadable record reads as empty rather than failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded: std.Io.Threaded = .init(arena.allocator(), .{});
    defer threaded.deinit();

    const table = read(arena.allocator(), threaded.io(), "/nonexistent-cache", "/nowhere/vendor");
    try testing.expectEqual(@as(usize, 0), table.entries.len);
}
