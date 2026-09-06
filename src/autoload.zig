//! Autoloader generation — a native `composer dump-autoload`.
//!
//! Emits the five data files Composer's `ClassLoader` consumes:
//!
//!     autoload_psr4.php        prefix        → directories
//!     autoload_namespaces.php  psr-0 prefix  → directories
//!     autoload_classmap.php    class         → file
//!     autoload_files.php       identifier    → file, included eagerly
//!     autoload_static.php      all of the above, pre-baked for opcache
//!
//! It deliberately does NOT emit `autoload.php`, `autoload_real.php` or
//! `ClassLoader.php`. Those are Composer's runtime, they do not change when a
//! package is added, and rewriting them would mean maintaining a copy of
//! someone else's loader against the day it changes. Regenerating only the DATA
//! is both the whole of what a dump-autoload does in practice and the part that
//! cannot break the loader.
//!
//! The output is byte-comparable with Composer's, which is the point: it makes
//! the claim "this generator is correct" testable by diff against the tool it
//! replaces, rather than by assertion. Composer's own ordering rules are
//! therefore reproduced exactly —
//!
//!     psr-4 / psr-0   prefix DESCENDING   (Composer krsorts, so that a longer,
//!                                          more specific prefix is written
//!                                          before the shorter one it extends)
//!     classmap        class ASCENDING     (ksort)
//!     files           DEPENDENCY order    (a package's bootstrap runs after the
//!                                          bootstraps it relies on; the root
//!                                          package is last)

const std = @import("std");
const manifest = @import("manifest.zig");
const classmap = @import("classmap.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Manifest = manifest.Manifest;

/// Which of the two anchors a generated path hangs off.
///
/// Composer writes `$vendorDir . '/x'` for an installed package and
/// `$baseDir . '/x'` for the root project, and the static file spells the same
/// two as `__DIR__ . '/..'` and `__DIR__ . '/../..'`. Keeping the anchor
/// symbolic until emission is what lets one path be written both ways.
pub const Anchor = enum { vendor, base };

pub const Path = struct {
    anchor: Anchor,
    /// Always begins with '/'.
    rel: []const u8,
};

pub const Psr = struct {
    prefix: []const u8,
    paths: []const Path,
};

pub const FileEntry = struct {
    id: []const u8,
    path: Path,
};

pub const ClassEntry = struct {
    fqcn: []const u8,
    path: Path,
};

/// Everything the five files are rendered from.
pub const Plan = struct {
    psr4: []const Psr,
    psr0: []const Psr,
    classes: []const ClassEntry,
    files: []const FileEntry,

    /// The suffix on `ComposerStaticInit…`. Composer derives it from the root
    /// package name plus the vendor path; any stable value works, and stability
    /// is what matters — a changing class name leaves the previous static file
    /// resident in opcache under a name nothing loads.
    hash: []const u8,
};

pub const Options = struct {
    /// Include `autoload-dev` rules (Composer's default; `--no-dev` drops them).
    dev: bool = true,
    /// Scan psr-4/psr-0 directories into the classmap as well (`-o`).
    optimize: bool = false,
};

/// Build the plan for the project rooted at `base_dir` with `vendor_dir`.
pub fn plan(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: []const u8,
    vendor_dir: []const u8,
    root: Manifest,
    installed: []const Manifest,
    opts: Options,
) !Plan {
    var psr4: std.ArrayList(Psr) = .empty;
    var psr0: std.ArrayList(Psr) = .empty;
    var files: std.ArrayList(FileEntry) = .empty;
    var classes: std.ArrayList(ClassEntry) = .empty;

    // Composer walks the package list in TWO different orders, and the
    // difference is deliberate on its part (AutoloadGenerator::parseAutoloads):
    //
    //   files            sorted, root LAST   — a bootstrap runs after the
    //                                          bootstraps it depends on
    //   psr-4/0, classmap REVERSED, root FIRST — so the root package's rules
    //                                          take precedence over a
    //                                          dependency's
    //
    // Reproducing both is what makes the output comparable byte for byte, and
    // the precedence half of it is load-bearing rather than cosmetic.

    // Composer injects its own runtime class into every classmap it writes, so
    // that `Composer\InstalledVersions` resolves without a psr-4 rule for it.
    //
    // Registered BEFORE the scan because Composer's `addClass` OVERWRITES,
    // whereas duplicates here are resolved first-wins. Under `-o` the scan of
    // composer/composer's own psr-4 root finds a second, different
    // `Composer\InstalledVersions` inside the vendored Composer source, and
    // that copy is not the one the loader must use.
    try classes.append(allocator, .{
        .fqcn = "Composer\\InstalledVersions",
        .path = .{ .anchor = .vendor, .rel = "/composer/InstalledVersions.php" },
    });

    const sorted = try sortPackages(allocator, installed);

    for (sorted) |pkg| {
        try collectFiles(allocator, pkg, .vendor, try packageDir(allocator, pkg), false, opts, &files);
    }
    try collectFiles(allocator, root, .base, "", true, opts, &files);

    try collectRules(allocator, io, base_dir, vendor_dir, root, .base, "", true, opts, &psr4, &psr0, &classes);
    var i = sorted.len;
    while (i > 0) {
        i -= 1;
        const pkg = sorted[i];
        try collectRules(allocator, io, base_dir, vendor_dir, pkg, .vendor, try packageDir(allocator, pkg), false, opts, &psr4, &psr0, &classes);
    }

    // Composer merges rules for a prefix declared by more than one package,
    // keeping the order the packages were walked in.
    const merged4 = try mergeByPrefix(allocator, psr4.items);
    const merged0 = try mergeByPrefix(allocator, psr0.items);

    std.mem.sort(Psr, merged4, {}, prefixDescending);
    std.mem.sort(Psr, merged0, {}, prefixDescending);
    std.mem.sort(ClassEntry, classes.items, {}, classAscending);

    return .{
        .psr4 = merged4,
        .psr0 = merged0,
        .classes = try dedupeClasses(allocator, classes.items),
        .files = try files.toOwnedSlice(allocator),
        .hash = try staticSuffix(allocator, io, vendor_dir, base_dir, root),
    };
}

/// The autoload blocks that apply to a package, written into `buf`.
///
/// `autoload-dev` belongs to the ROOT package only — a dependency's dev rules
/// are its own test scaffolding and Composer never registers them.
///
/// The buffer is the CALLER's because the obvious spelling — returning
/// `&.{ pkg.autoload, pkg.autoload_dev }` — takes the address of a temporary
/// that dies with this function, and the resulting slice segfaults at the first
/// read. Zig allows it; nothing warns.
fn blocksOf(
    pkg: Manifest,
    is_root: bool,
    opts: Options,
    buf: *[2]manifest.Autoload,
) []const manifest.Autoload {
    buf[0] = pkg.autoload;
    if (is_root and opts.dev) {
        buf[1] = pkg.autoload_dev;
        return buf[0..2];
    }
    return buf[0..1];
}

/// Collect one package's eagerly-included `files`.
fn collectFiles(
    allocator: std.mem.Allocator,
    pkg: Manifest,
    anchor: Anchor,
    pkg_rel: []const u8,
    is_root: bool,
    opts: Options,
    files: *std.ArrayList(FileEntry),
) !void {
    var buf: [2]manifest.Autoload = undefined;
    for (blocksOf(pkg, is_root, opts, &buf)) |block| {
        for (block.files) |f| {
            try files.append(allocator, .{
                .id = try pkg.fileIdentifier(allocator, f),
                .path = .{ .anchor = anchor, .rel = try joinRel(allocator, pkg_rel, f) },
            });
        }
    }
}

/// Collect one package's psr-4, psr-0 and classmap rules.
fn collectRules(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: []const u8,
    vendor_dir: []const u8,
    pkg: Manifest,
    anchor: Anchor,
    pkg_rel: []const u8,
    is_root: bool,
    opts: Options,
    psr4: *std.ArrayList(Psr),
    psr0: *std.ArrayList(Psr),
    classes: *std.ArrayList(ClassEntry),
) !void {
    var buf: [2]manifest.Autoload = undefined;
    const blocks = blocksOf(pkg, is_root, opts, &buf);

    // The exclusion list is resolved to absolute prefixes once, because it is
    // consulted against every file the classmap scan visits.
    const exclusions = try absExclusions(allocator, base_dir, vendor_dir, anchor, pkg_rel, blocks);

    for (blocks) |block| {
        for (block.psr4) |rule| {
            try psr4.append(allocator, .{
                .prefix = rule.prefix,
                .paths = try relPaths(allocator, anchor, pkg_rel, rule.paths),
            });
        }
        for (block.psr0) |rule| {
            try psr0.append(allocator, .{
                .prefix = rule.prefix,
                .paths = try relPaths(allocator, anchor, pkg_rel, rule.paths),
            });
        }

        // `classmap` entries are always scanned; psr-4/psr-0 roots only under -o.
        for (block.classmap) |entry| {
            try scanInto(allocator, io, base_dir, vendor_dir, anchor, pkg_rel, entry, exclusions, .classmap, classes);
        }
        if (opts.optimize) {
            for (block.psr4) |rule| for (rule.paths) |p| {
                try scanInto(allocator, io, base_dir, vendor_dir, anchor, pkg_rel, p, exclusions, .{ .psr = .{ .kind = .psr4, .prefix = rule.prefix } }, classes);
            };
            for (block.psr0) |rule| for (rule.paths) |p| {
                try scanInto(allocator, io, base_dir, vendor_dir, anchor, pkg_rel, p, exclusions, .{ .psr = .{ .kind = .psr0, .prefix = rule.prefix } }, classes);
            };
        }
    }
}

/// How a scanned directory's classes are filtered.
///
/// A `classmap` rule takes everything it finds. A psr-0/psr-4 root does NOT:
/// Composer keeps only classes whose name maps back to the file they were found
/// in, and drops the rest as PSR violations. Two classes in one file — common
/// enough in real packages — means the second is deliberately absent from the
/// optimized classmap, so it keeps resolving through the psr-4 rule instead.
/// Skipping this filter produces a classmap that is a strict superset of
/// Composer's, which sounds harmless and is not: it silently changes which file
/// a class resolves from.
const ScanMode = union(enum) {
    classmap,
    psr: struct { kind: enum { psr0, psr4 }, prefix: []const u8 },
};

fn scanInto(
    allocator: std.mem.Allocator,
    io: Io,
    base_dir: []const u8,
    vendor_dir: []const u8,
    anchor: Anchor,
    pkg_rel: []const u8,
    entry: []const u8,
    exclusions: []const []const u8,
    mode: ScanMode,
    classes: *std.ArrayList(ClassEntry),
) !void {
    const rel = try joinRel(allocator, pkg_rel, entry);
    const anchor_dir = if (anchor == .vendor) vendor_dir else base_dir;
    const abs = try std.fmt.allocPrint(allocator, "{s}{s}", .{ anchor_dir, rel });

    var found: std.ArrayList(classmap.Found) = .empty;
    try classmap.scanTree(allocator, io, abs, exclusions, &found);

    // scanTree walks a file's declarations consecutively, so a run of equal
    // paths is one file — which is the unit Composer's filter works on.
    var i: usize = 0;
    while (i < found.items.len) {
        var j = i;
        while (j < found.items.len and std.mem.eql(u8, found.items[j].path, found.items[i].path)) j += 1;
        try acceptFile(allocator, found.items[i..j], abs, anchor, anchor_dir, mode, classes);
        i = j;
    }
}

/// Apply the psr conformance rule to the classes found in ONE file.
fn acceptFile(
    allocator: std.mem.Allocator,
    file_classes: []const classmap.Found,
    base_abs: []const u8,
    anchor: Anchor,
    anchor_dir: []const u8,
    mode: ScanMode,
    classes: *std.ArrayList(ClassEntry),
) !void {
    const path = file_classes[0].path;
    if (!std.mem.startsWith(u8, path, anchor_dir)) return;
    const anchored: Path = .{ .anchor = anchor, .rel = path[anchor_dir.len..] };

    const psr = switch (mode) {
        .classmap => {
            for (file_classes) |f| try classes.append(allocator, .{ .fqcn = f.fqcn, .path = anchored });
            return;
        },
        .psr => |p| p,
    };

    // The file's path below the rule's directory, extension removed —
    // `Bridge/Symfony/LetMigrateBundle` for a class expected to be named
    // `<prefix>Bridge\Symfony\LetMigrateBundle`.
    if (path.len <= base_abs.len) return;
    var real_sub = path[base_abs.len..];
    real_sub = std.mem.trimStart(u8, real_sub, "/");
    if (std.mem.lastIndexOfScalar(u8, real_sub, '.')) |dot| real_sub = real_sub[0..dot];

    var valid: std.ArrayList(ClassEntry) = .empty;
    for (file_classes) |f| {
        const sub_path = (try expectedSubPath(allocator, f.fqcn, psr.prefix, psr.kind == .psr0)) orelse continue;
        if (std.mem.eql(u8, sub_path, real_sub)) {
            try valid.append(allocator, .{ .fqcn = f.fqcn, .path = anchored });
        }
    }

    // Composer's rule is all-or-nothing per file: with no conforming class it
    // records violations and contributes nothing, rather than half the file.
    if (valid.items.len == 0) return;
    try classes.appendSlice(allocator, valid.items);
}

/// The path a class name implies under its psr rule, or null when it cannot
/// belong to that rule at all.
fn expectedSubPath(
    allocator: std.mem.Allocator,
    fqcn: []const u8,
    prefix: []const u8,
    psr0: bool,
) !?[]const u8 {
    if (prefix.len > 0 and !std.mem.startsWith(u8, fqcn, prefix)) return null;
    const sub = if (prefix.len > 0) fqcn[prefix.len..] else fqcn;

    var out = try allocator.alloc(u8, sub.len);
    if (psr0) {
        // psr-0 turns underscores in the CLASS name (not the namespace) into
        // directory separators as well.
        const split = std.mem.lastIndexOfScalar(u8, sub, '\\');
        for (sub, 0..) |c, i| {
            const in_class_name = if (split) |at| i > at else true;
            out[i] = if (c == '\\' or (in_class_name and c == '_')) '/' else c;
        }
    } else {
        for (sub, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    }
    return out;
}

fn absExclusions(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    vendor_dir: []const u8,
    anchor: Anchor,
    pkg_rel: []const u8,
    blocks: []const manifest.Autoload,
) ![]const []const u8 {
    const anchor_dir = if (anchor == .vendor) vendor_dir else base_dir;

    var out: std.ArrayList([]const u8) = .empty;
    for (blocks) |b| for (b.exclude) |e| {
        // Composer's exclusions are glob-ish (`**/database/migrations/**`). A
        // full glob engine is not warranted: every real use is "a path segment
        // anywhere below the package", so the leading wildcard is stripped and
        // the rest matched as a path prefix. A pattern this cannot express is
        // ignored rather than approximated, because an exclusion that matches
        // too MUCH silently drops classes from the map.
        const trimmed = std.mem.trim(u8, e, "*/");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '*') != null) continue;

        const rel = try joinRel(allocator, pkg_rel, trimmed);
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ anchor_dir, rel }));
    };
    return out.toOwnedSlice(allocator);
}

/// The package's directory, anchored at `$vendorDir`.
///
/// `installed.json` spells `install-path` relative to `vendor/composer/`, and
/// BOTH directions occur: `../guzzlehttp/guzzle` climbs out to
/// `vendor/guzzlehttp/guzzle`, while Composer's own packages sit alongside it as
/// `./xdebug-handler` = `vendor/composer/xdebug-handler`. Stripping a leading
/// `../` therefore gets the first right and the second silently wrong, so the
/// path is resolved segment by segment from `composer/` instead.
fn packageDir(allocator: std.mem.Allocator, pkg: Manifest) ![]const u8 {
    if (pkg.install_path.len == 0) {
        // No install-path recorded: Composer's default layout is vendor/<name>.
        if (pkg.name.len == 0) return "";
        return std.fmt.allocPrint(allocator, "/{s}", .{pkg.name});
    }

    var segments: std.ArrayList([]const u8) = .empty;
    try segments.append(allocator, "composer");

    var it = std.mem.tokenizeScalar(u8, pkg.install_path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(allocator, seg);
    }

    var out: std.ArrayList(u8) = .empty;
    for (segments.items) |seg| {
        try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return out.toOwnedSlice(allocator);
}

fn relPaths(
    allocator: std.mem.Allocator,
    anchor: Anchor,
    pkg_rel: []const u8,
    paths: []const []const u8,
) ![]const Path {
    var out: std.ArrayList(Path) = .empty;
    for (paths) |p| {
        try out.append(allocator, .{ .anchor = anchor, .rel = try joinRel(allocator, pkg_rel, p) });
    }
    return out.toOwnedSlice(allocator);
}

/// Join a package-relative sub-path onto the package's own anchored path.
///
/// An empty sub-path is the package directory itself — a real psr-4 spelling
/// (`{"Foo\\": ""}`), and one that must not produce a trailing slash, because
/// Composer's loader concatenates directly onto it.
fn joinRel(allocator: std.mem.Allocator, pkg_rel: []const u8, sub: []const u8) ![]const u8 {
    const s = std.mem.trim(u8, sub, "/");
    if (s.len == 0) return if (pkg_rel.len == 0) try allocator.dupe(u8, "/") else pkg_rel;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_rel, s });
}

/// Composer's package order — `Composer\Util\PackageSorter::sortPackages`.
///
/// NOT a topological sort, and the difference is visible in the output, so it is
/// reproduced rather than approximated. Each package gets a WEIGHT computed from
/// the packages that require it:
///
///     weight(p) = - Σ over each user u of p:  (1 - weight(u))
///
/// so a package many things depend on sinks to a large negative weight and sorts
/// first. Packages of equal weight are ordered by `strnatcasecmp` on the name.
/// A requirement cycle returns 0 for the package currently being computed, which
/// is what stops the recursion.
fn sortPackages(allocator: std.mem.Allocator, packages: []const Manifest) ![]const Manifest {
    const weights = try allocator.alloc(i64, packages.len);
    const state = try allocator.alloc(State, packages.len);
    @memset(state, .unvisited);

    for (packages, 0..) |_, i| {
        weights[i] = importance(packages, weights, state, i);
    }

    const Item = struct { index: usize, weight: i64 };
    var items = try allocator.alloc(Item, packages.len);
    for (packages, 0..) |_, i| items[i] = .{ .index = i, .weight = weights[i] };

    const Ctx = struct {
        pkgs: []const Manifest,
        fn lessThan(ctx: @This(), a: Item, b: Item) bool {
            if (a.weight != b.weight) return a.weight < b.weight;
            return natCaseLess(ctx.pkgs[a.index].name, ctx.pkgs[b.index].name);
        }
    };
    // A STABLE sort, because Composer's usort tie-break is a total order on the
    // name and ours must not reorder equal keys differently.
    std.mem.sortUnstable(Item, items, Ctx{ .pkgs = packages }, Ctx.lessThan);

    var out = try allocator.alloc(Manifest, packages.len);
    for (items, 0..) |item, i| out[i] = packages[item.index];
    return out;
}

const State = enum { unvisited, computing, done };

/// The recursive half of Composer's weighting, memoised through `state`.
fn importance(packages: []const Manifest, weights: []i64, state: []State, target: usize) i64 {
    switch (state[target]) {
        .done => return weights[target],
        // A cycle contributes nothing rather than diverging — Composer's
        // `if (isset($computing[$name])) return 0;`.
        .computing => return 0,
        .unvisited => {},
    }
    state[target] = .computing;

    var weight: i64 = 0;
    const name = packages[target].name;
    for (packages, 0..) |user, i| {
        if (i == target) continue;
        if (!requires(user, name)) continue;
        weight -= 1 - importance(packages, weights, state, i);
    }

    weights[target] = weight;
    state[target] = .done;
    return weight;
}

fn requires(pkg: Manifest, name: []const u8) bool {
    for (pkg.require) |dep| {
        if (std.mem.eql(u8, dep.name, name)) return true;
    }
    return false;
}

/// PHP's `strnatcasecmp` as a less-than: digit runs compare NUMERICALLY.
///
/// Needed for real ordering, not pedantry — `symfony/polyfill-php73`,
/// `php80` and `php81` are ordered by the number, and a plain byte compare puts
/// `php8` after `php73`.
fn natCaseLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);

        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            // Skip leading zeros, then compare run lengths, then digits.
            while (i < a.len and a[i] == '0') i += 1;
            while (j < b.len and b[j] == '0') j += 1;

            const a_start = i;
            const b_start = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;

            const a_run = a[a_start..i];
            const b_run = b[b_start..j];
            if (a_run.len != b_run.len) return a_run.len < b_run.len;
            if (!std.mem.eql(u8, a_run, b_run)) return std.mem.order(u8, a_run, b_run) == .lt;
            continue;
        }

        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    return (a.len - i) < (b.len - j);
}

/// Fold rules sharing a prefix into one entry, preserving directory order.
fn mergeByPrefix(allocator: std.mem.Allocator, rules: []const Psr) ![]Psr {
    var out: std.ArrayList(Psr) = .empty;

    for (rules) |rule| {
        var hit: ?usize = null;
        for (out.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.prefix, rule.prefix)) {
                hit = i;
                break;
            }
        }
        if (hit) |i| {
            var merged: std.ArrayList(Path) = .empty;
            try merged.appendSlice(allocator, out.items[i].paths);
            try merged.appendSlice(allocator, rule.paths);
            out.items[i].paths = try merged.toOwnedSlice(allocator);
        } else {
            try out.append(allocator, rule);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// First declaration of a class wins, matching Composer, which keeps the first
/// and warns about the rest.
fn dedupeClasses(allocator: std.mem.Allocator, sorted: []const ClassEntry) ![]const ClassEntry {
    var out: std.ArrayList(ClassEntry) = .empty;
    for (sorted) |c| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1].fqcn, c.fqcn)) continue;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn prefixDescending(_: void, a: Psr, b: Psr) bool {
    return std.mem.order(u8, a.prefix, b.prefix) == .gt;
}

fn classAscending(_: void, a: ClassEntry, b: ClassEntry) bool {
    return std.mem.order(u8, a.fqcn, b.fqcn) == .lt;
}

fn nameAscending(_: void, a: Manifest, b: Manifest) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// The suffix on `ComposerStaticInit…`, taken from the autoloader already in
/// place.
///
/// This MUST be preserved, not invented. Composer generates the suffix randomly
/// (`md5(uniqid())`) the first time and thereafter recovers it by regex from
/// `vendor/autoload.php` — and `autoload_real.php`, which this generator does
/// not rewrite, names the class literally:
///
///     \Composer\Autoload\ComposerStaticInit73f3771ab…::getInitializer($loader)
///
/// Emitting a static file under any other name leaves that call referring to a
/// class that no longer exists, and the project fatals on its very next
/// autoload. The fallback is derived from the root package rather than random so
/// that a vendor tree with no readable autoload.php still regenerates
/// reproducibly.
fn staticSuffix(allocator: std.mem.Allocator, io: Io, vendor_dir: []const u8, base_dir: []const u8, root: Manifest) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ vendor_dir, "autoload.php" });
    if (Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch null) |content| {
        const marker = "ComposerAutoloaderInit";
        if (std.mem.indexOf(u8, content, marker)) |at| {
            const rest = content[at + marker.len ..];
            var end: usize = 0;
            while (end < rest.len and rest[end] != ':' and !std.ascii.isWhitespace(rest[end])) end += 1;
            if (end > 0) return allocator.dupe(u8, rest[0..end]);
        }
    }

    var digest: [16]u8 = undefined;
    var h = std.crypto.hash.Md5.init(.{});
    h.update(root.name);
    h.update(":");
    h.update(base_dir);
    h.final(&digest);
    return std.fmt.allocPrint(allocator, "{x}", .{&digest});
}

// ── rendering ─────────────────────────────────────────────────────────────────

const header_fmt =
    \\<?php
    \\
    \\// {s} @generated by Composer
    \\
    \\$vendorDir = dirname(__DIR__);
    \\$baseDir = dirname($vendorDir);
    \\
    \\return array(
    \\
;

/// The five generated files, named so a caller can render one at a time.
pub const Which = enum {
    psr4,
    psr0,
    classmap,
    files,
    static,

    pub fn fileName(self: Which) []const u8 {
        return switch (self) {
            .psr4 => "autoload_psr4.php",
            .psr0 => "autoload_namespaces.php",
            .classmap => "autoload_classmap.php",
            .files => "autoload_files.php",
            .static => "autoload_static.php",
        };
    }
};

/// Render one file's contents.
///
/// Public so `--check` can compare against disk without writing, which is how
/// the parity claim in this file's header is actually verified.
pub fn renderFor(allocator: std.mem.Allocator, p: Plan, which: Which) ![]const u8 {
    return switch (which) {
        .psr4 => renderPsr(allocator, which.fileName(), p.psr4),
        .psr0 => renderPsr(allocator, which.fileName(), p.psr0),
        .classmap => renderClassmap(allocator, p.classes),
        .files => renderFiles(allocator, p.files),
        .static => renderStatic(allocator, p),
    };
}

/// Write all five files into `<vendor_dir>/composer/`.
pub fn write(allocator: std.mem.Allocator, io: Io, vendor_dir: []const u8, p: Plan) !void {
    const dir = try std.fs.path.join(allocator, &.{ vendor_dir, "composer" });

    inline for (std.meta.fields(Which)) |f| {
        const which: Which = @enumFromInt(f.value);
        try writeFile(allocator, io, dir, which.fileName(), try renderFor(allocator, p, which));
    }
}

fn writeFile(allocator: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, body: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    const util = @import("util.zig");
    try util.writeFileAtomic(io, path, body);
}

fn renderPsr(allocator: std.mem.Allocator, name: []const u8, rules: []const Psr) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, header_fmt, .{name});

    for (rules) |rule| {
        try out.appendSlice(allocator, "    '");
        try appendPhpSingle(allocator, &out, rule.prefix);
        try out.appendSlice(allocator, "' => array(");
        for (rule.paths, 0..) |path, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try appendDollarPath(allocator, &out, path);
        }
        try out.appendSlice(allocator, "),\n");
    }

    try out.appendSlice(allocator, ");\n");
    return out.toOwnedSlice(allocator);
}

fn renderClassmap(allocator: std.mem.Allocator, classes: []const ClassEntry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, header_fmt, .{"autoload_classmap.php"});

    for (classes) |c| {
        try out.appendSlice(allocator, "    '");
        try appendPhpSingle(allocator, &out, c.fqcn);
        try out.appendSlice(allocator, "' => ");
        try appendDollarPath(allocator, &out, c.path);
        try out.appendSlice(allocator, ",\n");
    }

    try out.appendSlice(allocator, ");\n");
    return out.toOwnedSlice(allocator);
}

fn renderFiles(allocator: std.mem.Allocator, files: []const FileEntry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, header_fmt, .{"autoload_files.php"});

    for (files) |f| {
        try out.print(allocator, "    '{s}' => ", .{f.id});
        try appendDollarPath(allocator, &out, f.path);
        try out.appendSlice(allocator, ",\n");
    }

    try out.appendSlice(allocator, ");\n");
    return out.toOwnedSlice(allocator);
}

fn renderStatic(allocator: std.mem.Allocator, p: Plan) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.print(allocator,
        \\<?php
        \\
        \\// autoload_static.php @generated by Composer
        \\
        \\namespace Composer\Autoload;
        \\
        \\class ComposerStaticInit{s}
        \\{{
        \\
    , .{p.hash});

    if (p.files.len > 0) {
        try out.appendSlice(allocator, "    public static $files = array (\n");
        for (p.files) |f| {
            try out.print(allocator, "        '{s}' => ", .{f.id});
            try appendDirPath(allocator, &out, f.path);
            try out.appendSlice(allocator, ",\n");
        }
        try out.appendSlice(allocator, "    );\n\n");
    }

    try renderStaticPsr(allocator, &out, "prefixLengthsPsr4", "prefixDirsPsr4", p.psr4, true);
    try renderStaticPsr(allocator, &out, "prefixesPsr0", "", p.psr0, false);

    if (p.classes.len > 0) {
        try out.appendSlice(allocator, "    public static $classMap = array (\n");
        for (p.classes) |c| {
            try out.appendSlice(allocator, "        '");
            try appendPhpSingle(allocator, &out, c.fqcn);
            try out.appendSlice(allocator, "' => ");
            try appendDirPath(allocator, &out, c.path);
            try out.appendSlice(allocator, ",\n");
        }
        try out.appendSlice(allocator, "    );\n\n");
    }

    try out.print(allocator,
        \\    public static function getInitializer(ClassLoader $loader)
        \\    {{
        \\        return \Closure::bind(function () use ($loader) {{
        \\
    , .{});
    if (p.psr4.len > 0) {
        try out.print(allocator, "            $loader->prefixLengthsPsr4 = ComposerStaticInit{s}::$prefixLengthsPsr4;\n", .{p.hash});
        try out.print(allocator, "            $loader->prefixDirsPsr4 = ComposerStaticInit{s}::$prefixDirsPsr4;\n", .{p.hash});
    }
    if (p.psr0.len > 0) {
        try out.print(allocator, "            $loader->prefixesPsr0 = ComposerStaticInit{s}::$prefixesPsr0;\n", .{p.hash});
    }
    if (p.classes.len > 0) {
        try out.print(allocator, "            $loader->classMap = ComposerStaticInit{s}::$classMap;\n", .{p.hash});
    }
    try out.appendSlice(allocator,
        \\
        \\        }, null, ClassLoader::class);
        \\    }
        \\}
        \\
    );

    return out.toOwnedSlice(allocator);
}

/// PSR-4 static form is a two-level map keyed by first BYTE of the prefix, so
/// the loader can reject most prefixes with one array lookup. PSR-0's is keyed
/// by first byte then whole prefix, with no lengths.
fn renderStaticPsr(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    lengths_name: []const u8,
    dirs_name: []const u8,
    rules: []const Psr,
    with_lengths: bool,
) !void {
    if (rules.len == 0) return;

    if (with_lengths) {
        try out.print(allocator, "    public static ${s} = array (\n", .{lengths_name});
        var i: usize = 0;
        while (i < rules.len) {
            const letter = rules[i].prefix[0];
            try out.appendSlice(allocator, "        '");
            try appendPhpSingle(allocator, out, rules[i].prefix[0..1]);
            try out.appendSlice(allocator, "' =>\n        array (\n");
            while (i < rules.len and rules[i].prefix[0] == letter) : (i += 1) {
                try out.appendSlice(allocator, "            '");
                try appendPhpSingle(allocator, out, rules[i].prefix);
                try out.print(allocator, "' => {d},\n", .{rules[i].prefix.len});
            }
            try out.appendSlice(allocator, "        ),\n");
        }
        try out.appendSlice(allocator, "    );\n\n");

        try out.print(allocator, "    public static ${s} = array (\n", .{dirs_name});
        for (rules) |rule| {
            try out.appendSlice(allocator, "        '");
            try appendPhpSingle(allocator, out, rule.prefix);
            try out.appendSlice(allocator, "' =>\n        array (\n");
            for (rule.paths, 0..) |path, n| {
                try out.print(allocator, "            {d} => ", .{n});
                try appendDirPath(allocator, out, path);
                try out.appendSlice(allocator, ",\n");
            }
            try out.appendSlice(allocator, "        ),\n");
        }
        try out.appendSlice(allocator, "    );\n\n");
        return;
    }

    try out.print(allocator, "    public static ${s} = array (\n", .{lengths_name});
    var i: usize = 0;
    while (i < rules.len) {
        const letter = rules[i].prefix[0];
        try out.appendSlice(allocator, "        '");
        try appendPhpSingle(allocator, out, rules[i].prefix[0..1]);
        try out.appendSlice(allocator, "' =>\n        array (\n");
        while (i < rules.len and rules[i].prefix[0] == letter) : (i += 1) {
            try out.appendSlice(allocator, "            '");
            try appendPhpSingle(allocator, out, rules[i].prefix);
            try out.appendSlice(allocator, "' =>\n            array (\n");
            for (rules[i].paths, 0..) |path, n| {
                try out.print(allocator, "                {d} => ", .{n});
                try appendDirPath(allocator, out, path);
                try out.appendSlice(allocator, ",\n");
            }
            try out.appendSlice(allocator, "            ),\n");
        }
        try out.appendSlice(allocator, "        ),\n");
    }
    try out.appendSlice(allocator, "    );\n\n");
}

/// `$vendorDir . '/x'` — the form the non-static files use.
fn appendDollarPath(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: Path) !void {
    try out.appendSlice(allocator, switch (path.anchor) {
        .vendor => "$vendorDir . '",
        .base => "$baseDir . '",
    });
    try appendPhpSingle(allocator, out, path.rel);
    try out.appendSlice(allocator, "'");
}

/// `__DIR__ . '/..' . '/x'` — the form autoload_static.php uses, because it is
/// evaluated from `vendor/composer/` with no variables in scope.
fn appendDirPath(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: Path) !void {
    try out.appendSlice(allocator, switch (path.anchor) {
        .vendor => "__DIR__ . '/..' . '",
        .base => "__DIR__ . '/../..' . '",
    });
    try appendPhpSingle(allocator, out, path.rel);
    try out.appendSlice(allocator, "'");
}

/// Escape for a PHP single-quoted literal: only `\` and `'` are special.
fn appendPhpSingle(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c == '\\' or c == '\'') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "psr-4 rules render descending, with composer's path spelling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rules = [_]Psr{
        .{ .prefix = "Zed\\", .paths = &.{.{ .anchor = .base, .rel = "/src" }} },
        .{ .prefix = "Acme\\", .paths = &.{.{ .anchor = .vendor, .rel = "/acme/lib/src" }} },
    };
    const sorted = try a.dupe(Psr, &rules);
    std.mem.sort(Psr, sorted, {}, prefixDescending);

    const out = try renderPsr(a, "autoload_psr4.php", sorted);
    try testing.expect(std.mem.indexOf(u8, out, "'Zed\\\\' => array($baseDir . '/src'),") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'Acme\\\\' => array($vendorDir . '/acme/lib/src'),") != null);
    // Descending: Zed before Acme.
    try testing.expect(std.mem.indexOf(u8, out, "Zed").? < std.mem.indexOf(u8, out, "Acme").?);
}

test "install-path is rewritten relative to the vendor dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const dir = try packageDir(arena.allocator(), .{ .name = "guzzlehttp/guzzle", .install_path = "../guzzlehttp/guzzle" });
    try testing.expectEqualStrings("/guzzlehttp/guzzle", dir);

    // No install-path recorded → Composer's default vendor/<name> layout.
    const fallback = try packageDir(arena.allocator(), .{ .name = "acme/lib" });
    try testing.expectEqualStrings("/acme/lib", fallback);
}

test "the most depended-upon package sorts first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const pkgs = [_]Manifest{
        .{ .name = "a/app", .require = &.{ .{ .name = "b/lib", .constraint = "*" }, .{ .name = "php", .constraint = ">=8" } } },
        .{ .name = "b/lib", .require = &.{.{ .name = "c/core", .constraint = "*" }} },
        .{ .name = "c/core" },
    };
    const ordered = try sortPackages(arena.allocator(), &pkgs);

    // c/core is required by b/lib, which is required by a/app, so c sinks
    // furthest and a/app — required by nothing — stays at weight 0.
    try testing.expectEqualStrings("c/core", ordered[0].name);
    try testing.expectEqualStrings("b/lib", ordered[1].name);
    try testing.expectEqualStrings("a/app", ordered[2].name);
}

test "equal weights break the tie by natural, case-insensitive name order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Nothing requires anything: every weight is 0, so name order decides.
    const pkgs = [_]Manifest{
        .{ .name = "sym/polyfill-php80" },
        .{ .name = "sym/polyfill-php8" },
        .{ .name = "sym/polyfill-php73" },
        .{ .name = "Acme/Lib" },
    };
    const ordered = try sortPackages(arena.allocator(), &pkgs);

    try testing.expectEqualStrings("Acme/Lib", ordered[0].name);
    // Natural order compares the digit run as a number: 8 < 73 < 80.
    try testing.expectEqualStrings("sym/polyfill-php8", ordered[1].name);
    try testing.expectEqualStrings("sym/polyfill-php73", ordered[2].name);
    try testing.expectEqualStrings("sym/polyfill-php80", ordered[3].name);
}

test "a requirement cycle still emits every package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const pkgs = [_]Manifest{
        .{ .name = "x/one", .require = &.{.{ .name = "y/two", .constraint = "*" }} },
        .{ .name = "y/two", .require = &.{.{ .name = "x/one", .constraint = "*" }} },
    };
    const ordered = try sortPackages(arena.allocator(), &pkgs);
    try testing.expectEqual(@as(usize, 2), ordered.len);
}

test "file identifiers match composer's md5(name:path)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const m = Manifest{ .name = "guzzlehttp/guzzle" };
    const id = try m.fileIdentifier(arena.allocator(), "src/functions_include.php");
    try testing.expectEqualStrings("37a3dc5111fe8f707ab4c132ef1dbc62", id);
}

test "an empty psr-4 path means the package directory itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const joined = try joinRel(arena.allocator(), "/acme/lib", "");
    try testing.expectEqualStrings("/acme/lib", joined);
}
