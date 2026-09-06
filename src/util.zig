//! The small filesystem and string helpers this package needs.
//!
//! Deliberately narrow. Everything here is a pure function over `std`, with no
//! knowledge of packages, so it is the one file a reader can skip. It exists
//! rather than being pulled from a host application's utility module because
//! that would make this repository unusable on its own — the point of it being
//! a repository.

const std = @import("std");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

// ── writing ───────────────────────────────────────────────────────────────────

/// Write a file by staging and renaming, so a reader sees either the previous
/// file or the new one and never a half-written one.
///
/// Every generated artefact goes through here. A truncated `autoload_static.php`
/// is not a file with a mistake in it — it is a parse error at the top of every
/// request the application serves, and the process that wrote it has already
/// exited by the time anyone sees that.
pub fn writeFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    // The temp name carries the pid, so two processes writing the same target
    // cannot land on one another's staging file — one would otherwise rename a
    // half-written copy over the target the other was still filling.
    const pid: u32 = switch (@import("builtin").os.tag) {
        .windows => 0,
        .linux => @bitCast(std.os.linux.getpid()),
        else => @bitCast(std.c.getpid()),
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "{s}.pkg-tmp.{d}", .{ path, pid }) catch {
        // No room for the suffix — a direct write still beats not writing.
        return Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    };

    try Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    Dir.cwd().rename(tmp, Dir.cwd(), path, io) catch |e| {
        Dir.cwd().deleteFile(io, tmp) catch {};
        return e;
    };
}

/// Make a path executable (0755). Best-effort, and a no-op on Windows: a
/// `vendor/bin` proxy that could not be chmod'd is worth reporting at the point
/// it fails to run, not worth failing an otherwise complete install.
pub fn chmodExec(io: Io, path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const f = Dir.cwd().openFile(io, path, .{}) catch return;
    defer f.close(io);
    f.setPermissions(io, @enumFromInt(0o755)) catch {};
}

// ── paths ─────────────────────────────────────────────────────────────────────

/// Drop trailing separators, keeping a bare root intact.
pub fn trimSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 1 and (p[p.len - 1] == '/' or p[p.len - 1] == '\\')) p = p[0 .. p.len - 1];
    return p;
}

/// Drop leading "./" segments so joined absolute paths stay clean.
pub fn stripDotSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len >= 2 and p[0] == '.' and (p[1] == '/' or p[1] == '\\')) p = p[2..];
    return p;
}

/// Parent directory of a path (null when there is no separator).
pub fn parentOf(path: ?[]const u8) ?[]const u8 {
    const p = path orelse return null;
    const t = trimSlash(p);
    const idx = std.mem.lastIndexOfScalar(u8, t, '/') orelse return null;
    if (idx == 0) return "/";
    return t[0..idx];
}

/// Absolutise a path against `PWD`.
///
/// `PWD` rather than the process cwd because the paths this resolves are the
/// ones a user typed at a shell prompt, and a shell that followed a symlink
/// into the tree reports the path the user walked, not the one `getcwd`
/// resolves it to. An install writing the resolved form records a
/// `install-path` the user cannot recognise in their own `installed.json`.
pub fn absPath(allocator: std.mem.Allocator, env: *EnvMap, raw: []const u8) ![]const u8 {
    const path = stripDotSlash(raw);
    if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) return path;
    const pwd = env.get("PWD") orelse return path;
    if (pwd.len == 0) return path;
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return pwd;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pwd, path });
}

// ── probes ────────────────────────────────────────────────────────────────────

/// True if `path` is accessible (relative to the process cwd).
pub fn fileExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True if `path` opens as a directory under `dir`.
pub fn dirExists(dir: Dir, io: Io, path: []const u8) bool {
    var d = dir.openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// ── lists ─────────────────────────────────────────────────────────────────────

/// Join a string list with ", " for display.
pub fn joinList(allocator: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, it);
    }
    return out.toOwnedSlice(allocator);
}

/// Is `needle` one of `haystack`?
pub fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "trimSlash keeps a bare root but drops trailing separators" {
    try testing.expectEqualStrings("/a/b", trimSlash("/a/b/"));
    try testing.expectEqualStrings("/a/b", trimSlash("/a/b///"));
    try testing.expectEqualStrings("/", trimSlash("/"));
    try testing.expectEqualStrings("", trimSlash(""));
}

test "parentOf stops at the root rather than returning an empty path" {
    try testing.expectEqualStrings("/a", parentOf("/a/b").?);
    try testing.expectEqualStrings("/", parentOf("/a").?);
    try testing.expect(parentOf("relative") == null);
    try testing.expect(parentOf(null) == null);
}

test "stripDotSlash removes every leading ./" {
    try testing.expectEqualStrings("a/b", stripDotSlash("./a/b"));
    try testing.expectEqualStrings("a/b", stripDotSlash("././a/b"));
    try testing.expectEqualStrings("/a", stripDotSlash("/a"));
}

test "joinList renders an empty list as an empty string" {
    const a = testing.allocator;
    const empty = try joinList(a, &.{});
    defer a.free(empty);
    try testing.expectEqualStrings("", empty);

    const three = try joinList(a, &.{ "x", "y", "z" });
    defer a.free(three);
    try testing.expectEqualStrings("x, y, z", three);
}
