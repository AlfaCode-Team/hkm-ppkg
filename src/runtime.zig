//! Composer's own runtime files, and how a native install obtains them.
//!
//! Five files in a vendor tree are neither package code nor generated data —
//! they are Composer's loader itself:
//!
//!     vendor/autoload.php                 the entry point everything requires
//!     vendor/composer/autoload_real.php   wires the loader to the data files
//!     vendor/composer/ClassLoader.php     the PSR-0/4 loader (579 lines)
//!     vendor/composer/InstalledVersions.php  the runtime package registry
//!     vendor/composer/platform_check.php  php version / extension guard
//!
//! They are COPIED from a donor vendor tree, not generated and not vendored into
//! this repository. Two reasons, and the second is the one that decides it:
//!
//!  1. `ClassLoader` and `InstalledVersions` are Composer's MIT-licensed source.
//!     Embedding them here would mean carrying someone else's code, and its
//!     licence, inside the kernel's tooling — a deliberate decision for a
//!     maintainer to take, not one for a build tool to take on their behalf.
//!  2. The three generated files agree with each other through the autoloader
//!     SUFFIX baked into their class names. Copying the set verbatim keeps that
//!     agreement by construction; re-authoring any one of them invites the
//!     mismatch that leaves `autoload_real.php` calling a class nothing defines.
//!
//! When no donor exists, that is reported plainly rather than papered over: a
//! vendor/ without these files has no entry point, and saying so beats producing
//! a tree that fails at the first `require`.

const std = @import("std");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Paths relative to a vendor directory.
pub const files = [_][]const u8{
    "autoload.php",
    "composer/autoload_real.php",
    "composer/ClassLoader.php",
    "composer/InstalledVersions.php",
    "composer/platform_check.php",
    "composer/LICENSE",
};

/// `platform_check.php` is optional — Composer omits it when the check is
/// disabled — so its absence in a donor must not fail the copy.
fn optional(rel: []const u8) bool {
    return std.mem.eql(u8, rel, "composer/platform_check.php") or
        std.mem.eql(u8, rel, "composer/LICENSE");
}

pub const Status = enum {
    /// Already present in the target tree.
    present,
    /// Copied in from a donor.
    provisioned,
    /// No donor available; the tree has no entry point.
    missing,
};

/// Ensure `vendor_dir` has a usable loader.
///
/// `donors` are vendor directories to copy from, in preference order. The host
/// supplies them because only the host knows which trees it is entitled to read
/// — this package will not go looking around a machine for one.
pub fn ensure(
    allocator: std.mem.Allocator,
    io: Io,
    vendor_dir: []const u8,
    donors: []const []const u8,
) Status {
    if (hasAll(allocator, io, vendor_dir)) return .present;

    const donor = findDonor(allocator, io, vendor_dir, donors) orelse return .missing;

    for (files) |rel| {
        const from = std.fs.path.join(allocator, &.{ donor, rel }) catch continue;
        const to = std.fs.path.join(allocator, &.{ vendor_dir, rel }) catch continue;

        const body = Dir.cwd().readFileAlloc(io, from, allocator, .limited(4 * 1024 * 1024)) catch {
            if (optional(rel)) continue;
            return .missing;
        };
        if (util.parentOf(to)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
        util.writeFileAtomic(io, to, body) catch return .missing;
    }

    return if (hasAll(allocator, io, vendor_dir)) .provisioned else .missing;
}

/// Does this vendor directory have every required runtime file?
pub fn hasAll(allocator: std.mem.Allocator, io: Io, vendor_dir: []const u8) bool {
    for (files) |rel| {
        if (optional(rel)) continue;
        const path = std.fs.path.join(allocator, &.{ vendor_dir, rel }) catch return false;
        if (!util.fileExists(io, path)) return false;
    }
    return true;
}

/// The first offered vendor tree that actually has the loader in it.
///
/// The tree being installed into is skipped even if a caller offers it: copying
/// a directory onto itself is how a half-written file becomes the only copy.
fn findDonor(
    allocator: std.mem.Allocator,
    io: Io,
    exclude_vendor: []const u8,
    donors: []const []const u8,
) ?[]const u8 {
    for (donors) |candidate| {
        const abs = std.fs.path.resolve(allocator, &.{candidate}) catch candidate;
        if (std.mem.eql(u8, abs, exclude_vendor) or std.mem.eql(u8, candidate, exclude_vendor)) continue;
        if (hasAll(allocator, io, candidate)) return candidate;
    }
    return null;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the loader and the registry are required, the licence and guard are not" {
    // Getting this backwards would either reject a perfectly good donor (if the
    // optional files were required) or accept a tree with no loader at all.
    try testing.expect(!optional("autoload.php"));
    try testing.expect(!optional("composer/autoload_real.php"));
    try testing.expect(!optional("composer/ClassLoader.php"));
    try testing.expect(!optional("composer/InstalledVersions.php"));

    try testing.expect(optional("composer/platform_check.php"));
    try testing.expect(optional("composer/LICENSE"));
}

test "every required file is listed exactly once" {
    for (files, 0..) |a, i| {
        for (files[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
    try testing.expectEqual(@as(usize, 6), files.len);
}
