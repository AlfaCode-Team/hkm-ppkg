//! Where this package's progress output goes.
//!
//! A library that writes to stdout on its own decides the host's interface for
//! it. So nothing here prints by default: the sink is a set of function
//! pointers, every one of them a no-op until a host installs its own.
//!
//!     const pkg = @import("pkg");
//!     pkg.report.use(.{ .intro = myIntro, .item = myItem, ... });
//!
//! The signatures are deliberately plain `void` functions over already-formatted
//! strings. An output layer that could fail, or that needed an allocator,
//! would push its failure modes into every call site in the resolver — and
//! there is nothing sensible for a resolver to do about a closed stdout.
//!
//! One consequence worth stating: this is process-global mutable state, set
//! once at startup. It is not per-call context, and a host that resolves on
//! several threads gets one shared sink. That is the same trade every logging
//! facade makes, and the alternative — threading a writer through every
//! function that might mention a package — buys nothing here.

const std = @import("std");

/// The output surface. Every field defaults to doing nothing.
pub const Sink = struct {
    /// Opens a run: a title above the work that follows.
    intro: *const fn (title: []const u8) void = ignoreLine,
    /// Closes a run: the one-line result.
    outro: *const fn (message: []const u8) void = ignoreLine,
    /// A heading within a run.
    section: *const fn (title: []const u8) void = ignoreLine,
    /// A key/value row — the shape most of this package's output takes.
    item: *const fn (key: []const u8, desc: []const u8) void = ignorePair,
    /// Ordinary informational line.
    note: *const fn (line: []const u8) void = ignoreLine,
    /// Something completed.
    ok: *const fn (line: []const u8) void = ignoreLine,
    /// Secondary detail, safe to skim past.
    muted: *const fn (line: []const u8) void = ignoreLine,
    /// Something the user should look at, but which did not stop the run.
    warn: *const fn (line: []const u8) void = ignoreLine,
    /// Something that stopped the run.
    err: *const fn (message: []const u8) void = ignoreLine,
    /// Vertical space.
    blank: *const fn () void = ignoreNothing,
    /// UNDECORATED output — no prefix, no frame, no colour.
    ///
    /// For the commands whose output is data rather than narration:
    /// `config vendor-dir` prints a path that a shell will capture, and a
    /// leading `│ ` in it is a bug in every script that reads it.
    raw: *const fn (text: []const u8) void = ignoreLine,
    /// `-q`: stop writing results to stdout. Diagnostics still reach stderr —
    /// a quiet run that fails must still say why.
    quiet: *const fn (on: bool) void = ignoreBool,
    /// `--ansi` / `--no-ansi`: force colour on or off; null returns to
    /// whatever the host detected.
    color: *const fn (choice: ?bool) void = ignoreChoice,
};

fn ignoreLine(_: []const u8) void {}
fn ignorePair(_: []const u8, _: []const u8) void {}
fn ignoreNothing() void {}
fn ignoreBool(_: bool) void {}
fn ignoreChoice(_: ?bool) void {}

var sink: Sink = .{};

/// How the user invokes this tool. See `setProgram`.
var program: []const u8 = "ppkg";

/// Install a host's output. Call once, before any command runs.
pub fn use(s: Sink) void {
    sink = s;
}

/// Drop back to silence. Mainly for tests that assert on a function which
/// otherwise narrates itself into the test runner's output.
pub fn silence() void {
    sink = .{};
    program = "ppkg";
}

/// Spell the tool the way the user invokes it.
///
/// Every message in this package names its commands as `ppkg …`: titles open
/// with it ("ppkg install") and prose quotes it ("run `ppkg install`"). A host
/// that embeds the package as a subcommand is invoked differently, and telling
/// its user to run a `ppkg` that is not on their PATH is a wrong instruction.
///
/// So the command word is rewritten here, once, on the way out — and ONLY in
/// those two positions: at the very start of a line, or straight after a
/// backtick. Anywhere else "ppkg" is data (a package called `acme/ppkg`, a
/// description, a URL ending in `hkm-ppkg`) and passes through untouched, and
/// so does everything written with `raw`, which exists to be captured.
pub fn setProgram(name: []const u8) void {
    program = if (name.len > 0) name else "ppkg";
}

/// `s` with the command word respelled into `buf`, or `s` itself when there is
/// nothing to rewrite — or when the result would not fit, since a line that
/// says `ppkg` is better than a line cut short.
fn spell(s: []const u8, buf: []u8) []const u8 {
    if (std.mem.eql(u8, program, "ppkg")) return s;
    if (std.mem.indexOf(u8, s, "ppkg") == null) return s;

    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (isCommandAt(s, i)) {
            if (w + program.len > buf.len) return s;
            @memcpy(buf[w..][0..program.len], program);
            w += program.len;
            i += "ppkg".len;
            continue;
        }
        if (w >= buf.len) return s;
        buf[w] = s[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

fn isCommandAt(s: []const u8, i: usize) bool {
    if (!std.mem.startsWith(u8, s[i..], "ppkg")) return false;
    const after = i + "ppkg".len;
    if (after < s.len and s[after] != ' ' and s[after] != '`') return false;
    return i == 0 or s[i - 1] == '`';
}

// The buffers are on the stack of each forwarding function rather than shared:
// resolution prefetches on several threads, and a shared buffer would let one
// thread's line be overwritten while another's sink is still reading it.

pub fn intro(title: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.intro(spell(title, &buf));
}
pub fn outro(message: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.outro(spell(message, &buf));
}
pub fn section(title: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.section(spell(title, &buf));
}
pub fn item(key: []const u8, desc: []const u8) void {
    var kbuf: [4096]u8 = undefined;
    var dbuf: [4096]u8 = undefined;
    sink.item(spell(key, &kbuf), spell(desc, &dbuf));
}
pub fn note(line: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.note(spell(line, &buf));
}
pub fn ok(line: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.ok(spell(line, &buf));
}
pub fn muted(line: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.muted(spell(line, &buf));
}
pub fn warn(line: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.warn(spell(line, &buf));
}
pub fn err(message: []const u8) void {
    var buf: [4096]u8 = undefined;
    sink.err(spell(message, &buf));
}
/// Verbatim — never respelled. See `setProgram`.
pub fn raw(text: []const u8) void {
    sink.raw(text);
}

pub fn blank() void {
    sink.blank();
}

pub fn setQuiet(on: bool) void {
    sink.quiet(on);
}
pub fn setColor(choice: ?bool) void {
    sink.color(choice);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

var seen_lines: usize = 0;
var seen_pairs: usize = 0;

fn countLine(_: []const u8) void {
    seen_lines += 1;
}
fn countPair(_: []const u8, _: []const u8) void {
    seen_pairs += 1;
}

test "the default sink swallows everything" {
    // The property that matters: importing this package and never configuring
    // it must not write to a host's stdout. A library that greets you is a
    // library you cannot embed.
    //
    // Asserted on the pointers rather than by calling and observing nothing,
    // because "no output appeared" is not something a test can see — it is what
    // a test that forgot to assert also looks like.
    silence();
    try testing.expectEqual(&ignoreLine, sink.intro);
    try testing.expectEqual(&ignoreLine, sink.outro);
    try testing.expectEqual(&ignoreLine, sink.section);
    try testing.expectEqual(&ignorePair, sink.item);
    try testing.expectEqual(&ignoreLine, sink.note);
    try testing.expectEqual(&ignoreLine, sink.ok);
    try testing.expectEqual(&ignoreLine, sink.muted);
    try testing.expectEqual(&ignoreLine, sink.warn);
    try testing.expectEqual(&ignoreLine, sink.err);
    try testing.expectEqual(&ignoreNothing, sink.blank);
    try testing.expectEqual(&ignoreBool, sink.quiet);
    try testing.expectEqual(&ignoreChoice, sink.color);

    // And calling through them is still safe with nothing installed.
    intro("quiet");
    item("k", "v");
    err("nothing should appear");
    blank();
}

test "an installed sink receives the calls, and silence() removes it" {
    seen_lines = 0;
    seen_pairs = 0;
    use(.{ .intro = countLine, .warn = countLine, .item = countPair });
    defer silence();

    intro("a");
    warn("b");
    item("k", "v");
    // Unset fields keep their no-op default rather than falling back to some
    // other field — partial installation is the expected way to use this.
    note("not counted");

    try testing.expectEqual(@as(usize, 2), seen_lines);
    try testing.expectEqual(@as(usize, 1), seen_pairs);

    silence();
    intro("ignored now");
    try testing.expectEqual(@as(usize, 2), seen_lines);
}

test "the command word is respelled for a host, and nothing else is" {
    var buf: [256]u8 = undefined;
    defer silence();

    // Standalone: nothing to do, and the input comes back untouched.
    setProgram("ppkg");
    try testing.expectEqualStrings("ppkg install", spell("ppkg install", &buf));

    setProgram("hkm ppkg");
    // A title, and a command quoted in prose.
    try testing.expectEqualStrings("hkm ppkg install", spell("ppkg install", &buf));
    try testing.expectEqualStrings("hkm ppkg", spell("ppkg", &buf));
    try testing.expectEqualStrings("Run `hkm ppkg install` first.", spell("Run `ppkg install` first.", &buf));
    try testing.expectEqualStrings("`hkm ppkg`", spell("`ppkg`", &buf));

    // Data that merely CONTAINS the word is left alone: a package name, a URL,
    // a description mid-sentence.
    try testing.expectEqualStrings("acme/ppkg", spell("acme/ppkg", &buf));
    try testing.expectEqualStrings("https://github.com/AlfaCode-Team/hkm-ppkg", spell("https://github.com/AlfaCode-Team/hkm-ppkg", &buf));
    try testing.expectEqualStrings("a wrapper for ppkg users", spell("a wrapper for ppkg users", &buf));
    try testing.expectEqualStrings("ppkgs are fun", spell("ppkgs are fun", &buf));

    // Already spelled for the host: rewriting must not stack a second prefix.
    try testing.expectEqualStrings("hkm ppkg install", spell("hkm ppkg install", &buf));
    try testing.expectEqualStrings("Run `hkm ppkg install`.", spell("Run `hkm ppkg install`.", &buf));

    // Too long to respell: the original beats a truncated line.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("ppkg install", spell("ppkg install", &tiny));
}

var quiet_seen: ?bool = null;
fn recordQuiet(on: bool) void {
    quiet_seen = on;
}

test "quiet and colour reach the host, and raw output is never respelled" {
    quiet_seen = null;
    seen_lines = 0;
    use(.{ .quiet = recordQuiet, .raw = countLine });
    defer silence();

    setQuiet(true);
    try testing.expectEqual(@as(?bool, true), quiet_seen);
    // Unset: a no-op rather than a crash.
    setColor(false);

    setProgram("hkm ppkg");
    raw("ppkg 1.0.0");
    try testing.expectEqual(@as(usize, 1), seen_lines);
}
