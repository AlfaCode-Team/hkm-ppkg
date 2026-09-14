//! Subversion repositories.
//!
//! The odd one out, and worth saying why: there is no clone and no cache
//! directory here. Subversion is a SERVER protocol — `svn ls`, `svn cat` and
//! `svn export` all talk to the remote directly — so there is nothing local to
//! keep in step, and a mirror would be a second copy of a thing the server is
//! already authoritative for.
//!
//! ## Layout, not refs
//!
//! Subversion has no tags and no branches. It has DIRECTORIES that a
//! convention treats as tags and branches, and Composer's driver encodes that
//! convention: `trunk`, `branches/*`, `tags/*`, each overridable per repository
//! (`trunk-path`, `branches-path`, `tags-path`, and `false` to disable one).
//!
//! An identifier is therefore a PATH plus a revision — `/tags/1.2.0/@42` — and
//! both halves matter. The path says which directory, the revision pins it: a
//! tag in Subversion is an ordinary directory that anyone can commit to, so a
//! lock that recorded only the path would pin nothing at all.
//!
//! ## What the revision is taken from
//!
//! `svn ls --verbose` prints the revision of each entry's last change. Composer
//! takes `max(lastRev, entryRev)` where `lastRev` is the revision of `./` — the
//! parent directory's own last change — because a tag directory created by a
//! copy carries the copy's revision while its contents carry an older one.
//! Taking the entry's revision alone pins a tree that predates the tag.

const std = @import("std");
const git = @import("git.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    SvnFailed,
};

/// The directory convention a repository follows.
pub const Layout = struct {
    /// `null` disables the section entirely — Composer spells that `false`.
    trunk: ?[]const u8 = "trunk",
    branches: ?[]const u8 = "branches",
    tags: ?[]const u8 = "tags",
    /// `package-path` — the package lives in a SUBDIRECTORY of each tag.
    package: []const u8 = "",
};

/// Is `svn` on this machine?
pub fn available(allocator: std.mem.Allocator, io: Io, env: *EnvMap) bool {
    const out = run(allocator, io, env, &.{ "svn", "--version", "--quiet" }) catch return false;
    return std.mem.trim(u8, out, " \t\r\n").len > 0;
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    argv: []const []const u8,
) ![]const u8 {
    return git.runTool(allocator, io, env, argv) catch Error.SvnFailed;
}

/// Does this URL answer as a Subversion repository?
pub fn probe(allocator: std.mem.Allocator, io: Io, env: *EnvMap, url: []const u8) bool {
    _ = run(allocator, io, env, &.{ "svn", "info", "--non-interactive", "--", url }) catch return false;
    return true;
}

pub const Ref = struct {
    name: []const u8,
    /// `/tags/1.2.0/@42` — the path and the revision, together.
    identifier: []const u8,
    kind: enum { tag, branch },
};

/// Every tag and branch the layout convention finds.
pub fn refs(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    base_url: []const u8,
    layout: Layout,
) ![]const Ref {
    var out: std.ArrayList(Ref) = .empty;
    const base = std.mem.trimEnd(u8, base_url, "/");

    if (layout.trunk) |trunk| {
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, trunk });
        if (list(allocator, io, env, url) catch null) |entries| {
            // Only `./` matters here: it carries trunk's own last-changed
            // revision, and trunk is one branch rather than a directory of
            // them.
            for (entries) |e| {
                if (!std.mem.eql(u8, e.name, "./")) continue;
                try out.append(allocator, .{
                    .name = "trunk",
                    .identifier = try identifier(allocator, try std.fmt.allocPrint(allocator, "/{s}", .{trunk}), e.revision, layout),
                    .kind = .branch,
                });
                break;
            }
        }
    }

    if (layout.branches) |branches| try collect(allocator, io, env, base, branches, layout, .branch, &out);
    if (layout.tags) |tags| try collect(allocator, io, env, base, tags, layout, .tag, &out);

    return out.toOwnedSlice(allocator);
}

fn collect(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    base: []const u8,
    section: []const u8,
    layout: Layout,
    kind: @FieldType(Ref, "kind"),
    out: *std.ArrayList(Ref),
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, section });
    const entries = list(allocator, io, env, url) catch return;

    var parent_revision: u64 = 0;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "./")) {
            parent_revision = e.revision;
            continue;
        }
        // Only directories are tags or branches; a stray file in `tags/` is
        // not a version of anything.
        if (!std.mem.endsWith(u8, e.name, "/")) continue;

        const name = std.mem.trimEnd(u8, e.name, "/");
        const path = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ section, name });
        try out.append(allocator, .{
            .name = name,
            .identifier = try identifier(allocator, path, @max(parent_revision, e.revision), layout),
            .kind = kind,
        });
    }
}

/// `buildIdentifier`: the directory, the package path, and the revision.
fn identifier(
    allocator: std.mem.Allocator,
    path: []const u8,
    revision: u64,
    layout: Layout,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}/@{d}", .{
        std.mem.trimEnd(u8, path, "/"),
        layout.package,
        revision,
    });
}

pub const Entry = struct {
    revision: u64,
    name: []const u8,
};

/// `svn ls --verbose`, parsed.
///
/// The format is `<rev> <author> [<size>] <date...> <name>` with the name last
/// and everything before it variable-width, which is why Composer matches the
/// first field and the last one and ignores the middle entirely.
pub fn list(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    url: []const u8,
) ![]const Entry {
    const out = try run(allocator, io, env, &.{ "svn", "ls", "--verbose", "--non-interactive", "--", url });
    return parseList(allocator, out);
}

fn parseList(allocator: std.mem.Allocator, text: []const u8) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        const first_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const revision = std.fmt.parseInt(u64, line[0..first_end], 10) catch continue;

        // The LAST whitespace-separated field is the name. A name containing a
        // space breaks that, and it breaks Composer's regex too — this matches
        // its behaviour rather than inventing a better parse that would then
        // disagree about which entries exist.
        const last_start = (std.mem.lastIndexOfAny(u8, line, " \t") orelse continue) + 1;
        const name = line[last_start..];
        if (name.len == 0) continue;

        try entries.append(allocator, .{ .revision = revision, .name = name });
    }
    return entries.toOwnedSlice(allocator);
}

/// Split `/tags/1.2.0/@42` into its path and its `@42`.
pub fn splitIdentifier(id: []const u8) struct { path: []const u8, rev: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, id, '@') orelse return .{ .path = id, .rev = "" };
    // Only when the tail really is `@<digits>`; a URL-ish identifier could
    // carry an `@` that is part of a name.
    if (at + 1 >= id.len) return .{ .path = id, .rev = "" };
    for (id[at + 1 ..]) |c| {
        if (!std.ascii.isDigit(c)) return .{ .path = id, .rev = "" };
    }
    return .{ .path = std.mem.trimEnd(u8, id[0..at], "/"), .rev = id[at..] };
}

/// One file's contents at one identifier.
pub fn fileAt(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    base_url: []const u8,
    id: []const u8,
    path: []const u8,
) ?[]const u8 {
    const split = splitIdentifier(id);
    const url = std.fmt.allocPrint(allocator, "{s}{s}/{s}{s}", .{
        std.mem.trimEnd(u8, base_url, "/"),
        split.path,
        path,
        split.rev,
    }) catch return null;

    const out = run(allocator, io, env, &.{ "svn", "cat", "--non-interactive", "--", url }) catch return null;
    return if (std.mem.trim(u8, out, " \t\r\n").len == 0) null else out;
}

/// The date of the revision an identifier names.
///
/// Parsed out of `svn info`'s `Last Changed Date:` line, and NOT taken from
/// `--show-item last-changed-date`, which would be simpler and would be UTC.
///
/// The reason is byte-identity with Composer, and it is worth stating so nobody
/// "fixes" it: `SvnDriver::getChangeDate` reads that line, which `svn` renders
/// in the CLIENT's local timezone, and builds a `DateTimeImmutable` from it —
/// PHP then ignores the UTC timezone argument because the string already
/// carries an offset. So Composer's lock records the offset of whichever
/// machine ran the update. That is a flaw, it is Composer's, and it is present
/// whether or not this package exists; introducing a DIFFERENT `time` here to
/// avoid it would trade a pre-existing quirk for a permanent diff against every
/// lock Composer writes.
pub fn changeDate(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    base_url: []const u8,
    id: []const u8,
) ?[]const u8 {
    const split = splitIdentifier(id);
    const url = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        std.mem.trimEnd(u8, base_url, "/"),
        split.path,
        split.rev,
    }) catch return null;

    const out = run(allocator, io, env, &.{ "svn", "info", "--non-interactive", "--", url }) catch return null;
    return parseChangeDate(allocator, out) catch null;
}

/// `Last Changed Date: 2026-09-08 00:09:22 +0300 (Tue, 08 Sep 2026)`
/// → `2026-09-08T00:09:22+03:00`
fn parseChangeDate(allocator: std.mem.Allocator, info: []const u8) !?[]const u8 {
    const marker = "Last Changed Date:";
    const at = std.mem.indexOf(u8, info, marker) orelse return null;

    var rest = info[at + marker.len ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl];
    // Composer's regex stops at the `(` that opens the human-readable form.
    if (std.mem.indexOfScalar(u8, rest, '(')) |paren| rest = rest[0..paren];
    const line = std.mem.trim(u8, rest, " \t\r");

    // `<date> <time> <+hhmm>`
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const date = parts.next() orelse return null;
    const time = parts.next() orelse return null;
    const offset = parts.next() orelse "+0000";
    if (date.len < 10 or time.len < 8 or offset.len < 5) return null;

    return try std.fmt.allocPrint(allocator, "{s}T{s}{s}:{s}", .{
        date,
        time[0..8],
        offset[0..3],
        offset[3..5],
    });
}

/// Export the tree at `id` into `dest`.
///
/// `svn export` rather than an archive: Subversion has no `archive` verb, and
/// exporting straight to the destination avoids inventing a zip only to unpack
/// it again. It also means a `.svn` directory never appears in vendor, which is
/// what `export` is for as opposed to `checkout`.
pub fn exportTo(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    base_url: []const u8,
    id: []const u8,
    dest: []const u8,
) !void {
    const split = splitIdentifier(id);
    const url = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        std.mem.trimEnd(u8, base_url, "/"),
        split.path,
        split.rev,
    });

    if (util.parentOf(dest)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
    Dir.cwd().deleteTree(io, dest) catch {};

    _ = run(allocator, io, env, &.{
        "svn", "export", "--force", "--non-interactive", "--", url, dest,
    }) catch return Error.SvnFailed;

    if (!util.dirExists(Dir.cwd(), io, dest)) return Error.SvnFailed;
}

/// Read the three path overrides from a repository declaration.
pub fn layoutOf(raw: ?std.json.Value) Layout {
    var out: Layout = .{};
    const value = raw orelse return out;
    if (value != .object) return out;

    const map = [_]struct { key: []const u8, field: enum { trunk, branches, tags } }{
        .{ .key = "trunk-path", .field = .trunk },
        .{ .key = "branches-path", .field = .branches },
        .{ .key = "tags-path", .field = .tags },
    };
    for (map) |m| {
        const v = value.object.get(m.key) orelse continue;
        // `false` disables the section. A string renames it. Anything else is
        // left alone rather than guessed at.
        const replacement: ?[]const u8 = switch (v) {
            .bool => |b| if (b) null else @as(?[]const u8, null),
            .string => |str| str,
            else => continue,
        };
        // A `false` and a `true` both land on null here; only `false` is
        // meaningful in Composer's schema, and `true` for a path is a mistake
        // that disabling is the safer reading of.
        switch (m.field) {
            .trunk => out.trunk = replacement,
            .branches => out.branches = replacement,
            .tags => out.tags = replacement,
        }
    }
    if (value.object.get("package-path")) |v| {
        if (v == .string) {
            const trimmed = std.mem.trim(u8, v.string, "/");
            if (trimmed.len > 0) {
                out.package = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "/{s}",
                    .{trimmed},
                ) catch "";
            }
        }
    }
    return out;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "svn ls --verbose is parsed by its first and last field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The real shape: revision, author, optional size, a date whose width
    // varies, then the name.
    const sample =
        \\     42 alice                 Sep 08 10:11 ./
        \\     37 bob                   Sep 01 09:00 1.0.0/
        \\     41 carol                 Sep 07 12:30 1.1.0/
        \\     12 dave              1024 Jan 02  2025 README.txt
    ;
    const entries = try parseList(a, sample);
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqual(@as(u64, 42), entries[0].revision);
    try testing.expectEqualStrings("./", entries[0].name);
    try testing.expectEqualStrings("1.0.0/", entries[1].name);
    try testing.expectEqual(@as(u64, 12), entries[3].revision);
}

test "a tag takes the LATER of its own revision and its parent's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The case the max() exists for: a tag directory created by a copy carries
    // the copy's revision while its contents carry an older one. Taking the
    // entry's own revision pins a tree from before the tag was made.
    var out: std.ArrayList(Ref) = .empty;
    const entries = [_]Entry{
        .{ .revision = 42, .name = "./" },
        .{ .revision = 37, .name = "1.0.0/" },
    };
    var parent: u64 = 0;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "./")) {
            parent = e.revision;
            continue;
        }
        const name = std.mem.trimEnd(u8, e.name, "/");
        try out.append(a, .{
            .name = name,
            .identifier = try identifier(a, try std.fmt.allocPrint(a, "/tags/{s}", .{name}), @max(parent, e.revision), .{}),
            .kind = .tag,
        });
    }
    try testing.expectEqualStrings("/tags/1.0.0/@42", out.items[0].identifier);
}

test "an identifier splits back into a path and a revision" {
    const split = splitIdentifier("/tags/1.2.0/@42");
    try testing.expectEqualStrings("/tags/1.2.0", split.path);
    try testing.expectEqualStrings("@42", split.rev);

    // A `package-path` is part of the path, not of the revision.
    const nested = splitIdentifier("/tags/1.2.0/sub/pkg/@7");
    try testing.expectEqualStrings("/tags/1.2.0/sub/pkg", nested.path);
    try testing.expectEqualStrings("@7", nested.rev);

    // An `@` that is not a revision is left in the path — a name may contain
    // one, and cutting there would ask the server for a directory that is not
    // the one recorded.
    const named = splitIdentifier("/tags/v1@beta");
    try testing.expectEqualStrings("/tags/v1@beta", named.path);
    try testing.expectEqualStrings("", named.rev);
}

test "the change date is read the way composer reads it, offset and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info =
        \\Path: 1.1.0
        \\Revision: 4
        \\Last Changed Rev: 4
        \\Last Changed Date: 2026-09-08 00:09:22 +0300 (Tue, 08 Sep 2026)
    ;
    // The offset is the CLIENT's, and it is kept — see the doc comment on
    // `changeDate` for why matching Composer here beats being more correct.
    try testing.expectEqualStrings("2026-09-08T00:09:22+03:00", (try parseChangeDate(a, info)).?);

    const utc = "Last Changed Date: 2020-01-02 03:04:05 +0000 (Thu, 02 Jan 2020)";
    try testing.expectEqualStrings("2020-01-02T03:04:05+00:00", (try parseChangeDate(a, utc)).?);

    try testing.expect((try parseChangeDate(a, "Revision: 4")) == null);
}

test "a layout override renames a section, and false disables it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const declared = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"svn","url":"svn://x/y","trunk-path":"main","tags-path":false,"package-path":"lib"}
    , .{});
    const layout = layoutOf(declared);

    try testing.expectEqualStrings("main", layout.trunk.?);
    try testing.expectEqualStrings("branches", layout.branches.?);
    try testing.expect(layout.tags == null);
    try testing.expectEqualStrings("/lib", layout.package);

    // A `package-path` becomes part of every identifier.
    try testing.expectEqualStrings("/tags/1.0/lib/@9", try identifier(a, "/tags/1.0", 9, layout));

    // Nothing declared leaves Composer's defaults.
    const bare = layoutOf(null);
    try testing.expectEqualStrings("trunk", bare.trunk.?);
    try testing.expectEqualStrings("tags", bare.tags.?);
    try testing.expectEqualStrings("", bare.package);
}
