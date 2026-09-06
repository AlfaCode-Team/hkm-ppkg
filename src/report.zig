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
};

fn ignoreLine(_: []const u8) void {}
fn ignorePair(_: []const u8, _: []const u8) void {}
fn ignoreNothing() void {}

var sink: Sink = .{};

/// Install a host's output. Call once, before any command runs.
pub fn use(s: Sink) void {
    sink = s;
}

/// Drop back to silence. Mainly for tests that assert on a function which
/// otherwise narrates itself into the test runner's output.
pub fn silence() void {
    sink = .{};
}

pub fn intro(title: []const u8) void {
    sink.intro(title);
}
pub fn outro(message: []const u8) void {
    sink.outro(message);
}
pub fn section(title: []const u8) void {
    sink.section(title);
}
pub fn item(key: []const u8, desc: []const u8) void {
    sink.item(key, desc);
}
pub fn note(line: []const u8) void {
    sink.note(line);
}
pub fn ok(line: []const u8) void {
    sink.ok(line);
}
pub fn muted(line: []const u8) void {
    sink.muted(line);
}
pub fn warn(line: []const u8) void {
    sink.warn(line);
}
pub fn err(message: []const u8) void {
    sink.err(message);
}
pub fn blank() void {
    sink.blank();
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
    silence();
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
