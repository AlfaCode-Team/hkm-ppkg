//! `config` — the block Composer reads before it does anything else.
//!
//! Composer's `Config` object is assembled from four layers, and reading only
//! the project's own `composer.json` gets three of them wrong:
//!
//!     1. defaults
//!     2. `$COMPOSER_HOME/config.json`   the machine's own settings
//!     3. the project's `composer.json`  `config` block
//!     4. `COMPOSER_*` environment variables
//!
//! Later layers win, per key — a project setting `optimize-autoloader` does not
//! discard the machine's `cafile`. That per-KEY merge is the whole reason this
//! file exists rather than a `?[]const u8` per setting hung off `Manifest`: a
//! global config.json is where an operator puts the CA bundle, the process
//! timeout and the preferred install method for every project on the machine,
//! and a package manager that silently ignores it is one that behaves
//! differently from the tool it replaces on exactly the machines that were
//! configured most carefully.
//!
//! ## What is here, and what is not
//!
//! Every key with a CONSUMER is exposed as a named accessor with Composer's own
//! default. Keys that describe behaviour this package does not have are read by
//! `raw()` and reported by `hkm ppkg config --list`, but nothing acts on them —
//! and `compat` names the ones whose absence changes an outcome, rather than
//! letting a project discover it.
//!
//! Layer 1 lives in the accessor defaults rather than in a table, so that the
//! default and the key that overrides it are one line apart and cannot drift.

const std = @import("std");
const manifest = @import("manifest.zig");
const auth = @import("auth.zig");
const util = @import("util.zig");
const fetch = @import("fetch.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// How a package should be obtained — `config.preferred-install`.
pub const Preference = enum {
    /// A downloadable archive: fast, and what a deployment wants.
    dist,
    /// A working copy with its VCS metadata: what a contributor wants.
    source,
    /// Composer's default — dist for a tagged release, source for a branch.
    auto,
};

/// `config.bin-compat` — which launcher shapes to write into `vendor/bin`.
pub const BinCompat = enum {
    /// Unix launchers on Unix, plus `.bat` on Windows. Composer's default.
    auto,
    /// Both shapes everywhere — for a tree shared between Windows and WSL.
    full,
    /// A PHP proxy rather than a symlink, on every platform.
    proxy,
    /// A plain symlink. Fails on Windows without developer mode.
    symlink,
};

/// `config.audit.abandoned` — what an abandoned package does to `audit`.
pub const Abandoned = enum { ignore, report, fail };

pub const Settings = struct {
    /// The merged `config` block. Borrowed from the arena the loader was given.
    merged: std.json.ObjectMap,
    env: ?*EnvMap,
    allocator: std.mem.Allocator,

    // ── raw access ────────────────────────────────────────────────────────────

    /// The merged value for a key, whatever its JSON type.
    pub fn raw(self: Settings, key: []const u8) ?std.json.Value {
        return self.merged.get(key);
    }

    pub fn str(self: Settings, key: []const u8) ?[]const u8 {
        const v = self.merged.get(key) orelse return null;
        return switch (v) {
            .string => |s| if (s.len == 0) null else s,
            else => null,
        };
    }

    /// Composer accepts `true`, `"true"` and `1` for the same setting, because
    /// three different files write it three different ways — an env var is
    /// always a string, and a hand-edited config.json often is.
    pub fn flag(self: Settings, key: []const u8, default: bool) bool {
        const v = self.merged.get(key) orelse return default;
        return truthy(v) orelse default;
    }

    pub fn int(self: Settings, key: []const u8, default: i64) i64 {
        const v = self.merged.get(key) orelse return default;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch default,
            else => default,
        };
    }

    // ── the autoloader ────────────────────────────────────────────────────────

    /// `config.optimize-autoloader` — scan psr-4/0 roots into the classmap.
    /// The `-o` flag sets the same thing; a project that has declared it does
    /// not have to pass the flag on every dump.
    pub fn optimizeAutoloader(self: Settings) bool {
        // `classmap-authoritative` implies it: an authoritative classmap that
        // was not built from a scan resolves nothing.
        return self.flag("optimize-autoloader", false) or self.classmapAuthoritative();
    }

    /// `config.classmap-authoritative` — never touch the filesystem on a miss.
    pub fn classmapAuthoritative(self: Settings) bool {
        return self.flag("classmap-authoritative", false);
    }

    /// `config.apcu-autoloader` — memoise class lookups in APCu.
    pub fn apcuAutoloader(self: Settings) bool {
        return self.flag("apcu-autoloader", false);
    }

    /// `config.apcu-autoloader-prefix` — the APCu key prefix.
    ///
    /// Composer generates `bin2hex(random_bytes(10))` when the key is absent.
    /// Returning null here rather than inventing one lets the caller decide,
    /// which matters because a random prefix rewrites `autoload_real.php` on
    /// every single dump.
    pub fn apcuPrefix(self: Settings) ?[]const u8 {
        return self.str("apcu-autoloader-prefix");
    }

    /// `config.prepend-autoloader` — register ahead of other autoloaders.
    pub fn prependAutoloader(self: Settings) bool {
        return self.flag("prepend-autoloader", true);
    }

    /// `config.use-include-path` — also search PHP's own include_path.
    pub fn useIncludePath(self: Settings) bool {
        return self.flag("use-include-path", false);
    }

    /// `config.autoloader-suffix` — pin the generated class-name suffix.
    ///
    /// A project sets this to make a build reproducible: without it the suffix
    /// comes from the lock's content-hash, so any dependency change renames
    /// every generated class.
    pub fn autoloaderSuffix(self: Settings) ?[]const u8 {
        const s = self.str("autoloader-suffix") orelse return null;
        // It is interpolated into a PHP class name. A config file is something
        // anyone can edit, and a suffix with a quote or a brace in it produces
        // a vendor tree that fatals on every request.
        for (s) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
        }
        return s;
    }

    // ── installing ────────────────────────────────────────────────────────────

    /// `config.preferred-install` for a specific package.
    ///
    /// Two shapes: a bare string for every package, or an object of
    /// `"vendor/pattern" => "source"`. Composer takes the FIRST matching
    /// pattern in declaration order, so a specific rule must be written above
    /// the `*` that follows it — order matters and is preserved here.
    pub fn preferredInstall(self: Settings, package: []const u8) Preference {
        const v = self.merged.get("preferred-install") orelse return .auto;
        switch (v) {
            .string => |s| return preferenceOf(s),
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    if (globMatch(e.key_ptr.*, package)) {
                        return switch (e.value_ptr.*) {
                            .string => |s| preferenceOf(s),
                            else => .auto,
                        };
                    }
                }
                return .auto;
            },
            else => return .auto,
        }
    }

    /// `config.bin-compat`.
    pub fn binCompat(self: Settings) BinCompat {
        const s = self.str("bin-compat") orelse return .auto;
        if (std.mem.eql(u8, s, "full")) return .full;
        if (std.mem.eql(u8, s, "proxy")) return .proxy;
        if (std.mem.eql(u8, s, "symlink")) return .symlink;
        return .auto;
    }

    /// `config.discard-changes` — overwrite a package whose source was edited.
    ///
    /// Composer's third value, `"stash"`, needs a git working copy to stash
    /// into; it is read as `true` here and `compat` says so, because silently
    /// treating "stash my work" as "keep my work" would strand changes the
    /// operator asked to have moved out of the way.
    pub fn discardChanges(self: Settings) bool {
        const v = self.merged.get("discard-changes") orelse return false;
        if (v == .string and std.mem.eql(u8, v.string, "stash")) return true;
        return truthy(v) orelse false;
    }

    /// `config.lock` — write a composer.lock at all.
    ///
    /// A library that deliberately does not ship a lock sets this false; an
    /// update that writes one anyway adds a file to their repository.
    pub fn writesLock(self: Settings) bool {
        return self.flag("lock", true);
    }

    /// `config.sort-packages` — keep `require` alphabetically ordered.
    pub fn sortPackages(self: Settings) bool {
        return self.flag("sort-packages", false);
    }

    /// `config.platform-check` — `true`, `false` or `"php-only"`.
    pub fn platformCheck(self: Settings) ?[]const u8 {
        const v = self.merged.get("platform-check") orelse return null;
        return switch (v) {
            .string => |s| s,
            .bool => |b| if (b) "true" else "false",
            else => null,
        };
    }

    // ── the network ───────────────────────────────────────────────────────────

    /// `config.secure-http` — refuse plain HTTP.
    ///
    /// ON by default, which is Composer's default and the only safe one: a
    /// package downloaded over http is a package any host on the path may
    /// replace, and this one is about to be executed.
    pub fn secureHttp(self: Settings) bool {
        return self.flag("secure-http", true);
    }

    /// `config.disable-tls` — do not verify certificates, or use TLS at all.
    pub fn disableTls(self: Settings) bool {
        return self.flag("disable-tls", false);
    }

    /// `config.cafile` — the CA bundle to verify against.
    pub fn cafile(self: Settings) ?[]const u8 {
        return self.str("cafile");
    }

    /// `config.capath` — a directory of CA certificates.
    pub fn capath(self: Settings) ?[]const u8 {
        return self.str("capath");
    }

    /// `config.process-timeout` — seconds a spawned command may run.
    ///
    /// Applies to scripts and to the VCS tools: a `git clone` of a large
    /// repository over a slow link is the case this exists for, and a project
    /// that raised it did so because the default was not enough.
    pub fn processTimeout(self: Settings) u32 {
        const v = self.int("process-timeout", 300);
        if (v <= 0) return 0; // 0 = no limit, which Composer also allows
        return @intCast(@min(v, std.math.maxInt(u32)));
    }

    /// `config.cache-dir`.
    pub fn cacheDir(self: Settings) ?[]const u8 {
        return self.str("cache-dir");
    }

    /// `config.cache-files-ttl` — seconds a cached archive stays valid.
    pub fn cacheFilesTtl(self: Settings) i64 {
        return self.int("cache-files-ttl", self.int("cache-ttl", 15552000));
    }

    /// `config.cache-read-only` — read the cache, never write it.
    pub fn cacheReadOnly(self: Settings) bool {
        return self.flag("cache-read-only", false);
    }

    // ── archives ──────────────────────────────────────────────────────────────

    /// `config.archive-format` — the default for `archive`.
    pub fn archiveFormat(self: Settings) []const u8 {
        return self.str("archive-format") orelse "tar";
    }

    /// `config.archive-dir` — where `archive` writes by default.
    pub fn archiveDir(self: Settings) []const u8 {
        return self.str("archive-dir") orelse ".";
    }

    // ── audit ─────────────────────────────────────────────────────────────────

    /// Push the transport settings into the download layer.
    ///
    /// Called once per command, right after loading. These are process-wide
    /// facts about how this machine talks to the network — which CA bundle,
    /// whether plain HTTP is allowed — and the download path is reached from a
    /// worker pool whose functions take a fixed context, so they cannot be
    /// threaded through as parameters.
    pub fn applyTransport(self: Settings) void {
        fetch.applySettings(
            self.secureHttp(),
            self.cafile(),
            self.capath(),
            self.disableTls(),
            self.cacheDir(),
            self.processTimeout(),
        );
    }

    /// `config.audit.abandoned`.
    pub fn auditAbandoned(self: Settings) Abandoned {
        const v = self.merged.get("audit") orelse return .report;
        if (v != .object) return .report;
        const a = v.object.get("abandoned") orelse return .report;
        if (a != .string) return .report;
        if (std.mem.eql(u8, a.string, "ignore")) return .ignore;
        if (std.mem.eql(u8, a.string, "fail")) return .fail;
        return .report;
    }
};

/// Read and merge every layer for the project at `root_dir`.
///
/// `allocator` should be an arena — the returned settings borrow from the
/// parsed JSON of both files.
pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    env: ?*EnvMap,
    root_dir: []const u8,
) Settings {
    var merged: std.json.ObjectMap = .empty;

    // 2. the machine's own settings
    if (auth.composerHome(allocator, env)) |home| {
        const path = std.fs.path.join(allocator, &.{ home, "config.json" }) catch null;
        if (path) |p| overlayFile(allocator, io, &merged, p);
    }

    // 3. the project
    const project = std.fs.path.join(allocator, &.{ root_dir, "composer.json" }) catch null;
    if (project) |p| overlayFile(allocator, io, &merged, p);

    // 4. the environment
    overlayEnv(allocator, env, &merged);

    return .{ .merged = merged, .env = env, .allocator = allocator };
}

/// Settings for a caller that has nothing to read — tests, and the paths that
/// operate on a manifest they were handed rather than a directory.
pub fn empty(allocator: std.mem.Allocator) Settings {
    return .{ .merged = .empty, .env = null, .allocator = allocator };
}

/// Merge an already-parsed manifest's `config` block. For callers holding a
/// `Manifest` and no directory.
pub fn fromManifest(allocator: std.mem.Allocator, m: manifest.Manifest) Settings {
    var merged: std.json.ObjectMap = .empty;
    if (m.config_raw) |obj| overlayObject(allocator, &merged, obj);
    return .{ .merged = merged, .env = null, .allocator = allocator };
}

fn overlayFile(allocator: std.mem.Allocator, io: Io, into: *std.json.ObjectMap, path: []const u8) void {
    const body = Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return;
    if (parsed != .object) return;
    const cfg = parsed.object.get("config") orelse return;
    if (cfg != .object) return;
    overlayObject(allocator, into, cfg.object);
}

fn overlayObject(allocator: std.mem.Allocator, into: *std.json.ObjectMap, from: std.json.ObjectMap) void {
    var it = from.iterator();
    while (it.next()) |e| into.put(allocator, e.key_ptr.*, e.value_ptr.*) catch return;
}

/// The `COMPOSER_*` variables that override a config key.
///
/// Composer reads these in `Factory::createConfig`, and they are the layer a
/// CI job uses — a container sets `COMPOSER_PROCESS_TIMEOUT` rather than
/// editing a file it does not own.
const env_keys = [_]struct { []const u8, []const u8 }{
    .{ "COMPOSER_CACHE_DIR", "cache-dir" },
    .{ "COMPOSER_PROCESS_TIMEOUT", "process-timeout" },
    .{ "COMPOSER_DISCARD_CHANGES", "discard-changes" },
    .{ "COMPOSER_PREFER_STABLE", "prefer-stable" },
    .{ "COMPOSER_PREFER_LOWEST", "prefer-lowest" },
    .{ "COMPOSER_HTACCESS_PROTECT", "htaccess-protect" },
    .{ "COMPOSER_CAFILE", "cafile" },
    .{ "COMPOSER_CAPATH", "capath" },
    .{ "COMPOSER_DISABLE_TLS", "disable-tls" },
    .{ "COMPOSER_SECURE_HTTP", "secure-http" },
    .{ "COMPOSER_BIN_COMPAT", "bin-compat" },
    .{ "COMPOSER_AUTOLOADER_SUFFIX", "autoloader-suffix" },
};

fn overlayEnv(allocator: std.mem.Allocator, env: ?*EnvMap, into: *std.json.ObjectMap) void {
    const e = env orelse return;
    for (env_keys) |pair| {
        const value = e.get(pair[0]) orelse continue;
        if (value.len == 0) continue;
        into.put(allocator, pair[1], .{ .string = value }) catch return;
    }
}

/// `true`, `"true"`, `"1"`, `1` — and their negatives. Null when the value is
/// not a boolean in any spelling, so a caller can keep its own default rather
/// than read a typo as `false`.
fn truthy(v: std.json.Value) ?bool {
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| blk: {
            if (s.len == 0) break :blk null;
            if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn preferenceOf(s: []const u8) Preference {
    if (std.mem.eql(u8, s, "source")) return .source;
    if (std.mem.eql(u8, s, "dist")) return .dist;
    return .auto;
}

/// `preferred-install` patterns are fnmatch, not the single-`*` form
/// `allow-plugins` uses: `symfony/*` and `*/*-bundle` both appear in the wild.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    return globAt(pattern, name);
}

fn globAt(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn settingsFrom(arena: std.mem.Allocator, json: []const u8) !Settings {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    var merged: std.json.ObjectMap = .empty;
    overlayObject(arena, &merged, parsed.object);
    return .{ .merged = merged, .env = null, .allocator = arena };
}

test "defaults are Composer's defaults, not zero values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = empty(arena.allocator());

    try testing.expect(s.secureHttp()); // ON — the only safe default
    try testing.expect(s.prependAutoloader()); // Composer registers first
    try testing.expect(s.writesLock());
    try testing.expect(!s.optimizeAutoloader());
    try testing.expect(!s.disableTls());
    try testing.expectEqual(@as(u32, 300), s.processTimeout());
    try testing.expectEqual(Preference.auto, s.preferredInstall("acme/thing"));
    try testing.expectEqual(BinCompat.auto, s.binCompat());
    try testing.expectEqualStrings("tar", s.archiveFormat());
}

test "classmap-authoritative implies optimize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try settingsFrom(arena.allocator(), "{\"classmap-authoritative\": true}");

    // Not a convenience: an authoritative classmap built without a scan
    // resolves nothing, and the failure is a class-not-found at runtime.
    try testing.expect(s.optimizeAutoloader());
}

test "a bool written as a string is still a bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Every env var arrives as a string, and hand-edited config.json often does.
    const s = try settingsFrom(arena.allocator(), "{\"secure-http\": \"false\", \"optimize-autoloader\": \"1\"}");

    try testing.expect(!s.secureHttp());
    try testing.expect(s.optimizeAutoloader());
}

test "a value that is not a bool in any spelling keeps the default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try settingsFrom(arena.allocator(), "{\"secure-http\": \"yes-please\"}");

    // Reading a typo as `false` would silently turn off the check that stops a
    // package being fetched over plain HTTP.
    try testing.expect(s.secureHttp());
}

test "preferred-install: first matching pattern wins, in declaration order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try settingsFrom(arena.allocator(),
        \\{"preferred-install": {"acme/special": "source", "acme/*": "dist", "*": "auto"}}
    );

    try testing.expectEqual(Preference.source, s.preferredInstall("acme/special"));
    try testing.expectEqual(Preference.dist, s.preferredInstall("acme/other"));
    try testing.expectEqual(Preference.auto, s.preferredInstall("other/thing"));
}

test "preferred-install as a bare string covers everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try settingsFrom(arena.allocator(), "{\"preferred-install\": \"source\"}");

    try testing.expectEqual(Preference.source, s.preferredInstall("anything/at-all"));
}

test "fnmatch patterns, not just a single trailing star" {
    try testing.expect(globMatch("symfony/*", "symfony/console"));
    try testing.expect(globMatch("*/*-bundle", "acme/admin-bundle"));
    try testing.expect(!globMatch("*/*-bundle", "acme/admin"));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("acme/th?ng", "acme/thing"));
}

test "autoloader-suffix is refused when it is not a PHP identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ok = try settingsFrom(arena.allocator(), "{\"autoloader-suffix\": \"MyApp1\"}");
    const bad = try settingsFrom(arena.allocator(), "{\"autoloader-suffix\": \"my'; echo\"}");

    try testing.expectEqualStrings("MyApp1", ok.autoloaderSuffix().?);
    // It is interpolated into a class name in a file included on every request.
    try testing.expect(bad.autoloaderSuffix() == null);
}

test "audit.abandoned is nested, and defaults to report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try settingsFrom(arena.allocator(), "{\"audit\": {\"abandoned\": \"fail\"}}");
    const d = empty(arena.allocator());

    try testing.expectEqual(Abandoned.fail, s.auditAbandoned());
    try testing.expectEqual(Abandoned.report, d.auditAbandoned());
}

test "process-timeout accepts 0 as no limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try settingsFrom(arena.allocator(), "{\"process-timeout\": 0}");
    try testing.expectEqual(@as(u32, 0), s.processTimeout());
}

test "the environment beats the project, which beats the machine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var merged: std.json.ObjectMap = .empty;
    const machine = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"process-timeout": 900, "cafile": "/etc/ssl/machine.pem"}
    , .{});
    const project = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"process-timeout\": 60}", .{});
    overlayObject(a, &merged, machine.object);
    overlayObject(a, &merged, project.object);

    var env: EnvMap = .init(a);
    defer env.deinit();
    try env.put("COMPOSER_PROCESS_TIMEOUT", "30");
    overlayEnv(a, &env, &merged);

    const s = Settings{ .merged = merged, .env = &env, .allocator = a };
    try testing.expectEqual(@as(u32, 30), s.processTimeout());
    // Per-KEY merge: the project overrode one key and kept the machine's other.
    try testing.expectEqualStrings("/etc/ssl/machine.pem", s.cafile().?);
}
