//! `vendor/composer/platform_check.php` — the guard the autoloader runs first.
//!
//! Composer derives this file from the PHP and extension requirements of the
//! packages actually installed, and `vendor/autoload.php` includes it before
//! anything else. It is the reason a project whose dependencies need PHP 8.2
//! fails with a sentence instead of a parse error when it lands on 8.0.
//!
//! It used to be COPIED here, along with Composer's four genuine runtime files,
//! from a donor vendor tree. That was wrong in a way a file-count comparison
//! could not see: the copy carries the DONOR's floor. Installing a project that
//! requires `^8.1` from a kernel checkout requiring `^8.4` produced a vendor
//! tree that refused to boot on 8.1, 8.2 and 8.3 — the exact versions the
//! project declared support for.
//!
//! So it is generated, not copied, and generating it is not a licensing
//! question: unlike `ClassLoader.php`, nothing here is Composer's code. The
//! file is a rendering of the project's own dependency data, and every literal
//! below is a format string that Composer's `AutoloadGenerator::getPlatformCheck`
//! builds the same output from.

const std = @import("std");
const manifest = @import("manifest.zig");
const constraint = @import("constraint.zig");

/// `config.platform-check`.
pub const Mode = enum {
    /// Generate nothing.
    off,
    /// The PHP version bound only. Composer's DEFAULT since 2.x, which is why
    /// a tree full of `ext-json` requirements still checks only the version.
    php_only,
    /// Version and extensions.
    full,

    pub fn fromConfig(value: ?[]const u8) Mode {
        const v = value orelse return .php_only;
        if (std.mem.eql(u8, v, "false")) return .off;
        if (std.mem.eql(u8, v, "true")) return .full;
        if (std.mem.eql(u8, v, "php-only")) return .php_only;
        return .php_only;
    }
};

/// A `Composer\Semver\Constraint\Bound` — a version plus whether it is included.
const Bound = struct {
    zero: bool = true,
    version: constraint.Version = .{},
    inclusive: bool = true,

    /// Ordering matches `Bound::compareTo`: by version, then by inclusivity,
    /// where an EXCLUSIVE lower bound is the higher of the two (`> 8.1` admits
    /// strictly less than `>= 8.1`).
    fn greaterThan(self: Bound, other: Bound) bool {
        if (other.zero) return !self.zero;
        if (self.zero) return false;
        return switch (self.version.order(other.version)) {
            .gt => true,
            .lt => false,
            .eq => !self.inclusive and other.inclusive,
        };
    }

    /// `PHP_VERSION_ID` form: 8.1.0 → 80100.
    fn versionId(self: Bound) u32 {
        if (self.zero) return 0;
        return self.version.parts[0] * 10000 + self.version.parts[1] * 100 + self.version.parts[2];
    }

    /// The human form in the error message: at most three chunks.
    fn human(self: Bound, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
            self.version.parts[0], self.version.parts[1], self.version.parts[2],
        });
    }
};

/// The lower bound of a parsed constraint.
///
/// A constraint is a disjunction of conjunctions, so the bound is the MINIMUM
/// across alternatives of the MAXIMUM within each — `^8.1 || ^7.4` is satisfied
/// by 7.4, and claiming 8.1 would reject a runtime the project supports.
fn lowerBound(c: constraint.Constraint) Bound {
    if (c.groups.len == 0) return .{};

    var overall: ?Bound = null;
    for (c.groups) |group| {
        var group_bound: Bound = .{};
        for (group) |term| {
            const b: Bound = switch (term.op) {
                .gte, .eq => .{ .zero = term.any, .version = term.version, .inclusive = true },
                .gt => .{ .zero = term.any, .version = term.version, .inclusive = false },
                // An upper bound or an exclusion says nothing about the floor.
                .lt, .lte, .ne => .{},
            };
            if (b.greaterThan(group_bound)) group_bound = b;
        }
        if (overall == null or overall.?.greaterThan(group_bound)) overall = group_bound;
    }
    return overall orelse .{};
}

/// One package as this file needs to see it.
pub const Package = struct {
    name: []const u8,
    requires: []const manifest.Dep,
    provides: []const manifest.Dep = &.{},
    replaces: []const manifest.Dep = &.{},
    /// Dev-only packages are excluded from the check: a production deployment
    /// installed with `--no-dev` must not be told it needs phpunit's extensions.
    dev: bool = false,
};

/// Render the file, or null when there is nothing to check.
///
/// Null is Composer's answer too, and Composer then leaves the `require` out of
/// `autoload_real.php`. This package cannot do that — `autoload_real.php` is
/// copied verbatim from a donor tree and its `require` line is already there —
/// so `install` writes the no-op skeleton `renderEmpty` produces instead of
/// nothing at all. A missing file would be a fatal error at the top of every
/// request; a file that checks nothing is what the project asked for.
pub fn render(
    allocator: std.mem.Allocator,
    packages: []const Package,
    mode: Mode,
) !?[]const u8 {
    if (mode == .off) return null;

    // `ext-mbstring` required by one package and PROVIDED by another (the
    // symfony polyfills) must not be reported missing. Providers are collected
    // from every package, dev included: a polyfill does not stop working
    // because the package that pulled it in is dev-only.
    var providers: std.StringHashMapUnmanaged(void) = .empty;
    if (mode == .full) {
        for (packages) |pkg| {
            for (pkg.provides) |link| try recordProvider(allocator, &providers, link.name);
            for (pkg.replaces) |link| try recordProvider(allocator, &providers, link.name);
        }
    }

    var php: Bound = .{};
    var php_64bit = false;
    var extensions: std.ArrayList([]const u8) = .empty;

    for (packages) |pkg| {
        if (pkg.dev) continue;
        for (pkg.requires) |dep| {
            if (std.mem.eql(u8, dep.name, "php") or std.mem.eql(u8, dep.name, "php-64bit")) {
                const parsed = constraint.parse(allocator, dep.constraint) catch continue;
                const b = lowerBound(parsed);
                if (b.greaterThan(php)) php = b;
                if (std.mem.eql(u8, dep.name, "php-64bit")) php_64bit = true;
                continue;
            }
            if (mode != .full) continue;
            if (!std.mem.startsWith(u8, dep.name, "ext-")) continue;

            const ext = dep.name[4..];
            if (providers.contains(ext)) continue;
            // `ext-zend-opcache` is loaded under a name with a space in it.
            const loaded_as = if (std.mem.eql(u8, ext, "zend-opcache")) "zend opcache" else ext;
            if (!contains(extensions.items, loaded_as)) try extensions.append(allocator, loaded_as);
        }
    }

    std.mem.sort([]const u8, extensions.items, {}, lessThan);

    if (php.zero and extensions.items.len == 0) return null;

    var body: std.ArrayList(u8) = .empty;
    if (!php.zero) {
        try body.print(allocator,
            \\
            \\if (!(PHP_VERSION_ID {s} {d})) {{
            \\    $issues[] = 'Your Composer dependencies require a PHP version "{s} {s}". You are running ' . PHP_VERSION . '.';
            \\}}
            \\
        , .{
            if (php.inclusive) ">=" else ">",
            php.versionId(),
            if (php.inclusive) ">=" else ">",
            try php.human(allocator),
        });
    }
    if (php_64bit) {
        try body.appendSlice(allocator,
            \\
            \\if (PHP_INT_SIZE !== 8) {
            \\    $issues[] = 'Your Composer dependencies require a 64-bit build of PHP.';
            \\}
            \\
        );
    }
    if (extensions.items.len > 0) {
        try body.appendSlice(allocator, "\n$missingExtensions = array();\n");
        for (extensions.items) |ext| {
            // pcntl and readline exist under the CLI SAPI and legitimately do
            // not under others, so Composer only demands them on the CLI.
            if (std.mem.eql(u8, ext, "pcntl") or std.mem.eql(u8, ext, "readline")) {
                try body.print(allocator, "PHP_SAPI !== 'cli' || extension_loaded('{s}') || $missingExtensions[] = '{s}';\n", .{ ext, ext });
            } else {
                try body.print(allocator, "extension_loaded('{s}') || $missingExtensions[] = '{s}';\n", .{ ext, ext });
            }
        }
        try body.appendSlice(allocator,
            \\
            \\if ($missingExtensions) {
            \\    $issues[] = 'Your Composer dependencies require the following PHP extensions to be installed: ' . implode(', ', $missingExtensions) . '.';
            \\}
            \\
        );
    }

    return try wrap(allocator, body.items);
}

/// The file to write when there is nothing to check — see `render`.
pub fn renderEmpty(allocator: std.mem.Allocator) ![]const u8 {
    return wrap(allocator, "");
}

fn wrap(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?php
        \\
        \\// platform_check.php @generated by Composer
        \\
        \\$issues = array();
        \\{s}
        \\if ($issues) {{
        \\    if (!headers_sent()) {{
        \\        header('HTTP/1.1 500 Internal Server Error');
        \\    }}
        \\    if (!ini_get('display_errors')) {{
        \\        if (PHP_SAPI === 'cli' || PHP_SAPI === 'phpdbg') {{
        \\            fwrite(STDERR, 'Composer detected issues in your platform:' . PHP_EOL.PHP_EOL . implode(PHP_EOL, $issues) . PHP_EOL.PHP_EOL);
        \\        }} elseif (!headers_sent()) {{
        \\            echo 'Composer detected issues in your platform:' . PHP_EOL.PHP_EOL . str_replace('You are running '.PHP_VERSION.'.', '', implode(PHP_EOL, $issues)) . PHP_EOL.PHP_EOL;
        \\        }}
        \\    }}
        \\    throw new \RuntimeException(
        \\        'Composer detected issues in your platform: ' . implode(' ', $issues)
        \\    );
        \\}}
        \\
    , .{body});
}

fn recordProvider(
    allocator: std.mem.Allocator,
    into: *std.StringHashMapUnmanaged(void),
    name: []const u8,
) !void {
    if (!std.mem.startsWith(u8, name, "ext-")) return;
    try into.put(allocator, name[4..], {});
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn req(name: []const u8, c: []const u8) manifest.Dep {
    return .{ .name = name, .constraint = c };
}

test "the floor is the highest lower bound across non-dev packages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const php = (try render(a, &.{
        .{ .name = "acme/app", .requires = &.{req("php", "^8.0")} },
        .{ .name = "vendor/lib", .requires = &.{req("php", "^8.1")} },
        // Higher, but dev-only: excluded, exactly as Composer excludes it.
        .{ .name = "phpunit/phpunit", .requires = &.{req("php", "^8.3")}, .dev = true },
    }, .php_only)).?;

    try testing.expect(std.mem.indexOf(u8, php, "PHP_VERSION_ID >= 80100") != null);
    try testing.expect(std.mem.indexOf(u8, php, "a PHP version \">= 8.1.0\"") != null);
}

test "an OR takes the lowest alternative, not the highest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A package supporting BOTH lines must not have the 8.x floor imposed on it.
    const php = (try render(a, &.{
        .{ .name = "acme/app", .requires = &.{req("php", "^7.4 || ^8.0")} },
    }, .php_only)).?;

    try testing.expect(std.mem.indexOf(u8, php, "PHP_VERSION_ID >= 70400") != null);
}

test "an exclusive bound keeps its operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const php = (try render(a, &.{
        .{ .name = "acme/app", .requires = &.{req("php", "> 8.1.2")} },
    }, .php_only)).?;

    try testing.expect(std.mem.indexOf(u8, php, "PHP_VERSION_ID > 80102") != null);
    try testing.expect(std.mem.indexOf(u8, php, "\"> 8.1.2\"") != null);
}

test "php-only is the default, and it ignores extensions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(Mode.php_only, Mode.fromConfig(null));

    const pkgs = [_]Package{
        .{ .name = "acme/app", .requires = &.{ req("php", "^8.1"), req("ext-json", "*") } },
    };
    const only = (try render(a, &pkgs, .php_only)).?;
    try testing.expect(std.mem.indexOf(u8, only, "extension_loaded") == null);

    const full = (try render(a, &pkgs, .full)).?;
    try testing.expect(std.mem.indexOf(u8, full, "extension_loaded('json')") != null);
}

test "a provided extension is not reported missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const php = (try render(a, &.{
        .{ .name = "acme/app", .requires = &.{ req("ext-mbstring", "*"), req("ext-json", "*") } },
        .{ .name = "symfony/polyfill-mbstring", .requires = &.{}, .provides = &.{req("ext-mbstring", "*")} },
    }, .full)).?;

    try testing.expect(std.mem.indexOf(u8, php, "mbstring") == null);
    try testing.expect(std.mem.indexOf(u8, php, "extension_loaded('json')") != null);

    // With NOTHING left to check the answer is null, which is Composer's too.
    try testing.expect((try render(a, &.{
        .{ .name = "acme/app", .requires = &.{req("ext-mbstring", "*")} },
        .{ .name = "symfony/polyfill-mbstring", .requires = &.{}, .provides = &.{req("ext-mbstring", "*")} },
    }, .full)) == null);
}

test "pcntl and readline are only demanded on the CLI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const php = (try render(a, &.{
        .{ .name = "acme/app", .requires = &.{ req("ext-pcntl", "*"), req("ext-json", "*") } },
    }, .full)).?;

    try testing.expect(std.mem.indexOf(u8, php, "PHP_SAPI !== 'cli' || extension_loaded('pcntl')") != null);
    try testing.expect(std.mem.indexOf(u8, php, "\nextension_loaded('json')") != null);
}

test "zend-opcache is checked under the name it loads as" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const php = (try render(arena.allocator(), &.{
        .{ .name = "acme/app", .requires = &.{req("ext-zend-opcache", "*")} },
    }, .full)).?;

    try testing.expect(std.mem.indexOf(u8, php, "extension_loaded('zend opcache')") != null);
}

test "nothing to check yields null, and the skeleton is still valid PHP" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try render(a, &.{.{ .name = "acme/app", .requires = &.{} }}, .php_only)) == null);
    try testing.expect((try render(a, &.{.{ .name = "acme/app", .requires = &.{req("php", "^8.1")} }}, .off)) == null);

    const empty = try renderEmpty(a);
    try testing.expect(std.mem.indexOf(u8, empty, "$issues = array();") != null);
    try testing.expect(std.mem.indexOf(u8, empty, "PHP_VERSION_ID") == null);
}

test "php-64bit adds the word-size check as well as the version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const php = (try render(arena.allocator(), &.{
        .{ .name = "acme/app", .requires = &.{req("php-64bit", "^8.1")} },
    }, .php_only)).?;

    try testing.expect(std.mem.indexOf(u8, php, "PHP_INT_SIZE !== 8") != null);
    try testing.expect(std.mem.indexOf(u8, php, "PHP_VERSION_ID >= 80100") != null);
}
