//! The standalone binary's terminal — where `report`'s calls land when nothing
//! is hosting the package.
//!
//! It draws the same shape the hkm launcher does (a gutter, a title, a closing
//! line) so `ppkg install` and `hkm ppkg install` read alike, and it follows
//! the same stream rules, each of which exists because its absence was a bug:
//!
//!   * RESULTS go to stdout and DIAGNOSTICS (errors, warnings) to stderr, so
//!     `ppkg show > deps.txt` captures the answer and not the commentary;
//!   * colour is decided per stream — off when `NO_COLOR` is set, when
//!     `TERM=dumb`, or when that stream is not a terminal — and `--ansi` /
//!     `--no-ansi` override the guess;
//!   * `-q` silences stdout and never stderr: a quiet run that fails still says
//!     why.
//!
//! Process-global state, set once in main before anything prints. This is a
//! single-invocation command line, and threading an `Io` through every render
//! helper buys nothing.

const std = @import("std");
const builtin = @import("builtin");
const ppkg = @import("ppkg");

const Io = std.Io;
const EnvMap = std.process.Environ.Map;

var out_io: ?Io = null;
var color_out = false;
var color_err = false;
/// What `init` detected, so `--ansi`/`--no-ansi` can be undone.
var detected_out = false;
var detected_err = false;
var quiet_mode = false;

/// This terminal, as the package's output sink.
pub fn sink() ppkg.report.Sink {
    return .{
        .intro = intro,
        .outro = outro,
        .section = section,
        .item = item,
        .note = note,
        .ok = ok,
        .muted = muted,
        .warn = warn,
        .err = err,
        .blank = blank,
        .raw = raw,
        .quiet = setQuiet,
        .color = setColor,
    };
}

/// Bind the streams and decide colour. Call before anything prints; until it
/// runs, output falls back to `std.debug.print` (stderr).
pub fn init(io: Io, env: *EnvMap) void {
    out_io = io;

    // Presence is what counts for NO_COLOR, not the value — the published
    // convention (no-color.org) — but an empty `NO_COLOR=` is read as unset,
    // which is how every shell spells "remove this".
    const no_color = if (env.get("NO_COLOR")) |v| v.len > 0 else false;
    const dumb = if (env.get("TERM")) |t| std.mem.eql(u8, t, "dumb") else false;

    if (builtin.os.tag == .windows) utf8Console();

    detected_out = !no_color and !dumb and colourCapable(io, std.Io.File.stdout());
    detected_err = !no_color and !dumb and colourCapable(io, std.Io.File.stderr());
    color_out = detected_out;
    color_err = detected_err;
}

/// A terminal that will interpret escape sequences rather than print them.
///
/// On Windows, enabling is what switches the console into VT mode — a legacy
/// console that refuses gets plain text instead of `←[36m` littered through
/// every line. Elsewhere a terminal already understands them.
fn colourCapable(io: Io, file: std.Io.File) bool {
    if (!(file.isTty(io) catch false)) return false;
    file.enableAnsiEscapeCodes(io) catch return false;
    return true;
}

/// Switch the Windows console to UTF-8 output, so the gutter and the glyphs
/// arrive as characters rather than as three bytes each in the console's
/// legacy code page. Best effort: a console that refuses keeps its page.
fn utf8Console() void {
    const kernel32 = struct {
        extern "kernel32" fn SetConsoleOutputCP(code_page: c_uint) callconv(.winapi) c_int;
    };
    _ = kernel32.SetConsoleOutputCP(65001);
}

/// `-q`.
pub fn setQuiet(on: bool) void {
    quiet_mode = on;
}

/// `--ansi` (true), `--no-ansi` (false), or back to what `init` detected (null).
/// Colour on a non-tty is a legitimate request: it is how a CI log viewer that
/// understands ANSI gets coloured output through a pipe.
pub fn setColor(choice: ?bool) void {
    color_out = choice orelse detected_out;
    color_err = choice orelse detected_err;
}

// ── ANSI ──────────────────────────────────────────────────────────────────────

const reset = "\x1b[0m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const green = "\x1b[32m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";
const gray = "\x1b[90m";

/// Format once, then write to the chosen stream — stripping ANSI when that
/// stream is not receiving colour.
///
/// Stripping at write time is deliberate: the styles are concatenated into the
/// format strings at COMPILE time, so making colour conditional at each call
/// site would turn every one into a runtime branch.
fn emit(to_err: bool, comptime fmt: []const u8, args: anytype) void {
    if (quiet_mode and !to_err) return;

    const io = out_io orelse {
        std.debug.print(fmt, args);
        return;
    };
    const file = streamFor(to_err);

    var buf: [8192]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, fmt, args) catch {
        // Longer than the buffer (a pathological path). Write it formatted, on
        // the SAME stream — rerouting an oversized result to stderr would be
        // the stream-mixing bug this file exists to prevent.
        var w = file.writerStreaming(io, &.{});
        w.interface.print(fmt, args) catch {};
        return;
    };

    if (if (to_err) color_err else color_out) {
        file.writeStreamingAll(io, rendered) catch {};
        return;
    }
    var plain: [8192]u8 = undefined;
    file.writeStreamingAll(io, stripAnsi(rendered, &plain)) catch {};
}

fn streamFor(to_err: bool) std.Io.File {
    return if (to_err) std.Io.File.stderr() else std.Io.File.stdout();
}

/// Copy `src` into `dst` with CSI escape sequences removed. `dst` is always
/// large enough, because stripping only ever shortens.
fn stripAnsi(src: []const u8, dst: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        // An ESC always begins something that must not reach a log file, so it
        // is dropped whether or not a complete sequence follows — `emit`
        // renders into a fixed buffer, which can cut a sequence in half.
        if (src[i] == 0x1b) {
            i += 1;
            if (i < src.len and src[i] == '[') {
                i += 1;
                while (i < src.len and !(src[i] >= 0x40 and src[i] <= 0x7E)) i += 1;
                if (i < src.len) i += 1;
            }
            continue;
        }
        if (w >= dst.len) break;
        dst[w] = src[i];
        w += 1;
        i += 1;
    }
    return dst[0..w];
}

/// Display columns, not bytes: a key holding a multi-byte glyph occupies one
/// column, and padding it by its byte length shifts the description left.
fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    emit(false, fmt, args);
}

fn diag(comptime fmt: []const u8, args: anytype) void {
    emit(true, fmt, args);
}

// ── the sink ──────────────────────────────────────────────────────────────────

const bar = dim ++ "│" ++ reset;
const corner_top = green ++ "┌" ++ reset;
const corner_bot = green ++ "└" ++ reset;

pub fn intro(title: []const u8) void {
    out("\n" ++ corner_top ++ "  " ++ bold ++ "{s}" ++ reset ++ "\n" ++ bar ++ "\n", .{title});
}

pub fn outro(message: []const u8) void {
    out(bar ++ "\n" ++ corner_bot ++ "  " ++ green ++ "{s}" ++ reset ++ "\n\n", .{message});
}

pub fn note(line: []const u8) void {
    out(bar ++ "  {s}\n", .{line});
}

pub fn ok(line: []const u8) void {
    out(bar ++ "  " ++ green ++ "✓" ++ reset ++ " {s}\n", .{line});
}

pub fn muted(line: []const u8) void {
    out(bar ++ "  " ++ gray ++ "{s}" ++ reset ++ "\n", .{line});
}

/// stderr: commentary, not the answer.
pub fn warn(line: []const u8) void {
    diag(bar ++ "  " ++ yellow ++ "▲ {s}" ++ reset ++ "\n", .{line});
}

pub fn blank() void {
    out(bar ++ "\n", .{});
}

pub fn section(title: []const u8) void {
    out(bar ++ "  " ++ bold ++ "{s}" ++ reset ++ "\n", .{title});
}

/// A key padded to 30 display columns, then its description. A key at or past
/// the column still gets a gap, or a long usage line reads as one word.
pub fn item(key: []const u8, desc: []const u8) void {
    const w = displayWidth(key);
    if (w >= 30) {
        out(bar ++ "  " ++ cyan ++ "{s}" ++ reset ++ "  " ++ gray ++ "{s}" ++ reset ++ "\n", .{ key, desc });
        return;
    }
    var pad_buf: [30]u8 = undefined;
    const pad = pad_buf[0 .. 30 - w];
    @memset(pad, ' ');
    out(bar ++ "  " ++ cyan ++ "{s}{s}" ++ reset ++ gray ++ "{s}" ++ reset ++ "\n", .{ key, pad, desc });
}

/// stderr, always — including under `-q`.
pub fn err(message: []const u8) void {
    diag("\n" ++ red ++ "■  {s}" ++ reset ++ "\n\n", .{message});
}

/// Verbatim on stdout, one trailing newline, no gutter and no colour — for
/// output a script captures (`ppkg config vendor-dir`, `ppkg --version`).
///
/// Deliberately NOT silenced by `-q`, matching the hkm launcher: `-q` means
/// less narration, and the value a script asked for is not narration.
pub fn raw(block: []const u8) void {
    const io = out_io orelse {
        std.debug.print("{s}\n", .{block});
        return;
    };
    std.Io.File.stdout().writeStreamingAll(io, block) catch {};
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stripAnsi removes every sequence this file emits, and nothing else" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("plain", stripAnsi("plain", &buf));
    try testing.expectEqualStrings("hi", stripAnsi(cyan ++ "hi" ++ reset, &buf));
    try testing.expectEqualStrings("│  ok", stripAnsi(bar ++ "  " ++ green ++ "ok" ++ reset, &buf));
    // A sequence cut in half at the end of the buffer still loses its ESC.
    try testing.expectEqualStrings("x", stripAnsi("x\x1b", &buf));
    // Multi-byte text is not an escape sequence.
    try testing.expectEqualStrings("→ café ✓ ┌", stripAnsi("→ café ✓ ┌", &buf));
}

test "width is counted in columns, not bytes" {
    try testing.expectEqual(@as(usize, 4), displayWidth("ppkg"));
    try testing.expectEqual(@as(usize, 3), displayWidth("a→b"));
}

test "the sink covers every field report defines" {
    // A field left at its no-op default here is output the standalone binary
    // silently drops — `-q` doing nothing, or warnings never appearing.
    const s = sink();
    inline for (@typeInfo(ppkg.report.Sink).@"struct".fields) |f| {
        const default = (ppkg.report.Sink{});
        try testing.expect(@field(s, f.name) != @field(default, f.name));
    }
}
