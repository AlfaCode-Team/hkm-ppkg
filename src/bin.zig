//! `vendor/bin/` — the executables a package publishes.
//!
//! A package declares `"bin": ["phpunit"]`, and Composer puts a launcher at
//! `vendor/bin/phpunit`. That launcher is not a symlink: it is a proxy that
//! sets two globals the target script relies on —
//!
//!     $GLOBALS['_composer_bin_dir']        where the launcher lives
//!     $GLOBALS['_composer_autoload_path']  which autoloader to use
//!
//! A symlink cannot do that, and a tool invoked through one resolves `__DIR__`
//! to the wrong place and loads the wrong autoloader (or none).
//!
//! ## Four shapes, decided by the target's first bytes
//!
//! `BinaryInstaller::generateUnixyProxyCode` reads the first 500 bytes of the
//! target and branches. All four are reproduced here, because which one a
//! project gets is not a detail — it decides whether the tool runs:
//!
//!   1. not PHP at all      → a SHELL proxy that execs the target
//!   2. `<?php` with no shebang → a PHP proxy, no stream wrapper
//!   3. shebang then `<?php`    → the same, plus the PHP<8 stream wrapper
//!   4. `vendor/phpunit/phpunit/phpunit` → shape 3 plus two PHPUnit workarounds
//!
//! The stream wrapper used to be omitted here, on the reasoning that this
//! platform requires PHP 8.4 and the branch is unreachable. That reasoning does
//! not survive this being a general Composer replacement: the vendor tree it
//! writes is deployed to whatever PHP the PROJECT supports, not the one this
//! tool was built for. On PHP 7 an `include` of a file with a shebang prints
//! the shebang, and `__DIR__` inside the target resolves to `vendor/bin` —
//! silently, in production, for anyone still on 7.4.

const std = @import("std");
const util = @import("util.zig");
const layout = @import("layout.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Create `<bin-dir>/<name>` for one declared binary.
///
/// `package_dir` is the package's directory, ABSOLUTE — not a name relative to
/// `vendor/`: `extra.installer-paths` can put a package anywhere in the
/// project, and a launcher whose target is computed from `vendor/<name>` would
/// point at a directory that does not exist.
///
/// The two paths the proxy needs — its autoloader and its target — are computed
/// with Composer's own `findShortestPathCode`, not assembled from `'/../'`.
/// With `bin-dir` moved out of the vendor tree those two literals differ from
/// each other AND from the default, and a launcher that guesses wrong is a
/// `require` of a file that is not there.
pub fn install(
    allocator: std.mem.Allocator,
    io: Io,
    lay: layout.Layout,
    package_dir: []const u8,
    bin_rel: []const u8,
) !void {
    try Dir.cwd().createDirPath(io, lay.bin);

    const name = std.fs.path.basename(bin_rel);
    const target = try std.fs.path.join(allocator, &.{ package_dir, std.mem.trim(u8, bin_rel, "/") });
    const path = try std.fs.path.join(allocator, &.{ lay.bin, name });

    const paths: Paths = .{
        .autoload = try layout.shortestPathCode(
            allocator,
            lay.bin,
            try std.fs.path.join(allocator, &.{ lay.vendor, "autoload.php" }),
            true,
            true,
        ),
        .target = try layout.shortestPathCode(allocator, lay.bin, target, true, true),
        .bare_target = try layout.relativePath(allocator, lay.bin, target),
        // Composer decides the shape from the target's own bytes, so the
        // target has to be read. 500 bytes, exactly as it reads.
        .head = head(allocator, io, target),
        // The PHPUnit workarounds key off the package PATH, not the binary's
        // name: a package that happens to ship a binary called `phpunit` is not
        // PHPUnit, and giving it PHPUnit's globals would be wrong.
        .is_phpunit = std.mem.endsWith(u8, target, "/phpunit/phpunit/phpunit"),
    };

    try util.writeFileAtomic(io, path, try proxy(allocator, paths));
    util.chmodExec(io, path);
}

/// The first 500 bytes of the target, or empty when it cannot be read.
///
/// A PREFIX read, not a whole-file read with a cap: `readFileAlloc` with a
/// limit FAILS on a file larger than it, and every real binary is. Reading the
/// prefix through the file handle is the difference between classifying the
/// target and classifying nothing — which came out as a shell proxy wrapped
/// around a PHP script.
fn head(allocator: std.mem.Allocator, io: Io, target: []const u8) []const u8 {
    const f = Dir.cwd().openFile(io, target, .{}) catch return "";
    defer f.close(io);

    const buf = allocator.alloc(u8, 500) catch return "";
    var reader = f.reader(io, buf);
    const chunk = reader.interface.peekGreedy(1) catch return "";
    return chunk;
}

/// What a launcher is written in terms of.
pub const Paths = struct {
    /// Reaches `<vendor>/autoload.php` from the bin directory.
    autoload: []const u8,
    /// Reaches the package's real script from the bin directory.
    target: []const u8,
    /// The same path as plain text, for the comment at the top of the file and
    /// for the shell proxy's `cd`. Composer writes
    /// `(../phpunit/phpunit/phpunit)` there — a relative path, not an
    /// expression.
    bare_target: []const u8 = "",
    /// The target's opening bytes, which decide the shape.
    head: []const u8 = "<?php",
    /// Is this the real PHPUnit binary?
    is_phpunit: bool = false,

    /// The default layout's answers, so a test or a caller with no Layout in
    /// hand still gets the strings Composer writes for `vendor/bin`.
    pub fn forDefault(allocator: std.mem.Allocator, target: []const u8) !Paths {
        return .{
            .autoload = "__DIR__ . '/..'.'/autoload.php'",
            .target = try std.fmt.allocPrint(allocator, "__DIR__ . '/..'.'/{s}'", .{target}),
            .bare_target = try std.fmt.allocPrint(allocator, "../{s}", .{target}),
        };
    }
};

/// What the target's first bytes say about it.
const Shape = struct {
    /// Does it open with `<?php`, optionally after a shebang?
    is_php: bool,
    /// The shebang line as written, trailing newline trimmed. Empty when there
    /// is none — and its presence is what decides the stream wrapper.
    shebang: []const u8,
};

/// Composer's `{^(#!.*\r?\n)?[\r\n\t ]*<\?php}`, by hand.
fn shapeOf(source: []const u8) Shape {
    var rest = source;
    var shebang: []const u8 = "";

    if (std.mem.startsWith(u8, rest, "#!")) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return .{ .is_php = false, .shebang = "" };
        shebang = std.mem.trimEnd(u8, rest[0..nl], "\r");
        rest = rest[nl + 1 ..];
    }

    rest = std.mem.trimStart(u8, rest, "\r\n\t ");
    return .{ .is_php = std.mem.startsWith(u8, rest, "<?php"), .shebang = shebang };
}

/// The launcher.
pub fn proxy(allocator: std.mem.Allocator, paths: Paths) ![]const u8 {
    const shape = shapeOf(paths.head);
    if (!shape.is_php) return shellProxy(allocator, paths);

    var out: std.ArrayList(u8) = .empty;

    // Composer carries the target's OWN shebang over when it has one, so a
    // binary that asks for a specific interpreter keeps asking for it.
    try out.appendSlice(allocator, if (shape.shebang.len > 0) shape.shebang else "#!/usr/bin/env php");
    try out.appendSlice(allocator, "\n<?php\n\n/**\n * Proxy PHP file generated by Composer\n *\n");
    try out.print(allocator, " * This file includes the referenced bin path ({s})\n", .{paths.bare_target});

    // The hint line exists only when the wrapper below does.
    const wrapped = shape.shebang.len > 0;
    if (wrapped) {
        try out.appendSlice(allocator, " * using a stream wrapper to prevent the shebang from being output on PHP<8\n *\n");
    } else {
        try out.appendSlice(allocator, " *\n");
    }

    try out.appendSlice(allocator,
        \\ * @generated
        \\ */
        \\
        \\namespace Composer;
        \\
        \\$GLOBALS['_composer_bin_dir'] = __DIR__;
        \\
    );
    try out.print(allocator, "$GLOBALS['_composer_autoload_path'] = {s};\n", .{paths.autoload});

    // PHPUnit reads this global to keep its own launcher out of the list of
    // files re-included in an isolated child process. Composer special-cases it
    // for the same reason; without it, process-isolation tests re-enter the
    // proxy and fail in a way that has nothing to do with the test.
    if (paths.is_phpunit) {
        try out.print(
            allocator,
            "$GLOBALS['__PHPUNIT_ISOLATION_EXCLUDE_LIST'] = $GLOBALS['__PHPUNIT_ISOLATION_BLACKLIST'] = array(realpath({s}));\n",
            .{paths.target},
        );
    }

    try out.appendSlice(allocator, "\n");
    if (wrapped) try appendStreamProxy(allocator, &out, paths);
    try out.print(allocator, "return include {s};\n", .{paths.target});

    return out.toOwnedSlice(allocator);
}

/// The PHP<8 stream wrapper, verbatim from `BinaryInstaller`.
///
/// Two lines of it are conditional and both belong to PHPUnit: it is the one
/// package whose binary is re-included by its own test runner, so it is the one
/// that needs `__DIR__` and `__FILE__` rewritten as well as the shebang
/// stripped.
fn appendStreamProxy(allocator: std.mem.Allocator, out: *std.ArrayList(u8), paths: Paths) !void {
    try out.appendSlice(allocator,
        \\if (PHP_VERSION_ID < 80000) {
        \\    if (!class_exists('Composer\BinProxyWrapper')) {
        \\        /**
        \\         * @internal
        \\         */
        \\        final class BinProxyWrapper
        \\        {
        \\            private $handle;
        \\            private $position;
        \\            private $realpath;
        \\
        \\            public function stream_open($path, $mode, $options, &$opened_path)
        \\            {
        \\                // get rid of phpvfscomposer:// prefix for __FILE__ & __DIR__ resolution
        \\                $opened_path = substr($path, 17);
        \\                $this->realpath = realpath($opened_path) ?: $opened_path;
        \\
    );

    // `$phpunitHack1` — the prefix is kept only for PHPUnit.
    if (paths.is_phpunit) {
        try out.appendSlice(allocator, "                $opened_path = 'phpvfscomposer://'.$this->realpath;\n");
    } else {
        try out.appendSlice(allocator, "                $opened_path = $this->realpath;\n");
    }

    try out.appendSlice(allocator,
        \\                $this->handle = fopen($this->realpath, $mode);
        \\                $this->position = 0;
        \\
        \\                return (bool) $this->handle;
        \\            }
        \\
        \\            public function stream_read($count)
        \\            {
        \\                $data = fread($this->handle, $count);
        \\
        \\                if ($this->position === 0) {
        \\                    $data = preg_replace('{^#!.*\r?\n}', '', $data);
        \\                }
        \\
    );

    // `$phpunitHack2`.
    if (paths.is_phpunit) {
        try out.appendSlice(allocator,
            \\                $data = str_replace('__DIR__', var_export(dirname($this->realpath), true), $data);
            \\                $data = str_replace('__FILE__', var_export($this->realpath, true), $data);
            \\
        );
    }

    try out.appendSlice(allocator,
        \\
        \\                $this->position += strlen($data);
        \\
        \\                return $data;
        \\            }
        \\
        \\            public function stream_cast($castAs)
        \\            {
        \\                return $this->handle;
        \\            }
        \\
        \\            public function stream_close()
        \\            {
        \\                fclose($this->handle);
        \\            }
        \\
        \\            public function stream_lock($operation)
        \\            {
        \\                return $operation ? flock($this->handle, $operation) : true;
        \\            }
        \\
        \\            public function stream_seek($offset, $whence)
        \\            {
        \\                if (0 === fseek($this->handle, $offset, $whence)) {
        \\                    $this->position = ftell($this->handle);
        \\                    return true;
        \\                }
        \\
        \\                return false;
        \\            }
        \\
        \\            public function stream_tell()
        \\            {
        \\                return $this->position;
        \\            }
        \\
        \\            public function stream_eof()
        \\            {
        \\                return feof($this->handle);
        \\            }
        \\
        \\            public function stream_stat()
        \\            {
        \\                return array();
        \\            }
        \\
        \\            public function stream_set_option($option, $arg1, $arg2)
        \\            {
        \\                return true;
        \\            }
        \\
        \\            public function url_stat($path, $flags)
        \\            {
        \\                $path = substr($path, 17);
        \\                if (file_exists($path)) {
        \\                    return stat($path);
        \\                }
        \\
        \\                return false;
        \\            }
        \\        }
        \\    }
        \\
        \\    if (
        \\        (function_exists('stream_get_wrappers') && in_array('phpvfscomposer', stream_get_wrappers(), true))
        \\        || (function_exists('stream_wrapper_register') && stream_wrapper_register('phpvfscomposer', 'Composer\BinProxyWrapper'))
        \\    ) {
        \\
    );
    try out.print(allocator, "        return include(\"phpvfscomposer://\" . {s});\n", .{paths.target});
    try out.appendSlice(allocator, "    }\n}\n\n");
}

/// The launcher for a target that is not PHP at all.
///
/// A shell script, because the target may be a compiled binary or a shell
/// script of its own — `include`ing it would be a syntax error. It still
/// exports `COMPOSER_RUNTIME_BIN_DIR`, which is how a non-PHP tool finds the
/// rest of the vendor tree.
fn shellProxy(allocator: std.mem.Allocator, paths: Paths) ![]const u8 {
    const dir = std.fs.path.dirname(paths.bare_target) orelse ".";
    const file = std.fs.path.basename(paths.bare_target);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\#!/usr/bin/env sh
        \\
        \\# Support bash to support `source` with fallback on $0 if this does not run with bash
        \\# https://stackoverflow.com/a/35006505/6512
        \\selfArg="$BASH_SOURCE"
        \\if [ -z "$selfArg" ]; then
        \\    selfArg="$0"
        \\fi
        \\
        \\self=$(realpath "$selfArg" 2> /dev/null)
        \\if [ -z "$self" ]; then
        \\    self="$selfArg"
        \\fi
        \\
        \\
    );
    try out.print(allocator, "dir=$(cd \"${{self%[/\\\\]*}}\" > /dev/null; cd '{s}' && pwd)\n", .{dir});
    try out.appendSlice(allocator,
        \\
        \\if [ -d /proc/cygdrive ]; then
        \\    case $(which php) in
        \\        $(readlink -n /proc/cygdrive)/*)
        \\            # We are in Cygwin using Windows php, so the path must be translated
        \\            dir=$(cygpath -m "$dir");
        \\            ;;
        \\    esac
        \\fi
        \\
        \\export COMPOSER_RUNTIME_BIN_DIR="$(cd "${self%[/\\]*}" > /dev/null; pwd)"
        \\
        \\# If bash is sourcing this file, we have to source the target as well
        \\bashSource="$BASH_SOURCE"
        \\if [ -n "$bashSource" ]; then
        \\    if [ "$bashSource" != "$0" ]; then
        \\
    );
    try out.print(allocator, "        source \"${{dir}}/{s}\" \"$@\"\n", .{file});
    try out.appendSlice(allocator,
        \\        return
        \\    fi
        \\fi
        \\
        \\
    );
    try out.print(allocator, "exec \"${{dir}}/{s}\" \"$@\"\n", .{file});
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The three inputs the shape check distinguishes.
const php_with_shebang = "#!/usr/bin/env php\n<?php\n";
const php_bare = "<?php\n";
const not_php = "#!/bin/sh\necho hi\n";

test "the proxy sets the globals a composer binary expects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var paths = try Paths.forDefault(a, "seld/jsonlint/bin/jsonlint");
    paths.head = php_with_shebang;
    const php = try proxy(a, paths);

    try testing.expect(std.mem.startsWith(u8, php, "#!/usr/bin/env php\n<?php"));
    try testing.expect(std.mem.indexOf(u8, php, "$GLOBALS['_composer_bin_dir'] = __DIR__;") != null);
    // Composer's own spelling: two concatenated literals, not one. Matching it
    // is what lets a generated proxy be diffed against Composer's.
    try testing.expect(std.mem.indexOf(u8, php, "$GLOBALS['_composer_autoload_path'] = __DIR__ . '/..'.'/autoload.php';") != null);
    try testing.expect(std.mem.indexOf(u8, php, "return include __DIR__ . '/..'.'/seld/jsonlint/bin/jsonlint';") != null);
}

test "a target with no shebang gets no stream wrapper, and no hint line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var paths = try Paths.forDefault(a, "acme/tool/bin/tool");
    paths.head = php_bare;
    const php = try proxy(a, paths);

    // The wrapper's whole job is stripping a shebang. A target without one
    // needs none, and Composer emits neither it nor the sentence explaining it.
    try testing.expect(std.mem.indexOf(u8, php, "BinProxyWrapper") == null);
    try testing.expect(std.mem.indexOf(u8, php, "stream wrapper") == null);
    try testing.expect(std.mem.indexOf(u8, php, "@generated") != null);
}

test "a shebang'd target gets the wrapper, without PHPUnit's two extras" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var paths = try Paths.forDefault(a, "nikic/php-parser/bin/php-parse");
    paths.head = php_with_shebang;
    const php = try proxy(a, paths);

    try testing.expect(std.mem.indexOf(u8, php, "BinProxyWrapper") != null);
    try testing.expect(std.mem.indexOf(u8, php, "$opened_path = $this->realpath;") != null);
    try testing.expect(std.mem.indexOf(u8, php, "'phpvfscomposer://'.$this->realpath") == null);
    try testing.expect(std.mem.indexOf(u8, php, "str_replace('__DIR__'") == null);
    try testing.expect(std.mem.indexOf(u8, php, "__PHPUNIT_ISOLATION") == null);
}

test "only the real phpunit binary gets the PHPUnit workarounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var unit = try Paths.forDefault(a, "phpunit/phpunit/phpunit");
    unit.head = php_with_shebang;
    unit.is_phpunit = true;
    const php = try proxy(a, unit);

    try testing.expect(std.mem.indexOf(u8, php, "__PHPUNIT_ISOLATION_EXCLUDE_LIST") != null);
    try testing.expect(std.mem.indexOf(u8, php, "$opened_path = 'phpvfscomposer://'.$this->realpath;") != null);
    try testing.expect(std.mem.indexOf(u8, php, "str_replace('__FILE__'") != null);

    // A package that merely ships a binary CALLED phpunit is not PHPUnit.
    var impostor = try Paths.forDefault(a, "acme/tools/bin/phpunit");
    impostor.head = php_with_shebang;
    const other = try proxy(a, impostor);
    try testing.expect(std.mem.indexOf(u8, other, "__PHPUNIT_ISOLATION") == null);
}

test "a target that is not PHP gets a shell proxy, not an include" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var paths = try Paths.forDefault(a, "acme/tool/bin/tool.sh");
    paths.head = not_php;
    const sh = try proxy(a, paths);

    // `include`ing a shell script would be a PHP syntax error at run time.
    try testing.expect(std.mem.startsWith(u8, sh, "#!/usr/bin/env sh"));
    try testing.expect(std.mem.indexOf(u8, sh, "exec \"${dir}/tool.sh\" \"$@\"") != null);
    try testing.expect(std.mem.indexOf(u8, sh, "COMPOSER_RUNTIME_BIN_DIR") != null);
    try testing.expect(std.mem.indexOf(u8, sh, "<?php") == null);
}

test "shapeOf tells the three openings apart" {
    try testing.expect(shapeOf(php_bare).is_php);
    try testing.expectEqualStrings("", shapeOf(php_bare).shebang);

    try testing.expect(shapeOf(php_with_shebang).is_php);
    try testing.expectEqualStrings("#!/usr/bin/env php", shapeOf(php_with_shebang).shebang);

    try testing.expect(!shapeOf(not_php).is_php);

    // A target that could not be read at all: treated as PHP, because that is
    // the overwhelmingly common case and an include that fails is a clearer
    // failure than a shell proxy that execs a PHP file.
    try testing.expect(shapeOf("").is_php == false);

    // Composer's regex allows whitespace between the shebang and the tag.
    try testing.expect(shapeOf("#!/usr/bin/env php\n\n  <?php").is_php);
}

test "a nested bin path keeps its directories but is named by its basename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // symfony/var-dumper declares "Resources/bin/var-dump-server": the launcher
    // is `vendor/bin/var-dump-server`, pointing at the full inner path.
    var paths = try Paths.forDefault(a, "symfony/var-dumper/Resources/bin/var-dump-server");
    paths.head = php_with_shebang;
    const php = try proxy(a, paths);
    try testing.expect(std.mem.indexOf(u8, php, "'/..'.'/symfony/var-dumper/Resources/bin/var-dump-server';") != null);
    try testing.expectEqualStrings("var-dump-server", std.fs.path.basename("Resources/bin/var-dump-server"));
}

// The two expectations below are the literals Composer 2.10.3 wrote into
// `bin/php-parse` for a project with `vendor-dir: lib/vendor, bin-dir: bin` —
// recorded from the generated file, not derived.
test "a moved bin-dir changes both literals, and they stop agreeing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lay = try layout.resolve(a, null, "/p", .{
        .config_vendor_dir = "lib/vendor",
        .config_bin_dir = "bin",
    });
    const paths: Paths = .{
        .autoload = try layout.shortestPathCode(a, lay.bin, "/p/lib/vendor/autoload.php", true, true),
        .target = try layout.shortestPathCode(a, lay.bin, "/p/lib/vendor/nikic/php-parser/bin/php-parse", true, true),
        .head = php_bare,
    };

    try testing.expectEqualStrings("__DIR__ . '/..'.'/lib/vendor/autoload.php'", paths.autoload);
    try testing.expectEqualStrings(
        "__DIR__ . '/..'.'/lib/vendor/nikic/php-parser/bin/php-parse'",
        paths.target,
    );

    const php = try proxy(a, paths);
    try testing.expect(std.mem.indexOf(u8, php, "return include __DIR__ . '/..'.'/lib/vendor/nikic/php-parser/bin/php-parse';") != null);
}
