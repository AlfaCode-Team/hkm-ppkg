//! PHP class scanner — the input to a generated classmap.
//!
//! Composer runs PHP's own tokenizer over every candidate file. We cannot, so
//! this is a small hand-written lexer over the parts of the grammar that can
//! HIDE a declaration or FAKE one. That distinction is the whole design: a
//! scanner that is merely approximate produces a classmap that maps a class to
//! the wrong file, and the failure surfaces as a fatal "class not found" long
//! after the scan, in a process that never mentions the autoloader.
//!
//! What it therefore understands, and why each one is here:
//!
//!   comments      `// # /* */`      a commented-out `class Foo` is not a class
//!   strings       `'…' "…"`         nor is the word inside a message
//!   heredoc       `<<<EOT … EOT`    which can span the whole file and contain anything
//!   `::class`     `Foo::class`      the constant, not a declaration
//!   `new class`   anonymous class   has no name to map
//!   `namespace`   both forms        the prefix every name in the file carries
//!
//! Deliberately NOT understood: conditional declarations (`if (!class_exists)`),
//! which Composer also maps unconditionally, and `declare(strict_types=1)`,
//! which cannot contain a declaration.

const std = @import("std");

const Io = std.Io;
const Dir = std.Io.Dir;

/// One discovered class, interface, trait or enum.
pub const Found = struct {
    /// Fully qualified, no leading backslash: `Foo\Bar\Baz`.
    fqcn: []const u8,
    /// Path exactly as the caller supplied it, so the emitter can decide how to
    /// spell it relative to the vendor directory.
    path: []const u8,
};

/// Scan one file's SOURCE, appending every declaration to `out`.
pub fn scanSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    out: *std.ArrayList(Found),
) !void {
    var ns: []const u8 = "";
    var i: usize = 0;

    // Everything before the first `<?php` is output, not code.
    i = std.mem.indexOf(u8, source, "<?") orelse return;

    while (i < source.len) {
        const c = source[i];

        // ── things that swallow text ──────────────────────────────────────
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            i = lineEnd(source, i);
            continue;
        }
        if (c == '#') {
            // #[Attribute] is not a comment; the rest of the line is skipped
            // either way because an attribute cannot contain a declaration.
            i = lineEnd(source, i);
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse source.len;
            i = @min(close + 2, source.len);
            continue;
        }
        if (c == '\'' or c == '"') {
            i = stringEnd(source, i);
            continue;
        }
        if (c == '<' and std.mem.startsWith(u8, source[i..], "<<<")) {
            i = heredocEnd(source, i);
            continue;
        }

        // `Foo::class` — skip the operator so `class` is never read as a keyword.
        if (c == ':' and i + 1 < source.len and source[i + 1] == ':') {
            i += 2;
            continue;
        }

        if (!isNameStart(c)) {
            i += 1;
            continue;
        }

        // ── a bare word ───────────────────────────────────────────────────
        const word_end = nameEnd(source, i);
        const word = source[i..word_end];

        // A word directly preceded by `$`, `->` or `\` is a variable, a member
        // or part of a qualified name — never a keyword introducing one.
        if (precededByNameChar(source, i)) {
            i = word_end;
            continue;
        }

        if (eqlKeyword(word, "namespace")) {
            const after = skipSpace(source, word_end);
            // `namespace;` and `namespace\foo()` are the operator form, not a
            // declaration — the latter would otherwise capture a function call
            // as the file's namespace and misqualify every class in it.
            if (after < source.len and (source[after] == ';' or source[after] == '\\')) {
                i = word_end;
                continue;
            }
            const ns_end = qualifiedNameEnd(source, after);
            ns = std.mem.trim(u8, source[after..ns_end], " \t\r\n\\");
            i = ns_end;
            continue;
        }

        if (eqlKeyword(word, "class") or eqlKeyword(word, "interface") or
            eqlKeyword(word, "trait") or eqlKeyword(word, "enum"))
        {
            // `new class {…}` is anonymous, and `enum` is a legal identifier in
            // older code (`$x->enum`, `function enum()`); both are rejected by
            // requiring a NAME to follow and, for class, a keyword not to precede.
            if (eqlKeyword(word, "class") and precededByWord(source, i, "new")) {
                i = word_end;
                continue;
            }

            const name_at = skipSpace(source, word_end);
            if (name_at >= source.len or !isNameStart(source[name_at])) {
                i = word_end;
                continue;
            }
            const name_stop = nameEnd(source, name_at);
            const name = source[name_at..name_stop];

            // `enum` only introduces a declaration when followed by a name AND
            // then a `{`, `:` (backed enum) or `implements`. A function called
            // `enum($x)` would otherwise register its argument as a type.
            if (eqlKeyword(word, "enum") and !enumFollows(source, name_stop)) {
                i = word_end;
                continue;
            }

            const fqcn = if (ns.len == 0)
                try allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ ns, name });

            try out.append(allocator, .{ .fqcn = fqcn, .path = path });
            i = name_stop;
            continue;
        }

        i = word_end;
    }
}

/// Scan every `.php` file under `root`, recursively.
///
/// `exclude` holds ABSOLUTE path prefixes to skip — how
/// `exclude-from-classmap` is honoured.
pub fn scanTree(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    exclude: []const []const u8,
    out: *std.ArrayList(Found),
) !void {
    // A file given where a directory was expected is a legal `classmap` entry.
    if (std.mem.endsWith(u8, root, ".php")) {
        if (excluded(root, exclude)) return;
        const src = Dir.cwd().readFileAlloc(io, root, allocator, .limited(8 * 1024 * 1024)) catch return;
        return scanSource(allocator, src, root, out);
    }

    var d = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer d.close(io);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        // Skip dot-directories: .git alone can hold more files than the source.
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const child = try std.fs.path.join(allocator, &.{ root, entry.name });
        if (excluded(child, exclude)) continue;

        switch (entry.kind) {
            .directory => try scanTree(allocator, io, child, exclude, out),
            .file, .sym_link => {
                if (!std.mem.endsWith(u8, entry.name, ".php")) continue;
                const src = Dir.cwd().readFileAlloc(io, child, allocator, .limited(8 * 1024 * 1024)) catch continue;
                try scanSource(allocator, src, child, out);
            },
            else => {},
        }
    }
}

fn excluded(path: []const u8, exclude: []const []const u8) bool {
    for (exclude) |e| if (e.len > 0 and std.mem.startsWith(u8, path, e)) return true;
    return false;
}

// ── lexer helpers ─────────────────────────────────────────────────────────────

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn nameEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and isNameChar(s[i])) i += 1;
    return i;
}

/// End of a possibly-qualified name (`Foo\Bar\Baz`), for `namespace`.
fn qualifiedNameEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (isNameChar(s[i]) or s[i] == '\\')) i += 1;
    return i;
}

fn skipSpace(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) i += 1;
    return i;
}

fn lineEnd(s: []const u8, start: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse return s.len;
    return nl + 1;
}

/// Index just past a single- or double-quoted string, honouring backslash
/// escapes. An unterminated string consumes the rest of the file, which is the
/// safe direction: the alternative is reading its contents as code.
fn stringEnd(s: []const u8, start: usize) usize {
    const quote = s[start];
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == quote) return i + 1;
    }
    return s.len;
}

/// Index just past a heredoc/nowdoc body.
///
/// The terminator must start a line (optionally indented, as PHP 7.3+ allows)
/// and be followed by a non-name character. Getting this wrong matters more
/// than it looks: a heredoc holding a PHP code sample is common in test
/// fixtures and templates, and treating its body as code invents classes.
fn heredocEnd(s: []const u8, start: usize) usize {
    var i = start + 3;
    i = skipSpace(s, i);

    var quote: u8 = 0;
    if (i < s.len and (s[i] == '\'' or s[i] == '"')) {
        quote = s[i];
        i += 1;
    }

    const label_start = i;
    i = nameEnd(s, i);
    const label = s[label_start..i];
    if (label.len == 0) return start + 3;

    if (quote != 0 and i < s.len and s[i] == quote) i += 1;
    i = lineEnd(s, i);

    while (i < s.len) {
        const line_stop = lineEnd(s, i);
        const line = s[i..line_stop];
        const body = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, body, label)) {
            const after = body[label.len..];
            if (after.len == 0 or !isNameChar(after[0])) return line_stop;
        }
        i = line_stop;
    }
    return s.len;
}

fn eqlKeyword(word: []const u8, kw: []const u8) bool {
    // PHP keywords are case-insensitive; class NAMES are not, but the keyword
    // introducing them is.
    return std.ascii.eqlIgnoreCase(word, kw);
}

/// Is the character before `at` one that makes this word part of something else?
fn precededByNameChar(s: []const u8, at: usize) bool {
    if (at == 0) return false;
    const p = s[at - 1];
    return p == '$' or p == '\\' or p == '>';
}

/// Is `word` the token immediately before position `at`?
fn precededByWord(s: []const u8, at: usize, word: []const u8) bool {
    var i = at;
    while (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == '\r' or s[i - 1] == '\n')) i -= 1;
    if (i < word.len) return false;
    const candidate = s[i - word.len .. i];
    if (!std.ascii.eqlIgnoreCase(candidate, word)) return false;
    // Must be a whole token: `renew class` does not make an anonymous class.
    if (i - word.len > 0 and isNameChar(s[i - word.len - 1])) return false;
    return true;
}

/// After `enum Name`, does a real enum declaration follow?
fn enumFollows(s: []const u8, at: usize) bool {
    const i = skipSpace(s, at);
    if (i >= s.len) return false;
    if (s[i] == '{' or s[i] == ':') return true;
    return std.ascii.startsWithIgnoreCase(s[i..], "implements");
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn scanOne(allocator: std.mem.Allocator, src: []const u8) ![]const Found {
    var out: std.ArrayList(Found) = .empty;
    try scanSource(allocator, src, "t.php", &out);
    return out.toOwnedSlice(allocator);
}

test "namespaced class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\namespace App\Domain;
        \\final class Invoice {}
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("App\\Domain\\Invoice", f[0].fqcn);
}

test "global namespace, several kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\interface A {}
        \\trait B {}
        \\enum C: string { case X = 'x'; }
        \\abstract class D {}
    );
    try testing.expectEqual(@as(usize, 4), f.len);
    try testing.expectEqualStrings("A", f[0].fqcn);
    try testing.expectEqualStrings("C", f[2].fqcn);
    try testing.expectEqualStrings("D", f[3].fqcn);
}

test "comments and strings hide nothing real" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\namespace N;
        \\// class Commented {}
        \\# class Hashed {}
        \\/* class Blocked {} */
        \\$s = 'class Quoted {}';
        \\$d = "class Dquoted {}";
        \\class Real {}
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("N\\Real", f[0].fqcn);
}

test "::class and anonymous classes are not declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\$a = Foo::class;
        \\$b = new class extends Base {};
        \\class Only {}
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("Only", f[0].fqcn);
}

test "heredoc body is not code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\namespace H;
        \\$tpl = <<<PHP
        \\class NotReal {}
        \\PHP;
        \\$now = <<<'RAW'
        \\class AlsoNot {}
        \\RAW;
        \\class Yes {}
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("H\\Yes", f[0].fqcn);
}

test "enum as an identifier is not a declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\$x = $row->enum;
        \\$y = enum($z);
        \\enum Suit { case Hearts; }
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("Suit", f[0].fqcn);
}

test "braced namespace and namespace operator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try scanOne(arena.allocator(),
        \\<?php
        \\namespace Braced {
        \\    class Inner {}
        \\}
    );
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("Braced\\Inner", f[0].fqcn);
}
