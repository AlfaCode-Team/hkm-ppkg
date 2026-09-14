//! `archive` — writing a package out as a tar or a zip.
//!
//! The inverse of `archive.zig`, and the one command here that CREATES a
//! distribution rather than consuming one. It is what a project runs to publish
//! a release to an `artifact` repository, and what a CI job runs to ship a
//! deployable tree.
//!
//! ## What goes in
//!
//! Composer's rule, which is easy to get subtly wrong: the archive contains the
//! working tree, INCLUDING `vendor/`, minus
//!
//!   * version-control directories (`.git`, `.svn`, `.hg`, …) — always;
//!   * anything `.gitignore` excludes;
//!   * anything the manifest's `archive.exclude` excludes.
//!
//! `--ignore-filters` drops the last two, exactly as Composer's flag does.
//!
//! The two filter sources share one pattern language, because Composer's
//! `ComposerExcludeFilter` and `GitExcludeFilter` both run rules through
//! `BaseExcludeFilter::generatePattern`. A rule containing no slash — or only a
//! trailing one — matches at ANY path segment; a rule starting with `/` matches
//! only at the root; and a match must end at the end of the path or at a `/`,
//! so `src` excludes `src/` and `src/a.php` but never `srcfoo`.
//!
//! ## What this does not claim
//!
//! The bytes are NOT byte-identical to Composer's archive, and cannot be: a zip
//! records a timestamp per entry, and a tar records uid, gid and mtime. What is
//! reproduced is the CONTENT — which files are in it, under which paths, and
//! the name of the archive itself.

const std = @import("std");
const util = @import("util.zig");
const manifest = @import("manifest.zig");
const archive = @import("archive.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

pub const Error = error{
    NothingToArchive,
    WriteFailed,
};

pub const Format = enum {
    tar,
    tar_gz,
    zip,

    /// The suffix Composer appends to `--file`.
    pub fn suffix(self: Format) []const u8 {
        return switch (self) {
            .tar => ".tar",
            .tar_gz => ".tar.gz",
            .zip => ".zip",
        };
    }

    pub fn parse(name: []const u8) ?Format {
        if (std.mem.eql(u8, name, "tar")) return .tar;
        if (std.mem.eql(u8, name, "tar.gz") or std.mem.eql(u8, name, "tgz")) return .tar_gz;
        if (std.mem.eql(u8, name, "zip")) return .zip;
        return null;
    }
};

pub const Options = struct {
    format: Format = .tar,
    /// Prepended to every entry. Composer's archives have no wrapper, so this
    /// is empty unless a caller wants one.
    prefix: []const u8 = "",
    /// Skip `.gitignore` and `archive.exclude`. VCS directories are skipped
    /// regardless — a `.git` inside a published tarball is a mistake in every
    /// case, and Composer excludes it through `ignoreVCS` rather than a filter.
    ignore_filters: bool = false,
};

pub const Stats = struct {
    path: []const u8,
    files: usize,
    bytes: usize,
};

/// The filename Composer gives an archive of `name` at `version`.
///
/// `vendor/package` becomes `vendor-package`, because a `/` in a filename is a
/// directory. An unnamed root package falls back to the directory's own name,
/// which is what Composer does when `composer.json` has no `name`.
pub fn archiveName(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
) ![]const u8 {
    var flat: std.ArrayList(u8) = .empty;
    for (name) |c| try flat.append(allocator, if (c == '/') '-' else c);
    if (version.len == 0) return flat.toOwnedSlice(allocator);
    try flat.append(allocator, '-');
    try flat.appendSlice(allocator, version);
    return flat.toOwnedSlice(allocator);
}

/// Write `root` out as an archive at `dest`.
pub fn create(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    dest: []const u8,
    root_manifest: manifest.Manifest,
    opts: Options,
) !Stats {
    var rules: std.ArrayList(Rule) = .empty;
    if (!opts.ignore_filters) {
        for (root_manifest.archive_exclude) |line| {
            if (Rule.parse(allocator, line) catch null) |r| try rules.append(allocator, r);
        }
        try appendGitignore(allocator, io, root, &rules);
    }

    var entries: std.ArrayList([]const u8) = .empty;
    try walk(allocator, io, root, "", rules.items, &entries);
    if (entries.items.len == 0) return Error.NothingToArchive;

    // Composer's finder sorts by name; a stable order is also what makes two
    // runs over an unchanged tree produce the same file list.
    std.mem.sort([]const u8, entries.items, {}, lessThan);

    if (util.parentOf(dest)) |parent| Dir.cwd().createDirPath(io, parent) catch {};

    const body = switch (opts.format) {
        .zip => try writeZip(allocator, io, root, entries.items, opts.prefix),
        .tar, .tar_gz => try writeTar(allocator, io, root, entries.items, opts.prefix, opts.format == .tar_gz),
    };
    try util.writeFileAtomic(io, dest, body);

    return .{ .path = dest, .files = entries.items.len, .bytes = body.len };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── which files ───────────────────────────────────────────────────────────────

/// Directories no archive should ever carry, whatever the filters say.
const vcs_dirs = [_][]const u8{ ".git", ".svn", ".hg", ".bzr", "CVS", "_darcs" };

fn walk(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    rel: []const u8,
    rules: []const Rule,
    out: *std.ArrayList([]const u8),
) !void {
    const abs = if (rel.len == 0) root else try std.fs.path.join(allocator, &.{ root, rel });
    var dir = Dir.cwd().openDir(io, abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        if (item.kind == .directory and util.contains(&vcs_dirs, item.name)) continue;

        const child = if (rel.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, item.name });

        // The filters are asked about a LEADING-SLASH path, which is what
        // `BaseExcludeFilter` matches against.
        const probe = try std.fmt.allocPrint(allocator, "/{s}", .{child});
        if (excluded(rules, probe)) continue;

        switch (item.kind) {
            .directory => try walk(allocator, io, root, child, rules, out),
            // A symlink is followed only when it points inside the tree, which
            // is Composer's rule too — a link out of the project would drag
            // arbitrary files off the machine into a published archive.
            .file, .sym_link => try out.append(allocator, child),
            else => {},
        }
    }
}

fn appendGitignore(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    rules: *std.ArrayList(Rule),
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    const body = Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (Rule.parse(allocator, line) catch null) |r| try rules.append(allocator, r);
    }
}

/// One exclude rule, in Composer's spelling.
pub const Rule = struct {
    /// The glob, with the leading `!` and the surrounding slashes stripped.
    pattern: []const u8,
    /// `!rule` — a later negation re-includes what an earlier rule excluded.
    negate: bool,
    /// The rule began with `/`, so it matches only at the root.
    anchored: bool,

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !?Rule {
        var rule = std.mem.trim(u8, raw, " \t\r");
        if (rule.len == 0 or rule[0] == '#') return null;

        var negate = false;
        if (rule[0] == '!') {
            negate = true;
            rule = std.mem.trimStart(u8, rule[1..], "!");
        }
        if (rule.len == 0) return null;

        // `generatePattern`: a leading slash anchors at the root. A rule with
        // no slash, or with one only at the end, matches at any segment.
        const anchored = rule[0] == '/';
        const trimmed = std.mem.trim(u8, rule, "/");
        if (trimmed.len == 0) return null;

        return .{ .pattern = try allocator.dupe(u8, trimmed), .negate = negate, .anchored = anchored };
    }

    /// Does this rule match `path`, which begins with `/`?
    pub fn matches(self: Rule, path: []const u8) bool {
        if (self.anchored) return globPrefix(self.pattern, path[1..]);

        // Unanchored: the rule may start at any segment boundary.
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] != '/') continue;
            if (globPrefix(self.pattern, path[i + 1 ..])) return true;
        }
        return false;
    }
};

/// Run every rule in order; the last one to speak wins.
fn excluded(rules: []const Rule, path: []const u8) bool {
    var out = false;
    for (rules) |r| {
        if (r.matches(path)) out = !r.negate;
    }
    return out;
}

/// Does `pattern` match a prefix of `text` that ends at the end or at a `/`?
///
/// The `(?=$|/)` in Composer's generated regex, which is what makes `src`
/// exclude `src/a.php` without excluding `srcfoo`. `*` and `?` do not cross a
/// `/`; `**` does.
fn globPrefix(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0 or text[0] == '/';

    if (pattern[0] == '*') {
        if (pattern.len >= 2 and pattern[1] == '*') {
            // `**` spans separators. Try every split point, including one that
            // consumes the whole remaining text.
            var k: usize = 0;
            while (k <= text.len) : (k += 1) {
                if (globPrefix(pattern[2..], text[k..])) return true;
            }
            return false;
        }
        var k: usize = 0;
        while (true) {
            if (globPrefix(pattern[1..], text[k..])) return true;
            if (k >= text.len or text[k] == '/') return false;
            k += 1;
        }
    }

    if (text.len == 0) return false;

    if (pattern[0] == '?') {
        if (text[0] == '/') return false;
        return globPrefix(pattern[1..], text[1..]);
    }

    if (pattern[0] == '[') {
        const close = std.mem.indexOfScalar(u8, pattern, ']') orelse return false;
        var set = pattern[1..close];
        var want = true;
        if (set.len > 0 and (set[0] == '!' or set[0] == '^')) {
            want = false;
            set = set[1..];
        }
        var hit = false;
        var i: usize = 0;
        while (i < set.len) : (i += 1) {
            if (i + 2 < set.len and set[i + 1] == '-') {
                if (text[0] >= set[i] and text[0] <= set[i + 2]) hit = true;
                i += 2;
                continue;
            }
            if (set[i] == text[0]) hit = true;
        }
        if (hit != want) return false;
        return globPrefix(pattern[close + 1 ..], text[1..]);
    }

    if (text[0] != pattern[0]) return false;
    return globPrefix(pattern[1..], text[1..]);
}

// ── writing ───────────────────────────────────────────────────────────────────

fn writeTar(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    entries: []const []const u8,
    prefix: []const u8,
    gzip: bool,
) ![]const u8 {
    var plain: std.Io.Writer.Allocating = try .initCapacity(allocator, 1 << 16);
    var tw: std.tar.Writer = .{ .underlying_writer = &plain.writer };
    if (prefix.len > 0) try tw.setRoot(prefix);

    for (entries) |rel| {
        const abs = try std.fs.path.join(allocator, &.{ root, rel });
        const body = Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024 * 1024)) catch continue;
        try tw.writeFileBytes(rel, body, .{ .mode = if (isExecutable(io, abs)) 0o755 else 0o644 });
    }
    try tw.finishPedantically();

    if (!gzip) return plain.written();

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 1 << 16);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&out.writer, &window, .gzip, .default);
    try comp.writer.writeAll(plain.written());
    try comp.finish();
    return out.written();
}

/// Does the owner-execute bit survive into the archive?
///
/// `std.tar.Writer` copies only that one bit, which is also all Composer's
/// archiver preserves — but losing it turns a shipped `bin/` script into a file
/// nothing can run, and that failure appears only on the machine that unpacks
/// the archive.
fn isExecutable(io: Io, path: []const u8) bool {
    if (!std.Io.File.Permissions.has_executable_bit) return false;
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return (st.permissions.toMode() & 0o100) != 0;
}

/// A zip with deflated entries.
///
/// Written by hand because the standard library reads zips and does not write
/// them. Everything here is the format's own bookkeeping — local header, data,
/// central directory, end record — and the only judgement call is using
/// deflate rather than store, so that an archive of a vendor tree is not five
/// times the size of Composer's.
fn writeZip(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    entries: []const []const u8,
    prefix: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var directory: std.ArrayList(u8) = .empty;
    var count: u32 = 0;

    for (entries) |rel| {
        const abs = try std.fs.path.join(allocator, &.{ root, rel });
        const body = Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024 * 1024)) catch continue;

        const name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, rel })
        else
            rel;

        var deflated: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(body.len, 64));
        {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var comp = try std.compress.flate.Compress.init(&deflated.writer, &window, .raw, .default);
            try comp.writer.writeAll(body);
            try comp.finish();
        }
        // Deflate can be larger than the input on incompressible data; storing
        // it uncompressed is both smaller and what every other writer does.
        const stored = deflated.written().len >= body.len;
        const payload = if (stored) body else deflated.written();
        const method: u16 = if (stored) 0 else 8;

        const crc = std.hash.Crc32.hash(body);
        const offset: u32 = @intCast(out.items.len);

        try appendLocalHeader(allocator, &out, name, method, crc, payload.len, body.len);
        try out.appendSlice(allocator, payload);

        try appendCentralHeader(allocator, &directory, name, method, crc, payload.len, body.len, offset);
        count += 1;
    }

    const directory_offset: u32 = @intCast(out.items.len);
    try out.appendSlice(allocator, directory.items);

    try out.appendSlice(allocator, "PK\x05\x06");
    try appendU16(allocator, &out, 0); // this disk
    try appendU16(allocator, &out, 0); // disk with the directory
    try appendU16(allocator, &out, @intCast(count));
    try appendU16(allocator, &out, @intCast(count));
    try appendU32(allocator, &out, @intCast(directory.items.len));
    try appendU32(allocator, &out, directory_offset);
    try appendU16(allocator, &out, 0); // comment length

    return out.toOwnedSlice(allocator);
}

fn appendLocalHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    method: u16,
    crc: u32,
    compressed: usize,
    uncompressed: usize,
) !void {
    try out.appendSlice(allocator, "PK\x03\x04");
    try appendU16(allocator, out, 20); // version needed
    try appendU16(allocator, out, 0); // flags
    try appendU16(allocator, out, method);
    try appendU16(allocator, out, 0); // mod time
    try appendU16(allocator, out, 0x21); // mod date — 1980-01-01, the epoch a zip can express
    try appendU32(allocator, out, crc);
    try appendU32(allocator, out, @intCast(compressed));
    try appendU32(allocator, out, @intCast(uncompressed));
    try appendU16(allocator, out, @intCast(name.len));
    try appendU16(allocator, out, 0); // extra length
    try out.appendSlice(allocator, name);
}

fn appendCentralHeader(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    method: u16,
    crc: u32,
    compressed: usize,
    uncompressed: usize,
    offset: u32,
) !void {
    try out.appendSlice(allocator, "PK\x01\x02");
    try appendU16(allocator, out, 0x031e); // made by: unix, spec 3.0
    try appendU16(allocator, out, 20);
    try appendU16(allocator, out, 0);
    try appendU16(allocator, out, method);
    try appendU16(allocator, out, 0);
    try appendU16(allocator, out, 0x21);
    try appendU32(allocator, out, crc);
    try appendU32(allocator, out, @intCast(compressed));
    try appendU32(allocator, out, @intCast(uncompressed));
    try appendU16(allocator, out, @intCast(name.len));
    try appendU16(allocator, out, 0); // extra
    try appendU16(allocator, out, 0); // comment
    try appendU16(allocator, out, 0); // disk
    try appendU16(allocator, out, 0); // internal attributes
    try appendU32(allocator, out, 0o644 << 16); // external attributes: unix mode
    try appendU32(allocator, out, offset);
    try out.appendSlice(allocator, name);
}

fn appendU16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parsed(a: std.mem.Allocator, s: []const u8) Rule {
    return (Rule.parse(a, s) catch unreachable).?;
}

test "a rule with no slash matches at any segment; one with a leading slash only at the root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const anywhere = parsed(a, "tests");
    try testing.expect(anywhere.matches("/tests"));
    try testing.expect(anywhere.matches("/tests/Unit/AThing.php"));
    try testing.expect(anywhere.matches("/src/tests/x.php"));
    // The `(?=$|/)` that stops a prefix match from swallowing a sibling.
    try testing.expect(!anywhere.matches("/testsuite.xml"));

    const at_root = parsed(a, "/tests");
    try testing.expect(at_root.matches("/tests/Unit/x.php"));
    try testing.expect(!at_root.matches("/src/tests/x.php"));
}

test "wildcards stop at a separator unless they are doubled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const star = parsed(a, "*.log");
    try testing.expect(star.matches("/build.log"));
    try testing.expect(star.matches("/var/build.log"));
    try testing.expect(!star.matches("/build.log.gz"));

    // `*` does not cross a `/`; `**` does.
    try testing.expect(!parsed(a, "src/*.php").matches("/src/Sub/A.php"));
    try testing.expect(parsed(a, "src/**/*.php").matches("/src/Sub/A.php"));

    const question = parsed(a, "a?c");
    try testing.expect(question.matches("/abc"));
    try testing.expect(!question.matches("/ac"));
    try testing.expect(!question.matches("/a/c"));
}

test "a later negation re-includes what an earlier rule excluded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rules = [_]Rule{ parsed(a, "docs"), parsed(a, "!docs/README.md") };
    try testing.expect(excluded(&rules, "/docs/internal.md"));
    try testing.expect(!excluded(&rules, "/docs/README.md"));

    // Order decides: the same two the other way round exclude everything.
    const reversed = [_]Rule{ parsed(a, "!docs/README.md"), parsed(a, "docs") };
    try testing.expect(excluded(&reversed, "/docs/README.md"));
}

test "a character class is honoured, including its negation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(parsed(a, "file[0-9].txt").matches("/file3.txt"));
    try testing.expect(!parsed(a, "file[0-9].txt").matches("/filex.txt"));
    try testing.expect(parsed(a, "file[!0-9].txt").matches("/filex.txt"));
}

test "an archive is named the way composer names one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `/` is a directory separator, so the vendor separator becomes a dash.
    try testing.expectEqualStrings("acme-widget-1.2.3", try archiveName(a, "acme/widget", "1.2.3"));
    try testing.expectEqualStrings(
        "test-mixed-repos-1.0.0+no-version-set",
        try archiveName(a, "test/mixed-repos", "1.0.0+no-version-set"),
    );
    try testing.expectEqualStrings("acme-widget", try archiveName(a, "acme/widget", ""));
}

test "the suffix and the format name agree in both directions" {
    try testing.expectEqual(Format.tar_gz, Format.parse("tar.gz").?);
    try testing.expectEqual(Format.tar_gz, Format.parse("tgz").?);
    try testing.expectEqual(Format.zip, Format.parse("zip").?);
    try testing.expect(Format.parse("rar") == null);
    try testing.expectEqualStrings(".tar.gz", Format.tar_gz.suffix());
}
