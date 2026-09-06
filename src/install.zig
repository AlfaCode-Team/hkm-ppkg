//! `hkm ppkg install` — build `vendor/` from `composer.lock`.
//!
//! Installing from a lock needs no solver: every version is already chosen and
//! every package carries the URL and immutable reference to fetch. The work is
//! download, unpack, record — and the recording half matters as much as the
//! rest, because `vendor/composer/installed.json` and `installed.php` are what
//! `Composer\InstalledVersions` answers from at runtime.
//!
//! What it does NOT do is resolve. `hkm ppkg require` / `update` — choosing
//! versions against Packagist — is the next piece of work, and until it exists
//! the lock has to come from Composer. That is a real boundary, not a temporary
//! omission to gloss over: this command reproduces a decision, it does not make
//! one.

const std = @import("std");
const lockfile = @import("lock.zig");
const manifest = @import("manifest.zig");
const autoload = @import("autoload.zig");
const fetch = @import("fetch.zig");
const archive = @import("archive.zig");
const runtime = @import("runtime.zig");
const binaries = @import("bin.zig");
const prompt = @import("report.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Options = struct {
    dev: bool = true,
    optimize: bool = false,
    /// Report what would happen and touch nothing.
    dry_run: bool = false,
    /// Reinstall packages already present at the right reference.
    force: bool = false,
    /// Vendor trees to copy Composer's own loader from when the target has
    /// none, in preference order. Empty means: do not provision one.
    runtime_donors: []const []const u8 = &.{},
};

pub const Summary = struct {
    installed: usize = 0,
    linked: usize = 0,
    reused: usize = 0,
    cached: usize = 0,
    downloaded_bytes: usize = 0,
    failed: usize = 0,
    binaries: usize = 0,
    runtime: runtime.Status = .present,
};

/// One package's placement outcome.
const Placement = enum { installed, linked, reused, failed };

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    opts: Options,
) !Summary {
    const vendor_dir = try std.fs.path.join(allocator, &.{ root_dir, "vendor" });

    const lock = try lockfile.read(allocator, io, root_dir);
    const packages = try lock.selected(allocator, opts.dev);

    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);

    var summary: Summary = .{};
    var placed: std.ArrayList(lockfile.Package) = .empty;

    // Warm the cache concurrently before touching the filesystem. Placement
    // below then finds every archive already local and runs at disk speed.
    if (!opts.dry_run) {
        summary.downloaded_bytes = try prefetchAll(allocator, io, env, cache_dir, packages);
    }

    for (packages, 0..) |pkg, index| {
        const dest = try std.fs.path.join(allocator, &.{ vendor_dir, pkg.name });

        // Progress is printed BEFORE the work, not after: the slow step is the
        // download, and a line that appears only once a package is finished
        // leaves the longest package looking like a hang.
        prompt.muted(try std.fmt.allocPrint(
            allocator,
            "  [{d}/{d}] {s} ({s})",
            .{ index + 1, packages.len, pkg.name, pkg.version },
        ));

        switch (place(allocator, io, root_dir, vendor_dir, cache_dir, pkg, dest, opts, &summary)) {
            .installed => summary.installed += 1,
            .linked => summary.linked += 1,
            .reused => summary.reused += 1,
            .failed => {
                summary.failed += 1;
                continue;
            },
        }
        try placed.append(allocator, pkg);
    }

    if (opts.dry_run) return summary;

    // Composer's loader must be in place BEFORE the data files are generated:
    // autoload_static.php takes its class-name suffix from vendor/autoload.php,
    // so generating first would derive a suffix and then have the copied
    // autoload_real.php disagree with it.
    summary.runtime = runtime.ensure(allocator, io, vendor_dir, opts.runtime_donors);

    // Launchers come after placement, so every target script is on disk, and
    // before the autoloader is generated, because a launcher requires it.
    for (placed.items) |pkg| {
        for (pkg.bin) |rel| {
            binaries.install(allocator, io, vendor_dir, pkg.name, rel) catch {
                prompt.warn(std.fmt.allocPrint(
                    allocator,
                    "{s}: could not create vendor/bin/{s}",
                    .{ pkg.name, std.fs.path.basename(rel) },
                ) catch pkg.name);
                continue;
            };
            summary.binaries += 1;
        }
    }

    try writeInstalled(allocator, io, root_dir, vendor_dir, placed.items, opts.dev);

    // The autoloader is regenerated from what was actually placed, using the
    // installed.json this run just wrote — the same path `hkm ppkg autoload`
    // takes, so an install and a later dump produce identical output.
    const root_manifest = (try manifest.read(allocator, io, root_dir)) orelse manifest.Manifest{};
    const installed = try manifest.readInstalled(allocator, io, vendor_dir);
    const plan = try autoload.plan(allocator, io, root_dir, vendor_dir, root_manifest, installed, .{
        .dev = opts.dev,
        .optimize = opts.optimize,
    });
    try autoload.write(allocator, io, vendor_dir, plan);

    return summary;
}

/// Put one package where it belongs.
fn place(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    vendor_dir: []const u8,
    cache_dir: []const u8,
    pkg: lockfile.Package,
    dest: []const u8,
    opts: Options,
    summary: *Summary,
) Placement {
    // A path repository is a link to a directory in this project, not a
    // download — see archive.linkTo for why it must stay a link.
    if (pkg.dist.kind == .path) {
        if (opts.dry_run) return .linked;
        const target = std.fs.path.join(allocator, &.{ root_dir, pkg.dist.url }) catch return .failed;
        archive.linkTo(allocator, io, dest, target, vendor_dir) catch return .failed;
        return .linked;
    }

    if (pkg.dist.kind != .zip) {
        // A lock entry with no usable dist would need the SOURCE (a git clone) —
        // which this command deliberately does not do, because cloning is the
        // slow path the native installer exists to avoid.
        prompt.warn(std.fmt.allocPrint(
            allocator,
            "{s}: no zip distribution in the lock — install it with composer",
            .{pkg.name},
        ) catch pkg.name);
        return .failed;
    }

    if (!opts.force and alreadyInstalled(allocator, io, dest, pkg)) return .reused;
    if (opts.dry_run) return .installed;

    const key = if (pkg.dist.reference.len > 0) pkg.dist.reference else pkg.version;
    const got = fetch.intoCache(allocator, io, cache_dir, pkg.dist.url, key, pkg.dist.shasum) catch {
        prompt.warn(std.fmt.allocPrint(allocator, "{s}: download failed", .{pkg.name}) catch pkg.name);
        return .failed;
    };
    if (got.cached) summary.cached += 1;

    archive.unpackTo(allocator, io, got.path, dest) catch {
        prompt.warn(std.fmt.allocPrint(allocator, "{s}: could not be unpacked", .{pkg.name}) catch pkg.name);
        return .failed;
    };
    return .installed;
}

/// Download every archive this install still needs, in parallel.
///
/// Returns the number of bytes actually transferred. Packages already unpacked
/// at the locked reference are excluded, so a re-run of a current tree makes no
/// requests at all.
fn prefetchAll(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    packages: []const lockfile.Package,
) !usize {
    var wants: std.ArrayList(fetch.Want) = .empty;
    for (packages) |pkg| {
        if (pkg.dist.kind != .zip) continue;
        if (pkg.dist.url.len == 0) continue;
        try wants.append(allocator, .{
            .url = pkg.dist.url,
            .key = if (pkg.dist.reference.len > 0) pkg.dist.reference else pkg.version,
            .sha1 = pkg.dist.shasum,
        });
    }
    if (wants.items.len == 0) return 0;

    return fetch.prefetch(allocator, io, cache_dir, wants.items, fetch.workerCount(env), reportFetch);
}

/// Progress from a worker thread.
///
/// Deliberately terse and count-only: several threads call this at once, and a
/// line naming the package would interleave with the others mid-word.
fn reportFetch(done: usize, total: usize, url: []const u8) void {
    _ = url;
    if (done == total or done % 10 == 0) {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  fetched {d}/{d}", .{ done, total }) catch return;
        prompt.muted(line);
    }
}

/// Is the right version already in place?
///
/// Judged on the reference recorded in the PREVIOUS install, not on the
/// directory merely existing: a package left over from a different lock is
/// present and wrong, which is the case a bare `dirExists` check gets backwards.
fn alreadyInstalled(allocator: std.mem.Allocator, io: Io, dest: []const u8, pkg: lockfile.Package) bool {
    if (!util.dirExists(Dir.cwd(), io, dest)) return false;
    if (pkg.dist.reference.len == 0) return false;

    const stamp = std.fs.path.join(allocator, &.{ dest, ".ppkg-ref" }) catch return false;
    const recorded = Dir.cwd().readFileAlloc(io, stamp, allocator, .limited(256)) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, recorded, " \n\r\t"), pkg.dist.reference);
}

/// May a directory holding this kind of dist be stamped?
///
/// Only a downloaded one. See the call site for why writing through a path
/// repository's symlink is the bug this exists to prevent.
fn stampable(kind: lockfile.DistType) bool {
    return kind != .path;
}

/// Record which reference a directory holds, so the next run can skip it.
fn stampReference(allocator: std.mem.Allocator, io: Io, dest: []const u8, reference: []const u8) void {
    if (reference.len == 0) return;
    const stamp = std.fs.path.join(allocator, &.{ dest, ".ppkg-ref" }) catch return;
    util.writeFileAtomic(io, stamp, reference) catch {};
}

// ── installed metadata ────────────────────────────────────────────────────────

/// Write `vendor/composer/installed.json` and `installed.php`.
fn writeInstalled(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    vendor_dir: []const u8,
    packages: []const lockfile.Package,
    dev: bool,
) !void {
    const composer_dir = try std.fs.path.join(allocator, &.{ vendor_dir, "composer" });
    try Dir.cwd().createDirPath(io, composer_dir);

    for (packages) |pkg| {
        // Never stamp a path repository. Its `dest` is a SYMLINK to a directory
        // inside the user's own project, so a write there does not land in
        // vendor/ at all — it lands in their source tree, as an untracked file
        // in a checkout they did not ask this tool to touch. Nothing is lost by
        // skipping it: a link has no reference to go stale, and `alreadyInstalled`
        // is never consulted for one.
        if (!stampable(pkg.dist.kind)) continue;
        const dest = try std.fs.path.join(allocator, &.{ vendor_dir, pkg.name });
        stampReference(allocator, io, dest, pkg.dist.reference);
    }

    try util.writeFileAtomic(
        io,
        try std.fs.path.join(allocator, &.{ composer_dir, "installed.json" }),
        try renderInstalledJson(allocator, packages, dev),
    );
    try util.writeFileAtomic(
        io,
        try std.fs.path.join(allocator, &.{ composer_dir, "installed.php" }),
        try renderInstalledPhp(allocator, io, root_dir, packages, dev),
    );
}

/// `installed.json` is the lock's package objects with three keys added.
///
/// Re-emitted from the ORIGINAL json value rather than from a struct, so every
/// field this tool does not model — authors, funding, support, extra — survives
/// into the installed metadata instead of being quietly dropped.
fn renderInstalledJson(
    allocator: std.mem.Allocator,
    packages: []const lockfile.Package,
    dev: bool,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\n    \"packages\": [\n");

    for (packages, 0..) |pkg, i| {
        const extra = [_]Extra{
            .{ .key = "version_normalized", .value = try lockfile.normalizeVersion(allocator, pkg.version) },
            .{ .key = "install-path", .value = try installPathFor(allocator, pkg) },
            .{ .key = "installation-source", .value = "dist" },
        };
        try writeObject(allocator, &out, pkg.raw, &extra, 2);
        if (i + 1 < packages.len) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n");
    }

    try out.appendSlice(allocator, "    ],\n");
    try out.print(allocator, "    \"dev\": {s},\n", .{if (dev) "true" else "false"});
    try out.appendSlice(allocator, "    \"dev-package-names\": [\n");

    var first = true;
    for (packages) |pkg| {
        if (!pkg.dev) continue;
        if (!first) try out.appendSlice(allocator, ",\n");
        first = false;
        try out.appendSlice(allocator, "        ");
        try writeJsonString(allocator, &out, pkg.name);
    }
    try out.appendSlice(allocator, "\n    ]\n}\n");
    return out.toOwnedSlice(allocator);
}

/// Where a package sits relative to `vendor/composer/`, the way Composer spells
/// it: `../guzzlehttp/guzzle`.
///
/// A PATH repository is no exception, which is easy to get wrong: it is
/// installed as a SYMLINK at `vendor/<name>`, and Composer records the link —
/// not the directory it points at. Recording the real location instead
/// (`../../modules/php-io-cli`) makes every generated autoload path for that
/// package resolve from inside `vendor/`, and its `files` bootstraps then fail
/// to open on the very first require.
fn installPathFor(allocator: std.mem.Allocator, pkg: lockfile.Package) ![]const u8 {
    return std.fmt.allocPrint(allocator, "../{s}", .{pkg.name});
}

const Extra = struct { key: []const u8, value: []const u8 };

/// Emit a json object, appending `extra` string keys that are not already in it.
fn writeObject(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
    extra: []const Extra,
    depth: usize,
) !void {
    if (value != .object) return writeValue(allocator, out, value, depth);

    try indent(allocator, out, depth);
    try out.appendSlice(allocator, "{\n");

    var it = value.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out.appendSlice(allocator, ",\n");
        first = false;
        try indent(allocator, out, depth + 1);
        try writeJsonString(allocator, out, entry.key_ptr.*);
        try out.appendSlice(allocator, ": ");
        try writeValueInline(allocator, out, entry.value_ptr.*, depth + 1);
    }

    for (extra) |e| {
        if (value.object.get(e.key) != null) continue;
        if (!first) try out.appendSlice(allocator, ",\n");
        first = false;
        try indent(allocator, out, depth + 1);
        try writeJsonString(allocator, out, e.key);
        try out.appendSlice(allocator, ": ");
        try writeJsonString(allocator, out, e.value);
    }

    try out.appendSlice(allocator, "\n");
    try indent(allocator, out, depth);
    try out.appendSlice(allocator, "}");
}

fn writeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value, depth: usize) !void {
    try indent(allocator, out, depth);
    try writeValueInline(allocator, out, value, depth);
}

fn writeValueInline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
    depth: usize,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try writeJsonString(allocator, out, s),
        .array => |a| {
            if (a.items.len == 0) return out.appendSlice(allocator, "[]");
            try out.appendSlice(allocator, "[\n");
            for (a.items, 0..) |item, i| {
                try indent(allocator, out, depth + 1);
                try writeValueInline(allocator, out, item, depth + 1);
                if (i + 1 < a.items.len) try out.appendSlice(allocator, ",");
                try out.appendSlice(allocator, "\n");
            }
            try indent(allocator, out, depth);
            try out.appendSlice(allocator, "]");
        },
        .object => |o| {
            if (o.count() == 0) return out.appendSlice(allocator, "{}");
            try out.appendSlice(allocator, "{\n");
            var it = o.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ",\n");
                first = false;
                try indent(allocator, out, depth + 1);
                try writeJsonString(allocator, out, entry.key_ptr.*);
                try out.appendSlice(allocator, ": ");
                try writeValueInline(allocator, out, entry.value_ptr.*, depth + 1);
            }
            try out.appendSlice(allocator, "\n");
            try indent(allocator, out, depth);
            try out.appendSlice(allocator, "}");
        },
    }
}

fn indent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "    ");
}

fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => {
            if (c < 0x20) {
                try out.print(allocator, "\\u{x:0>4}", .{c});
            } else {
                try out.append(allocator, c);
            }
        },
    };
    try out.append(allocator, '"');
}

/// `installed.php` — the array `Composer\InstalledVersions` reads.
fn renderInstalledPhp(
    allocator: std.mem.Allocator,
    io: Io,
    root_dir: []const u8,
    packages: []const lockfile.Package,
    dev: bool,
) ![]const u8 {
    const root = try rootPackageInfo(allocator, io, root_dir);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "<?php return array(\n    'root' => array(\n");
    try phpPair(allocator, &out, 2, "name", root.name);
    try phpPair(allocator, &out, 2, "pretty_version", root.pretty_version);
    try phpPair(allocator, &out, 2, "version", root.version);
    try phpPair(allocator, &out, 2, "reference", root.reference);
    try phpPair(allocator, &out, 2, "type", root.kind);
    try out.appendSlice(allocator, "        'install_path' => __DIR__ . '/../../',\n");
    try out.appendSlice(allocator, "        'aliases' => array(),\n");
    try out.print(allocator, "        'dev' => {s},\n", .{if (dev) "true" else "false"});
    try out.appendSlice(allocator, "    ),\n    'versions' => array(\n");

    for (packages) |pkg| {
        try out.appendSlice(allocator, "        ");
        try phpString(allocator, &out, pkg.name);
        try out.appendSlice(allocator, " => array(\n");
        try phpPair(allocator, &out, 3, "pretty_version", pkg.version);
        try phpPair(allocator, &out, 3, "version", try lockfile.normalizeVersion(allocator, pkg.version));
        try phpPair(allocator, &out, 3, "reference", pkg.dist.reference);
        try phpPair(allocator, &out, 3, "type", pkg.kind);
        try out.appendSlice(allocator, "            'install_path' => __DIR__ . '/");
        try out.appendSlice(allocator, try installPathFor(allocator, pkg));
        try out.appendSlice(allocator, "',\n");
        try writeAliases(allocator, &out, pkg);
        try out.print(allocator, "            'dev_requirement' => {s},\n", .{if (pkg.dev) "true" else "false"});
        try out.appendSlice(allocator, "        ),\n");
    }

    try out.appendSlice(allocator, "    ),\n);\n");
    return out.toOwnedSlice(allocator);
}

/// A dev branch that `extra.branch-alias` maps to a version gets that alias
/// recorded, so `InstalledVersions::satisfies('^1.0')` is true for `dev-master`
/// when the package says the branch IS 1.0.
fn writeAliases(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pkg: lockfile.Package) !void {
    const alias = branchAlias(pkg) orelse {
        try out.appendSlice(allocator, "            'aliases' => array(),\n");
        return;
    };
    try out.appendSlice(allocator, "            'aliases' => array(\n                0 => ");
    try phpString(allocator, out, alias);
    try out.appendSlice(allocator, ",\n            ),\n");
}

fn branchAlias(pkg: lockfile.Package) ?[]const u8 {
    if (pkg.raw != .object) return null;
    const extra = pkg.raw.object.get("extra") orelse return null;
    if (extra != .object) return null;
    const aliases = extra.object.get("branch-alias") orelse return null;
    if (aliases != .object) return null;
    const hit = aliases.object.get(pkg.version) orelse return null;
    return switch (hit) {
        .string => |s| s,
        else => null,
    };
}

const RootInfo = struct {
    name: []const u8 = "__root__",
    pretty_version: []const u8 = "dev-main",
    version: []const u8 = "dev-main",
    reference: []const u8 = "",
    kind: []const u8 = "library",
};

/// Describe the root package.
///
/// The branch and commit come from `.git`, read directly rather than by running
/// git: this is called during an install that is otherwise entirely offline and
/// process-free, and a missing `.git` is normal in a deployed tree.
fn rootPackageInfo(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !RootInfo {
    var info: RootInfo = .{};

    if (try manifest.read(allocator, io, root_dir)) |m| {
        if (m.name.len > 0) info.name = m.name;
        if (m.kind.len > 0) info.kind = m.kind;
    }

    const head_path = try std.fs.path.join(allocator, &.{ root_dir, ".git", "HEAD" });
    const head = Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096)) catch return info;
    const trimmed = std.mem.trim(u8, head, " \n\r\t");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref = trimmed[5..];
        const branch = std.fs.path.basename(ref);
        info.pretty_version = try std.fmt.allocPrint(allocator, "dev-{s}", .{branch});
        info.version = info.pretty_version;

        const ref_path = try std.fs.path.join(allocator, &.{ root_dir, ".git", ref });
        if (Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(256)) catch null) |sha| {
            info.reference = try allocator.dupe(u8, std.mem.trim(u8, sha, " \n\r\t"));
        }
    } else {
        // Detached HEAD: the file holds the commit itself.
        info.reference = try allocator.dupe(u8, trimmed);
    }

    return info;
}

fn phpPair(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, key: []const u8, value: []const u8) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "    ");
    try phpString(allocator, out, key);
    try out.appendSlice(allocator, " => ");
    try phpString(allocator, out, value);
    try out.appendSlice(allocator, ",\n");
}

fn phpString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\\' or c == '\'') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseValue(a: std.mem.Allocator, src: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
}

test "install paths are spelled relative to vendor/composer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zip = lockfile.Package{
        .name = "guzzlehttp/guzzle",
        .version = "7.9.2",
        .dist = .{ .kind = .zip },
        .raw = .null,
    };
    try testing.expectEqualStrings("../guzzlehttp/guzzle", try installPathFor(a, zip));

    // A path repository is recorded at its SYMLINK inside vendor/, not at the
    // directory the link points to — matching what Composer writes, and what the
    // generated autoload paths must agree with.
    const path_pkg = lockfile.Package{
        .name = "alfacode-team/http",
        .version = "dev-master",
        .dist = .{ .kind = .path, .url = "modules/http" },
        .raw = .null,
    };
    try testing.expectEqualStrings("../alfacode-team/http", try installPathFor(a, path_pkg));
}

test "installed.json keeps fields the tool does not model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = try parseValue(a,
        \\{"name":"acme/lib","version":"1.2.3","funding":[{"type":"github","url":"https://x"}],
        \\ "authors":[{"name":"Someone"}]}
    );
    const pkgs = [_]lockfile.Package{.{
        .name = "acme/lib",
        .version = "1.2.3",
        .dist = .{ .kind = .zip },
        .raw = raw,
    }};

    const json = try renderInstalledJson(a, &pkgs, true);

    // Untouched passthrough of what the lock said.
    try testing.expect(std.mem.indexOf(u8, json, "\"funding\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Someone\"") != null);
    // Added by the installer.
    try testing.expect(std.mem.indexOf(u8, json, "\"version_normalized\": \"1.2.3.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"install-path\": \"../acme/lib\"") != null);

    // And it must still be valid JSON.
    _ = try parseValue(a, json);
}

test "dev packages are listed in dev-package-names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pkgs = [_]lockfile.Package{
        .{ .name = "acme/runtime", .version = "1.0.0", .dist = .{ .kind = .zip }, .raw = .null },
        .{ .name = "acme/tests", .version = "2.0.0", .dev = true, .dist = .{ .kind = .zip }, .raw = .null },
    };
    const json = try renderInstalledJson(a, &pkgs, true);
    const at = std.mem.indexOf(u8, json, "dev-package-names").?;
    const tail = json[at..];

    try testing.expect(std.mem.indexOf(u8, tail, "\"acme/tests\"") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "\"acme/runtime\"") == null);
    _ = try parseValue(a, json);
}

test "a branch alias is recorded so version constraints can match a dev branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = try parseValue(a,
        \\{"name":"acme/lib","extra":{"branch-alias":{"dev-master":"1.0.x-dev"}}}
    );
    const pkg = lockfile.Package{ .name = "acme/lib", .version = "dev-master", .raw = raw };
    try testing.expectEqualStrings("1.0.x-dev", branchAlias(pkg).?);

    var out: std.ArrayList(u8) = .empty;
    try writeAliases(a, &out, pkg);
    try testing.expect(std.mem.indexOf(u8, out.items, "0 => '1.0.x-dev'") != null);
}

test "a package with no branch alias gets an empty alias array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const pkg = lockfile.Package{ .name = "acme/lib", .version = "1.0.0", .raw = .null };
    try testing.expect(branchAlias(pkg) == null);

    var out: std.ArrayList(u8) = .empty;
    try writeAliases(arena.allocator(), &out, pkg);
    try testing.expectEqualStrings("            'aliases' => array(),\n", out.items);
}

test "php string literals escape quotes and backslashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList(u8) = .empty;
    try phpString(arena.allocator(), &out, "it's\\fine");
    try testing.expectEqualStrings("'it\\'s\\\\fine'", out.items);
}

test "a path repository is never stamped" {
    // `vendor/<name>` for a path repo is a SYMLINK into the user's own project.
    // Stamping it writes .ppkg-ref into their source checkout — which is exactly
    // what happened to a git submodule before this guard existed, leaving an
    // untracked file in a repository this tool has no business writing to.
    try testing.expect(!stampable(.path));

    // Everything that was actually downloaded still gets one, or every install
    // re-extracts every package.
    try testing.expect(stampable(.zip));
    try testing.expect(stampable(.tar));
    try testing.expect(stampable(.none));
}
