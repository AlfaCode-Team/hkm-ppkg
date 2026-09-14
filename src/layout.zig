//! Where a project's directories actually are.
//!
//! Composer lets a project move `vendor/` and `vendor/bin/` (`config.vendor-dir`,
//! `config.bin-dir`, and the `COMPOSER_VENDOR_DIR` / `COMPOSER_BIN_DIR`
//! environment overrides). Until this file existed, both were hardcoded, and a
//! project that moved them was REFUSED by the compatibility audit rather than
//! installed into the wrong place — the right call while the support was
//! missing, and the reason this is the file that removes that refusal.
//!
//! The second half is `shortestPathCode`, a line-for-line port of
//! `Composer\Util\Filesystem::findShortestPathCode`. Generated PHP has to reach
//! from one directory to another, and once the two directories stop being
//! `vendor/bin` and `vendor` the answer stops being `__DIR__ . '/..'`. Composer
//! does not special-case it; neither does this.

const std = @import("std");
const manifest = @import("manifest.zig");
const util = @import("util.zig");

const EnvMap = std.process.Environ.Map;

/// The three directories every other module needs, all ABSOLUTE.
///
/// Absolute rather than project-relative because the generated PHP is written
/// in terms of one directory reaching another, and a relative path cannot
/// express `bin-dir` sitting outside the project at all — which Composer
/// permits.
pub const Layout = struct {
    /// The project root: the directory holding `composer.json`.
    root: []const u8,
    /// `config.vendor-dir`, resolved.
    vendor: []const u8,
    /// `config.bin-dir`, resolved, with `{$vendor-dir}` expanded.
    bin: []const u8,

    /// How to NAME one of these directories in a message.
    ///
    /// Project-relative when it sits inside the project (`vendor`,
    /// `lib/vendor/bin`), absolute when it does not. A message that says
    /// "vendor/ is up to date" to a project whose tree is in `lib/vendor` is
    /// not a small inaccuracy: it is the tool reporting on a directory the
    /// project does not have.
    pub fn label(self: Layout, allocator: std.mem.Allocator, path: []const u8) []const u8 {
        _ = allocator;
        const prefix_len = self.root.len + 1;
        if (path.len > prefix_len and
            std.mem.startsWith(u8, path, self.root) and
            path[self.root.len] == '/') return path[prefix_len..];
        return path;
    }

    /// True when the layout is the one Composer would use with no config at
    /// all. Callers that only need to know "is anything unusual here" — the
    /// compatibility audit, a progress line naming `vendor/bin/x` — ask this
    /// instead of comparing paths themselves.
    pub fn isDefault(self: Layout) bool {
        return std.mem.endsWith(u8, self.vendor, "/vendor") and
            std.mem.eql(u8, std.fs.path.dirname(self.vendor) orelse "", self.root) and
            std.mem.eql(u8, std.fs.path.dirname(self.bin) orelse "", self.vendor) and
            std.mem.eql(u8, std.fs.path.basename(self.bin), "bin");
    }
};

/// The layout for a project, from its manifest and the environment.
///
/// Precedence is Composer's: the environment variable beats `config`, which
/// beats the default. A relative value is taken relative to the project root —
/// `Config::realpath` does exactly that, and does NOT consult the process's
/// working directory, which is why a `hkm ppkg install ../other-project` puts
/// the tree where that project's own composer.json says and not next to the
/// shell.
pub fn resolve(
    allocator: std.mem.Allocator,
    env: ?*EnvMap,
    root_dir: []const u8,
    root: manifest.Manifest,
) !Layout {
    const root_abs = try absolute(allocator, env, root_dir);

    const vendor_raw = envOr(env, "COMPOSER_VENDOR_DIR") orelse
        root.config_vendor_dir orelse "vendor";
    const vendor = try anchor(allocator, root_abs, vendor_raw);

    // `{$vendor-dir}` expands to the RESOLVED vendor directory: Config::process
    // recurses through get('vendor-dir'), which has already been made absolute
    // by the time bin-dir asks for it.
    const bin_raw = envOr(env, "COMPOSER_BIN_DIR") orelse
        root.config_bin_dir orelse "{$vendor-dir}/bin";
    const bin_expanded = try expand(allocator, bin_raw, vendor);
    const bin = try anchor(allocator, root_abs, bin_expanded);

    return .{ .root = root_abs, .vendor = vendor, .bin = bin };
}

/// The layout a project has when nothing is configured — `<root>/vendor` and
/// `<root>/vendor/bin`. For callers that have no manifest in hand.
pub fn default(allocator: std.mem.Allocator, root_dir: []const u8) !Layout {
    return resolve(allocator, null, root_dir, .{});
}

fn envOr(env: ?*EnvMap, key: []const u8) ?[]const u8 {
    const e = env orelse return null;
    const v = e.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// Substitute every `{$vendor-dir}`. Composer's `process()` handles any config
/// key, but `vendor-dir` is the only one that appears in a path default, and
/// resolving arbitrary keys would mean modelling all 59 of them to serve a
/// substitution nothing in the wild makes.
fn expand(allocator: std.mem.Allocator, value: []const u8, vendor: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, value, "{$vendor-dir}") == null) return value;
    const size = std.mem.replacementSize(u8, value, "{$vendor-dir}", vendor);
    const out = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, value, "{$vendor-dir}", vendor, out);
    return out;
}

/// Make `path` absolute against `base`, and strip the trailing slash Composer
/// strips (`rtrim($val, '/\\')`).
fn anchor(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    const trimmed = trimEnd(path);
    if (trimmed.len == 0) return base;
    if (isAbsolute(trimmed)) return normalise(allocator, trimmed);
    return normalise(allocator, try std.fs.path.join(allocator, &.{ base, trimmed }));
}

/// A relative project root is resolved through `util.absPath` first, which
/// reads `PWD` rather than calling `getcwd`. That preference is deliberate and
/// documented there: `getcwd` resolves symlinks, so a project reached through a
/// symlinked path would have `install-path` entries written in a form its owner
/// does not recognise.
///
/// `getcwd` is nonetheless the fallback, because a Layout that is not absolute
/// is not merely inconvenient — `shortestPathCode` between two relative paths
/// finds no common ancestor and emits a literal `'.'` into the generated
/// autoloader. A caller passing no environment still gets a usable layout.
fn absolute(allocator: std.mem.Allocator, env: ?*EnvMap, path: []const u8) ![]const u8 {
    if (isAbsolute(path)) return normalise(allocator, path);

    if (env) |e| {
        const resolved = try util.absPath(allocator, e, path);
        if (isAbsolute(resolved)) return normalise(allocator, resolved);
    }

    const cwd = cwdAlloc(allocator) catch return normalise(allocator, path);
    return normalise(allocator, try std.fs.path.join(allocator, &.{ cwd, path }));
}

/// `getcwd(3)`. std has no portable wrapper in this Zig version, and the one
/// caller is this fallback.
///
/// On Linux without libc it is the raw syscall instead. The released Linux
/// binaries are static — built against no libc, so they run on any
/// distribution — and `std.c.getcwd` there is not a missing symbol at run time
/// but a compile error: every Linux build failed with it, while macOS (which
/// always links libc) built and tested green.
fn cwdAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.Unsupported;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.getcwd(&buf, buf.len);
        if (@as(isize, @bitCast(rc)) < 0) return error.CurrentDirectoryUnavailable;
    } else {
        _ = std.c.getcwd(&buf, buf.len) orelse return error.CurrentDirectoryUnavailable;
    }
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse return error.CurrentDirectoryUnavailable;
    return allocator.dupe(u8, buf[0..len]);
}

fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    // `C:` — Composer's isAbsolutePath accepts a drive letter and a UNC prefix.
    if (path.len > 1 and path[1] == ':') return true;
    return std.mem.startsWith(u8, path, "\\\\");
}

fn trimEnd(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return path[0..end];
}

/// `Filesystem::normalizePath` for the subset that matters here: collapse `//`,
/// drop `.`, and resolve `..` textually.
///
/// Textually, not through the filesystem, because both Composer and this are
/// describing where a file WILL be written — `realpath()` on a directory that
/// does not exist yet returns false, and the whole point of an installer is
/// that the destination is not there yet.
pub fn normalise(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const abs = path.len > 0 and path[0] == '/';
    var parts: std.ArrayList([]const u8) = .empty;

    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |chunk| {
        if (chunk.len == 0 or std.mem.eql(u8, chunk, ".")) continue;
        if (std.mem.eql(u8, chunk, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
                continue;
            }
            if (abs) continue; // `/..` is `/`
        }
        try parts.append(allocator, chunk);
    }

    var out: std.ArrayList(u8) = .empty;
    if (abs) try out.append(allocator, '/');
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, p);
    }
    if (out.items.len == 0) try out.append(allocator, '.');
    return out.toOwnedSlice(allocator);
}

// ── generated PHP that reaches from one path to another ──────────────────────

/// A PHP expression evaluating, inside the file at `from`, to the path `to`.
///
/// A port of `Composer\Util\Filesystem::findShortestPathCode`, including the
/// parts that look like accidents and are not:
///
///   * with `static_code`, the result is TWO concatenated literals
///     (`__DIR__ . '/..'.'/x/y'`), not one — Composer emits the ancestor hops
///     and the remainder separately, and matching it byte for byte is what lets
///     a generated proxy be diffed against Composer's. Without it the hops come
///     out as nested `dirname()` calls instead, which is the form the
///     non-static autoload files use;
///   * when the only common ancestor is `/` and the source is more than one
///     level down, it gives up on relativity and emits the absolute path,
///     because `'/../../../..'` chains are worse than useless in a moved tree;
///   * `$directories` counts the `from` path itself as a directory rather than
///     a file, which changes the hop count by exactly one.
///
/// `from` and `to` must both be absolute; a caller that has a relative path has
/// not resolved its `Layout` yet.
/// A plain relative path from `from_raw` to `to_raw` — no PHP around it.
///
/// `Filesystem::findShortestPath`, which Composer uses for the human-readable
/// comment at the top of a `vendor/bin` proxy. Separate from
/// `shortestPathCode` because that one emits an expression: the comment wants
/// `../phpunit/phpunit/phpunit`, not `__DIR__ . '/..'.'/…'`.
pub fn relativePath(
    allocator: std.mem.Allocator,
    from_raw: []const u8,
    to_raw: []const u8,
) ![]const u8 {
    const from = try normalise(allocator, from_raw);
    const to = try normalise(allocator, to_raw);
    if (std.mem.eql(u8, from, to)) return ".";

    var from_it = std.mem.tokenizeScalar(u8, from, '/');
    var to_it = std.mem.tokenizeScalar(u8, to, '/');

    var from_parts: std.ArrayList([]const u8) = .empty;
    var to_parts: std.ArrayList([]const u8) = .empty;
    while (from_it.next()) |seg| try from_parts.append(allocator, seg);
    while (to_it.next()) |seg| try to_parts.append(allocator, seg);

    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len and
        std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) : (common += 1)
    {}

    var out: std.ArrayList(u8) = .empty;
    for (common..from_parts.items.len) |_| try out.appendSlice(allocator, "../");
    for (to_parts.items[common..], 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    if (out.items.len == 0) return ".";
    // A trailing slash is left by the loop above when `to` IS the ancestor.
    if (out.items[out.items.len - 1] == '/') _ = out.pop();
    return out.toOwnedSlice(allocator);
}

pub fn shortestPathCode(
    allocator: std.mem.Allocator,
    from_raw: []const u8,
    to_raw: []const u8,
    directories: bool,
    static_code: bool,
) ![]const u8 {
    const from = try normalise(allocator, from_raw);
    const to = try normalise(allocator, to_raw);

    if (std.mem.eql(u8, from, to)) return if (directories) "__DIR__" else "__FILE__";

    // Walk `to` up until it is a prefix of `from`.
    var common: []const u8 = to;
    while (true) {
        const with_slash = try std.fmt.allocPrint(allocator, "{s}/", .{common});
        const from_slash = try std.fmt.allocPrint(allocator, "{s}/", .{from});
        if (std.mem.startsWith(u8, from_slash, with_slash)) break;
        if (std.mem.eql(u8, common, "/") or std.mem.eql(u8, common, ".")) break;
        common = phpDirname(common);
    }

    if (!std.mem.startsWith(u8, from, common) or std.mem.eql(u8, common, ".")) {
        return phpString(allocator, to);
    }

    // `__DIR__ . '/rest'` when `to` lives underneath `from`.
    const from_slash = try std.fmt.allocPrint(allocator, "{s}/", .{from});
    if (std.mem.startsWith(u8, to, from_slash)) {
        return std.fmt.allocPrint(allocator, "__DIR__ . {s}", .{
            try phpString(allocator, to[from.len..]),
        });
    }

    const common_slash = if (std.mem.endsWith(u8, common, "/"))
        common
    else
        try std.fmt.allocPrint(allocator, "{s}/", .{common});

    const below = after(from, common_slash.len);
    const depth = std.mem.count(u8, below, "/") + @intFromBool(directories);

    if (std.mem.eql(u8, common_slash, "/") and depth > 1) {
        return phpString(allocator, to);
    }

    var code: std.ArrayList(u8) = .empty;
    if (static_code) {
        try code.appendSlice(allocator, "__DIR__ . '");
        for (0..depth) |_| try code.appendSlice(allocator, "/..");
        try code.append(allocator, '\'');
    } else {
        for (0..depth) |_| try code.appendSlice(allocator, "dirname(");
        try code.appendSlice(allocator, "__DIR__");
        for (0..depth) |_| try code.append(allocator, ')');
    }

    const rest = after(to, common_slash.len);
    if (rest.len > 0) {
        try code.append(allocator, '.');
        try code.appendSlice(allocator, try phpString(
            allocator,
            try std.fmt.allocPrint(allocator, "/{s}", .{rest}),
        ));
    }
    return code.toOwnedSlice(allocator);
}

/// The relative path from `from` to `to`, as a plain string.
///
/// `Composer\Util\Filesystem::findShortestPath`. Distinct from
/// `shortestPathCode` in more than its return type: it appends a `dummy_file`
/// segment in `$directories` mode instead of adding one to a depth count, it
/// short-circuits siblings to `./name`, and it does NOT have the
/// `$sourcePathDepth > 1` bail-out on `.`-vs-`/` — so the two functions
/// genuinely disagree on some inputs, and neither can be written in terms of
/// the other.
///
/// `installed.php` records the root package's `install_path` with this, which
/// is why `vendor-dir: lib/vendor` turns `__DIR__ . '/../../'` into
/// `__DIR__ . '/../../../'`.
pub fn shortestPath(
    allocator: std.mem.Allocator,
    from_raw: []const u8,
    to_raw: []const u8,
    directories: bool,
) ![]const u8 {
    var from = try normalise(allocator, from_raw);
    const to = try normalise(allocator, to_raw);

    if (directories) {
        // `rtrim($from, '/') . '/dummy_file'` — and PHP's rtrim will happily
        // reduce "/" to the empty string, which is how the root directory
        // becomes "/dummy_file" rather than "//dummy_file".
        from = try std.fmt.allocPrint(allocator, "{s}/dummy_file", .{
            std.mem.trimEnd(u8, from, "/"),
        });
    }

    if (std.mem.eql(u8, phpDirname(from), phpDirname(to))) {
        return std.fmt.allocPrint(allocator, "./{s}", .{std.fs.path.basename(to)});
    }

    var common: []const u8 = to;
    while (true) {
        const with_slash = try std.fmt.allocPrint(allocator, "{s}/", .{common});
        const from_slash = try std.fmt.allocPrint(allocator, "{s}/", .{from});
        if (std.mem.startsWith(u8, from_slash, with_slash)) break;
        if (std.mem.eql(u8, common, "/")) break;
        common = phpDirname(common);
    }

    if (!std.mem.startsWith(u8, from, common)) return to;

    const common_slash = if (std.mem.endsWith(u8, common, "/"))
        common
    else
        try std.fmt.allocPrint(allocator, "{s}/", .{common});

    const depth = std.mem.count(u8, after(from, common_slash.len), "/");
    if (std.mem.eql(u8, common_slash, "/") and depth > 1) return to;

    var out: std.ArrayList(u8) = .empty;
    for (0..depth) |_| try out.appendSlice(allocator, "../");
    try out.appendSlice(allocator, after(to, common_slash.len));
    if (out.items.len == 0) return "./";
    return out.toOwnedSlice(allocator);
}

/// `dirname($p)`. Zig's returns null where PHP returns `"/"` or `"."`, and the
/// difference is not cosmetic: `dirname("/")` deciding to be null instead of
/// `"/"` makes a sibling comparison at the filesystem root fail, and the walk
/// up to a common ancestor never terminates where PHP's does.
fn phpDirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse
        if (path.len > 0 and path[0] == '/') "/" else ".";
}

/// `substr($s, $n)` — PHP yields the empty string past the end rather than
/// erroring, and both call sites reach it: when the common ancestor IS the
/// target (`to = "/p"`, ancestor `"/p/"`), the offset is one past the length.
fn after(s: []const u8, n: usize) []const u8 {
    return if (n >= s.len) "" else s[n..];
}

/// `var_export($s, true)` for a string: single quotes, `\\` and `\'` escaped,
/// everything else verbatim.
fn phpString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\\' or c == '\'') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the default layout is vendor/ and vendor/bin/" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const l = try resolve(arena.allocator(), null, "/srv/app", .{});
    try testing.expectEqualStrings("/srv/app", l.root);
    try testing.expectEqualStrings("/srv/app/vendor", l.vendor);
    try testing.expectEqualStrings("/srv/app/vendor/bin", l.bin);
    try testing.expect(l.isDefault());
}

test "config.vendor-dir moves both directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const l = try resolve(arena.allocator(), null, "/srv/app", .{ .config_vendor_dir = "lib/vendor" });
    try testing.expectEqualStrings("/srv/app/lib/vendor", l.vendor);
    // bin-dir defaults to {$vendor-dir}/bin, so it follows.
    try testing.expectEqualStrings("/srv/app/lib/vendor/bin", l.bin);
    try testing.expect(!l.isDefault());
}

test "config.bin-dir is independent, and interpolates {$vendor-dir}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const outside = try resolve(a, null, "/srv/app", .{
        .config_vendor_dir = "lib/vendor",
        .config_bin_dir = "bin",
    });
    try testing.expectEqualStrings("/srv/app/bin", outside.bin);

    const inside = try resolve(a, null, "/srv/app", .{ .config_bin_dir = "{$vendor-dir}/binaries" });
    try testing.expectEqualStrings("/srv/app/vendor/binaries", inside.bin);

    const absolute_bin = try resolve(a, null, "/srv/app", .{ .config_bin_dir = "/usr/local/bin" });
    try testing.expectEqualStrings("/usr/local/bin", absolute_bin.bin);
}

test "a trailing slash is trimmed, as Composer trims it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const l = try resolve(arena.allocator(), null, "/srv/app", .{ .config_vendor_dir = "deps/" });
    try testing.expectEqualStrings("/srv/app/deps", l.vendor);
}

test "normalise resolves .. and . textually" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("/srv/app", try normalise(a, "/srv/app/lib/.."));
    try testing.expectEqualStrings("/srv/app/x", try normalise(a, "/srv//./app/x"));
    try testing.expectEqualStrings("/", try normalise(a, "/.."));
    try testing.expectEqualStrings("a/b", try normalise(a, "a/./b"));
}

// The four expectations below are the strings Composer 2.10.3 actually wrote,
// recorded from generated proxies rather than derived from the algorithm.
test "shortestPathCode reproduces Composer's generated path expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // vendor/bin/php-parse → vendor/autoload.php
    try testing.expectEqualStrings(
        "__DIR__ . '/..'.'/autoload.php'",
        try shortestPathCode(a, "/p/vendor/bin", "/p/vendor/autoload.php", true, true),
    );
    // vendor/binaries/php-parse → the package's script, one level up
    try testing.expectEqualStrings(
        "__DIR__ . '/..'.'/nikic/php-parser/bin/php-parse'",
        try shortestPathCode(a, "/p/vendor/binaries", "/p/vendor/nikic/php-parser/bin/php-parse", true, true),
    );
    // bin/ at the project root, vendor at lib/vendor
    try testing.expectEqualStrings(
        "__DIR__ . '/..'.'/lib/vendor/autoload.php'",
        try shortestPathCode(a, "/p/bin", "/p/lib/vendor/autoload.php", true, true),
    );
    try testing.expectEqualStrings(
        "__DIR__ . '/..'.'/lib/vendor/nikic/php-parser/bin/php-parse'",
        try shortestPathCode(a, "/p/bin", "/p/lib/vendor/nikic/php-parser/bin/php-parse", true, true),
    );
}

test "shortestPathCode gives up on relativity rather than climb to the root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // /usr/local/bin → /srv/app/vendor/autoload.php: common ancestor is `/`
    // and the source is three deep, so Composer emits the absolute path.
    try testing.expectEqualStrings(
        "'/srv/app/vendor/autoload.php'",
        try shortestPathCode(a, "/usr/local/bin", "/srv/app/vendor/autoload.php", true, true),
    );
}

test "a target underneath the source is __DIR__ plus the remainder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "__DIR__ . '/composer/installed.php'",
        try shortestPathCode(arena.allocator(), "/p/vendor", "/p/vendor/composer/installed.php", true, true),
    );
}

// The corpus is 832 rows generated by calling
// `Composer\Util\Filesystem::findShortestPathCode` itself, over every pairing
// of 13 source directories with 16 targets, in both `$directories` and
// `$staticCode` modes. It
// exists because this function's output is PHP that ships inside a generated
// file: a wrong answer is not a failed assertion, it is a `require` of a path
// that does not exist, discovered by whoever runs the binary.
test "shortestPathCode agrees with Composer over the recorded corpus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = @embedFile("testdata/pathcode_corpus.json");
    const rows = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});

    var checked: usize = 0;
    for (rows.array.items) |row| {
        const o = row.object;
        const got = try shortestPathCode(
            a,
            o.get("from").?.string,
            o.get("to").?.string,
            o.get("directories").?.bool,
            o.get("static").?.bool,
        );
        const want = o.get("code").?.string;
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("from={s} to={s} dirs={} static={}\n", .{
                o.get("from").?.string,      o.get("to").?.string,
                o.get("directories").?.bool, o.get("static").?.bool,
            });
            return e;
        };
        // The plain-string form travels in the same corpus rather than a
        // second one: the two functions look interchangeable and are not, so
        // every row asserts both and the disagreements are on the record.
        const path = try shortestPath(a, o.get("from").?.string, o.get("to").?.string, o.get("directories").?.bool);
        testing.expectEqualStrings(o.get("path").?.string, path) catch |e| {
            std.debug.print("findShortestPath from={s} to={s} dirs={}\n", .{
                o.get("from").?.string, o.get("to").?.string, o.get("directories").?.bool,
            });
            return e;
        };

        checked += 1;
    }
    try testing.expectEqual(@as(usize, 832), checked);
}

test "an identical path is __DIR__ or __FILE__ by kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("__DIR__", try shortestPathCode(a, "/p/x", "/p/x", true, true));
    try testing.expectEqualStrings("__FILE__", try shortestPathCode(a, "/p/x", "/p/x", false, true));
}
