//! `ppkg` — the standalone binary.
//!
//! Everything it does is the package's own command line (`src/cli.zig`); this
//! file only supplies what a host always supplies — a terminal to print on,
//! the version it was built as, and where it sits on disk — and exits with the
//! code the command returned.
//!
//! It imports the package as the `ppkg` MODULE, exactly as any other host
//! would, so the binary cannot reach anything a host could not.

const std = @import("std");
const ppkg = @import("ppkg");
const build_info = @import("build_info");
const term = @import("term.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    // A real allocator-backed Threaded io, with the process environment handed
    // to it. `environ` is not decoration: std.Io.Threaded resolves a bare
    // command name (`php`, `git`, `unzip`) against the PATH held by the Io
    // instance, and left empty it falls back to a fixed list that does not
    // include /opt/homebrew/bin — every spawn of a Homebrew `php` on Apple
    // Silicon would fail with FileNotFound.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // One arena for the whole run: a command line that exits when the command
    // does has nothing to gain from freeing piecemeal.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try init.environ.createMap(allocator);

    term.init(io, &env);
    ppkg.report.use(term.sink());

    const argv = try init.args.toSlice(allocator);
    const args = try allocator.alloc([]const u8, argv.len -| 1);
    for (args, 1..) |*a, i| a.* = argv[i];

    // Where this binary is: `self-update` guesses from it how it was installed,
    // and `@composer` in a project's scripts re-enters through it.
    const exe: []const u8 = std.process.executablePathAlloc(io, allocator) catch "";

    const code = ppkg.cli.run(allocator, io, &env, args, .{
        .program = "ppkg",
        .version = build_info.version,
        .executable = exe,
        .self_command = exe,
    }) catch |e| {
        ppkg.report.err(std.fmt.allocPrint(allocator, "ppkg stopped: {s}", .{@errorName(e)}) catch "ppkg stopped.");
        std.process.exit(1);
    };
    std.process.exit(code);
}

test {
    _ = term;
}
