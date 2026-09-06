//! Composer manifest model — `composer.json` and `vendor/composer/installed.json`.
//!
//! The shared vocabulary for every `hkm ppkg` subcommand, and deliberately the
//! FIRST thing written: phase 1 (autoload generation, zero-network test
//! environments) reads these structures off disk, and phase 2 (a Packagist
//! client and solver) produces the same structures from the network. Nothing
//! downstream should need to know which of the two filled them in.
//!
//! Parsing is lenient in one specific direction: an unknown or malformed field
//! yields the empty value rather than an error. These files are hand-edited, and
//! a plugin whose `autoload` block has a typo should lose that one rule, not
//! make `hkm ppkg autoload` refuse to run and leave the project with no
//! autoloader at all.

const std = @import("std");

const Io = std.Io;
const Dir = std.Io.Dir;

/// One `"prefix" => path(s)` entry from a psr-4 / psr-0 block.
///
/// Composer permits both a bare string and an array of strings on the right;
/// both are normalised to `paths` here so consumers never branch on it.
pub const NamespaceRule = struct {
    prefix: []const u8,
    paths: []const []const u8,
};

/// A package's `autoload` (or `autoload-dev`) block.
pub const Autoload = struct {
    psr4: []const NamespaceRule = &.{},
    psr0: []const NamespaceRule = &.{},
    classmap: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},

    pub const empty: Autoload = .{};

    /// Nothing to contribute to a generated autoloader.
    pub fn isEmpty(self: Autoload) bool {
        return self.psr4.len == 0 and self.psr0.len == 0 and
            self.classmap.len == 0 and self.files.len == 0;
    }
};

/// A `require` / `require-dev` entry: package name and version constraint.
pub const Dep = struct {
    name: []const u8,
    constraint: []const u8,

    /// A platform requirement (`php`, `ext-json`, `lib-icu`) rather than a
    /// package to fetch. Phase 2's solver checks these against the running PHP
    /// instead of looking for them in a repository.
    pub fn isPlatform(self: Dep) bool {
        return std.mem.eql(u8, self.name, "php") or
            std.mem.eql(u8, self.name, "composer-runtime-api") or
            std.mem.eql(u8, self.name, "composer-plugin-api") or
            std.mem.startsWith(u8, self.name, "ext-") or
            std.mem.startsWith(u8, self.name, "lib-") or
            std.mem.startsWith(u8, self.name, "php-");
    }
};

/// A `repositories[]` entry. Carried through phase 1 unused, because it is what
/// phase 2's resolver dispatches on — and because recording it now keeps the
/// parser in one place.
pub const Repo = struct {
    kind: Kind,
    url: []const u8,

    pub const Kind = enum { composer, vcs, path, package, artifact, unknown };

    pub fn kindOf(name: []const u8) Kind {
        if (std.mem.eql(u8, name, "composer")) return .composer;
        if (std.mem.eql(u8, name, "vcs") or std.mem.eql(u8, name, "git") or
            std.mem.eql(u8, name, "github") or std.mem.eql(u8, name, "gitlab")) return .vcs;
        if (std.mem.eql(u8, name, "path")) return .path;
        if (std.mem.eql(u8, name, "package")) return .package;
        if (std.mem.eql(u8, name, "artifact")) return .artifact;
        return .unknown;
    }
};

/// One package: the root project or an installed dependency.
pub const Manifest = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    kind: []const u8 = "library",

    require: []const Dep = &.{},
    require_dev: []const Dep = &.{},

    autoload: Autoload = .empty,
    autoload_dev: Autoload = .empty,

    repositories: []const Repo = &.{},

    /// `minimum-stability` — the floor for what may enter the candidate pool.
    /// Absent means `stable`, which is Composer's default.
    minimum_stability: []const u8 = "stable",
    /// `prefer-stable` — take a stable release over a newer unstable one.
    prefer_stable: bool = false,

    /// Where this package's files live, RELATIVE to the vendor directory
    /// (`vendor/composer/installed.json` spells it `install-path`, e.g.
    /// `../guzzlehttp/guzzle`). Empty for the root package, whose autoload
    /// paths are relative to the project root instead — the distinction the
    /// generated `__DIR__ . '/..'` versus `__DIR__ . '/../..'` prefixes encode.
    install_path: []const u8 = "",

    /// The identifier Composer hashes to key an `autoload.files` entry:
    /// `md5("<package name>:<relative path>")`. The root package uses its own
    /// name here too, which is why `name` is read even when nothing else needs it.
    pub fn fileIdentifier(self: Manifest, allocator: std.mem.Allocator, relative: []const u8) ![]const u8 {
        var digest: [16]u8 = undefined;
        var h = std.crypto.hash.Md5.init(.{});
        h.update(self.name);
        h.update(":");
        h.update(relative);
        h.final(&digest);
        return std.fmt.allocPrint(allocator, "{x}", .{&digest});
    }
};

/// Parse a `composer.json` document.
///
/// `allocator` should be an arena: every string returned borrows from the
/// parsed JSON tree, which is itself leaked into it.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Manifest {
    const trimmed = std.mem.trim(u8, source, " \t\r\n\u{FEFF}");
    if (trimmed.len == 0) return .{};

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{}) catch {
        return error.MalformedManifest;
    };
    if (parsed != .object) return error.MalformedManifest;

    return fromObject(allocator, parsed.object);
}

/// Build a Manifest from an already-parsed object — the shape both
/// `composer.json` and each element of `installed.json` `packages[]` have.
pub fn fromObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Manifest {
    var m = Manifest{};

    if (strField(obj, "name")) |v| m.name = v;
    if (strField(obj, "version")) |v| m.version = v;
    if (strField(obj, "type")) |v| m.kind = v;
    if (strField(obj, "install-path")) |v| m.install_path = v;
    if (strField(obj, "minimum-stability")) |v| m.minimum_stability = v;
    if (obj.get("prefer-stable")) |v| {
        if (v == .bool) m.prefer_stable = v.bool;
    }

    m.require = try deps(allocator, obj, "require");
    m.require_dev = try deps(allocator, obj, "require-dev");

    if (obj.get("autoload")) |v| m.autoload = try autoloadOf(allocator, v);
    if (obj.get("autoload-dev")) |v| m.autoload_dev = try autoloadOf(allocator, v);

    m.repositories = try repositories(allocator, obj);

    return m;
}

/// Read `vendor/composer/installed.json` — every package Composer put in place.
///
/// Composer 2 wraps the list in `{"packages": [...], "dev": bool}`; Composer 1
/// wrote a bare array. Both are accepted because a vendor tree outlives the
/// Composer that produced it, and refusing the old shape would mean refusing to
/// generate an autoloader for a project that currently has a working one.
pub fn readInstalled(
    allocator: std.mem.Allocator,
    io: Io,
    vendor_dir: []const u8,
) ![]const Manifest {
    const path = try std.fs.path.join(allocator, &.{ vendor_dir, "composer", "installed.json" });
    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch {
        return error.NoInstalledJson;
    };

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
        return error.MalformedManifest;
    };

    const list: std.json.Array = switch (parsed) {
        .array => |a| a,
        .object => |o| blk: {
            const p = o.get("packages") orelse return error.MalformedManifest;
            if (p != .array) return error.MalformedManifest;
            break :blk p.array;
        },
        else => return error.MalformedManifest,
    };

    var out: std.ArrayList(Manifest) = .empty;
    for (list.items) |item| {
        if (item != .object) continue;
        try out.append(allocator, try fromObject(allocator, item.object));
    }
    return out.toOwnedSlice(allocator);
}

/// Read and parse `<dir>/composer.json`, or null when there is none.
pub fn read(allocator: std.mem.Allocator, io: Io, dir: []const u8) !?Manifest {
    const path = try std.fs.path.join(allocator, &.{ dir, "composer.json" });
    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch return null;
    return try parse(allocator, source);
}

// ── field readers ─────────────────────────────────────────────────────────────

fn autoloadOf(allocator: std.mem.Allocator, value: std.json.Value) !Autoload {
    if (value != .object) return .empty;
    const obj = value.object;

    return .{
        .psr4 = try namespaceRules(allocator, obj, "psr-4"),
        .psr0 = try namespaceRules(allocator, obj, "psr-0"),
        .classmap = try strList(allocator, obj, "classmap"),
        .files = try strList(allocator, obj, "files"),
        .exclude = try strList(allocator, obj, "exclude-from-classmap"),
    };
}

/// psr-4 / psr-0: `{"Prefix\\": "src"}` or `{"Prefix\\": ["src", "lib"]}`.
fn namespaceRules(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) ![]const NamespaceRule {
    const raw = obj.get(key) orelse return &.{};
    if (raw != .object) return &.{};

    var out: std.ArrayList(NamespaceRule) = .empty;
    var it = raw.object.iterator();
    while (it.next()) |entry| {
        const paths = switch (entry.value_ptr.*) {
            .string => |s| blk: {
                const one = try allocator.alloc([]const u8, 1);
                one[0] = s;
                break :blk one;
            },
            .array => |a| blk: {
                var acc: std.ArrayList([]const u8) = .empty;
                for (a.items) |p| if (p == .string) try acc.append(allocator, p.string);
                break :blk try acc.toOwnedSlice(allocator);
            },
            else => continue,
        };
        if (paths.len == 0) continue;
        try out.append(allocator, .{ .prefix = entry.key_ptr.*, .paths = paths });
    }
    return out.toOwnedSlice(allocator);
}

fn deps(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const Dep {
    const raw = obj.get(key) orelse return &.{};
    if (raw != .object) return &.{};

    var out: std.ArrayList(Dep) = .empty;
    var it = raw.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try out.append(allocator, .{
            .name = entry.key_ptr.*,
            .constraint = entry.value_ptr.string,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn repositories(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const Repo {
    const raw = obj.get("repositories") orelse return &.{};

    var out: std.ArrayList(Repo) = .empty;

    // Composer accepts both a list and a name-keyed object here.
    switch (raw) {
        .array => |a| for (a.items) |item| {
            if (try repoOf(item)) |r| try out.append(allocator, r);
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                if (try repoOf(entry.value_ptr.*)) |r| try out.append(allocator, r);
            }
        },
        else => return &.{},
    }
    return out.toOwnedSlice(allocator);
}

fn repoOf(value: std.json.Value) !?Repo {
    if (value != .object) return null;
    const kind = strField(value.object, "type") orelse return null;
    return .{
        .kind = Repo.kindOf(kind),
        .url = strField(value.object, "url") orelse "",
    };
}

fn strList(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const raw = obj.get(key) orelse return &.{};
    if (raw != .array) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    for (raw.array.items) |item| if (item == .string) try out.append(allocator, item.string);
    return out.toOwnedSlice(allocator);
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
