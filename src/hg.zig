//! Mercurial repositories.
//!
//! The same shape as `git.zig` — a local clone in the cache, then every
//! question answered off the disk — because Mercurial has no static host that
//! serves a file at a revision and no equivalent of `git ls-remote`. `hg` is
//! the only interface there is, so the mirror is not an optimisation here, it
//! is the mechanism.
//!
//! `hg clone --noupdate` is Composer's own command for this: a repository with
//! no working directory, which is what `hg cat -r` and `hg archive -r` need and
//! nothing more.
//!
//! ## The two lists, and why both
//!
//! Composer merges `hg branches` with `hg bookmarks`, bookmarks first so a
//! branch of the same name wins. Both are movable named revisions; a project
//! that uses bookmarks as its branch model — which is common on Bitbucket-era
//! repositories — has an empty `hg branches` beyond `default`, and reading only
//! one of the two lists makes every version of such a package disappear with no
//! error at all.

const std = @import("std");
const git = @import("git.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    HgFailed,
    NoMirror,
};

/// Is `hg` on this machine?
pub fn available(allocator: std.mem.Allocator, io: Io, env: *EnvMap) bool {
    const out = run(allocator, io, env, &.{ "hg", "--version" }) catch return false;
    return std.mem.indexOf(u8, out, "Mercurial") != null;
}

/// Run `hg`, prompt-free, and return stdout.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    argv: []const []const u8,
) ![]const u8 {
    // The same reasoning as `git.run`: a credential prompt inside a worker
    // thread looks exactly like a hang, so it must fail instead.
    return git.runTool(allocator, io, env, argv) catch Error.HgFailed;
}

/// Where a repository's clone lives — hashed from the URL, like git's.
pub fn mirrorPath(allocator: std.mem.Allocator, cache_dir: []const u8, url: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const name = try std.fmt.allocPrint(allocator, "{x}", .{digest[0..10]});
    return std.fs.path.join(allocator, &.{ cache_dir, "hg", name });
}

/// A clone of `url`, made or pulled as needed.
pub fn mirror(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    url: []const u8,
) ![]const u8 {
    const path = try mirrorPath(allocator, cache_dir, url);
    const marker = try std.fs.path.join(allocator, &.{ path, ".hg", "requires" });

    if (util.fileExists(io, marker)) {
        if (!git.refresh and git.fresh(io, marker)) return path;
        // A pull failure with a usable clone already here is not fatal: an
        // offline machine should resolve from what it has.
        _ = run(allocator, io, env, &.{ "hg", "--cwd", path, "pull" }) catch return path;
        git.touch(io, marker);
        return path;
    }

    if (util.parentOf(path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
    Dir.cwd().deleteTree(io, path) catch {};

    _ = run(allocator, io, env, &.{ "hg", "clone", "--noupdate", "--", url, path }) catch
        return Error.HgFailed;

    if (!util.fileExists(io, marker)) return Error.NoMirror;
    return path;
}

pub const Ref = struct {
    name: []const u8,
    /// The changeset node — an immutable 40-hex identity, like a git sha.
    node: []const u8,
    kind: enum { tag, branch },
};

/// Every tag, branch and bookmark.
pub fn refs(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
) ![]const Ref {
    var out: std.ArrayList(Ref) = .empty;

    if (run(allocator, io, env, &.{ "hg", "--cwd", mirror_dir, "tags" }) catch null) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const parsed = parseLine(line) orelse continue;
            // `tip` is not a release, it is "whatever is newest"; Composer
            // removes it and so does this, or every repository would publish a
            // moving version under a fixed name.
            if (std.mem.eql(u8, parsed.name, "tip")) continue;
            try out.append(allocator, .{ .name = parsed.name, .node = parsed.node, .kind = .tag });
        }
    }

    // Bookmarks first, branches after: a branch of the same name wins, which is
    // the order `array_merge($bookmarks, $branches)` produces.
    for ([_][]const u8{ "bookmarks", "branches" }) |which| {
        const text = run(allocator, io, env, &.{ "hg", "--cwd", mirror_dir, which }) catch continue;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const parsed = parseLine(line) orelse continue;
            // A name beginning with `-` would be read as an option by every
            // later `hg` invocation. Composer refuses it and so does this.
            if (parsed.name[0] == '-') continue;
            replaceOrAppend(allocator, &out, .{ .name = parsed.name, .node = parsed.node, .kind = .branch });
        }
    }

    return out.toOwnedSlice(allocator);
}

fn replaceOrAppend(allocator: std.mem.Allocator, out: *std.ArrayList(Ref), ref: Ref) void {
    for (out.items) |*existing| {
        if (existing.kind == .branch and std.mem.eql(u8, existing.name, ref.name)) {
            existing.* = ref;
            return;
        }
    }
    out.append(allocator, ref) catch {};
}

/// `name   <rev>:<node>` — the shape `hg tags`, `hg branches` and
/// `hg bookmarks` all print, the last with a `*` marking the active one.
fn parseLine(raw: []const u8) ?struct { name: []const u8, node: []const u8 } {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return null;
    // `hg bookmarks` marks the current one with `*`, and indents everything.
    if (line[0] == '*') line = std.mem.trim(u8, line[1..], " \t");

    const space = std.mem.indexOfAny(u8, line, " \t") orelse return null;
    const name = line[0..space];
    if (name.len == 0) return null;

    const rest = std.mem.trim(u8, line[space..], " \t");
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    // The number before the colon is a LOCAL revision number, meaningless on
    // another clone. The node after it is the global identity, and it is the
    // only half worth recording — up to the next space, because `hg branches`
    // appends a status word (`(inactive)`, `(closed)`) that is not part of it.
    var node = std.mem.trim(u8, rest[colon + 1 ..], " \t");
    if (std.mem.indexOfAny(u8, node, " \t")) |cut| node = node[0..cut];
    if (node.len == 0) return null;

    return .{ .name = name, .node = node };
}

/// One file's contents at one changeset.
pub fn fileAt(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    node: []const u8,
    path: []const u8,
) ?[]const u8 {
    // `--` before the path: a filename beginning with `-` is otherwise an
    // option, and the node is checked by the caller for the same reason.
    const out = run(allocator, io, env, &.{
        "hg", "--cwd", mirror_dir, "cat", "-r", node, "--", path,
    }) catch return null;
    return if (std.mem.trim(u8, out, " \t\r\n").len == 0) null else out;
}

/// The changeset's date, as the lock spells it.
///
/// `{date|rfc3339date}`, verbatim — which carries the offset the COMMIT was
/// made with, not UTC. That is deliberate and it is Composer's behaviour, by
/// an accident worth naming: `HgDriver` builds `new DateTimeImmutable($output,
/// new DateTimeZone('UTC'))`, and PHP ignores the timezone argument when the
/// string already carries an offset. Converting to UTC here would be more
/// consistent with the git driver and would differ from Composer's lock by
/// exactly the committer's offset.
///
/// It is still reproducible: Mercurial stores the offset alongside the
/// timestamp, so every machine renders the same string for the same changeset.
pub fn changeDate(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    node: []const u8,
) ?[]const u8 {
    const out = run(allocator, io, env, &.{
        "hg", "--cwd", mirror_dir, "log", "--template", "{date|rfc3339date}", "-r", node,
    }) catch return null;
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Write the tree at `node` into `out_path` as a zip.
pub fn archiveAt(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    node: []const u8,
    out_path: []const u8,
) !void {
    if (util.parentOf(out_path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};

    // `-p package` gives the archive the single wrapping directory the unpacker
    // already strips, matching what every other dist looks like here.
    _ = run(allocator, io, env, &.{
        "hg", "--cwd",   mirror_dir, "archive",
        "-r", node,      "-t",       "zip",
        "-p", "package", "--",       out_path,
    }) catch return Error.HgFailed;

    if (!util.fileExists(io, out_path)) return Error.HgFailed;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a tags/branches/bookmarks line yields the NODE, not the local revision" {
    // The revision number before the colon is local to one clone — the same
    // changeset has a different number elsewhere — so recording it would pin a
    // lock to something another machine cannot resolve.
    const tag = parseLine("v1.2.0                     12:9f1c4b2a77e1").?;
    try testing.expectEqualStrings("v1.2.0", tag.name);
    try testing.expectEqualStrings("9f1c4b2a77e1", tag.node);

    // `hg bookmarks` indents and marks the active one.
    const active = parseLine(" * feature                  8:aa11bb22cc33").?;
    try testing.expectEqualStrings("feature", active.name);
    try testing.expectEqualStrings("aa11bb22cc33", active.node);

    // `hg branches` adds a status word after the node, which is not part of it.
    const closed = parseLine("old-branch                 3:dd44ee55ff66 (inactive)").?;
    try testing.expectEqualStrings("old-branch", closed.name);
    // And NOT "dd44ee55ff66 (inactive)", which is what a lock would otherwise
    // record as a changeset identity.
    try testing.expectEqualStrings("dd44ee55ff66", closed.node);

    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("no-colon-here") == null);
}
