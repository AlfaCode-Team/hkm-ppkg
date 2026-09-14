//! `scripts` — running the commands a project declares for install events.
//!
//! ## The safety property, stated first
//!
//! **Only the ROOT package's `scripts` are ever run.** A dependency's scripts
//! are read for reporting and never executed. This is Composer's rule too, and
//! it is the whole reason running scripts is defensible: the commands executed
//! are the ones written in the manifest sitting in front of the person who
//! typed the command, not something that arrived in a tarball from the network.
//!
//! Everything else here is downstream of that. `--no-scripts` (or
//! `HKM_PPKG_NO_SCRIPTS=1`) turns it off, and `hkm ppkg compat` still lists what
//! a project declares, so a project can be inspected before it is run.
//!
//! Running them by DEFAULT is the deliberate choice, and it is the safer of the
//! two. A project whose `post-install-cmd` clears a compiled container, writes
//! a `.env`, or builds an asset manifest is not complete without it; an
//! installer that silently skips that step produces a vendor tree that looks
//! finished and an application that is subtly broken, with nothing in the
//! output to explain it.
//!
//! ## What a script entry may be
//!
//! | Written | Meaning |
//! |---|---|
//! | `"phpunit"` | a shell command, with the bin directory on `PATH` |
//! | `"@test"` | another script in the same block |
//! | `"@php bin/console x"` | the PHP binary, whichever one is running this |
//! | `"@composer dump-autoload"` | this tool, so a project does not need Composer |
//! | `"@putenv X=1"` | set a variable for the REST of this event, and nothing else |
//! | `"Acme\\Hooks::afterInstall"` | a static PHP method, called with the autoloader loaded |
//!
//! An entry may also be a LIST of any of the above, run in order, stopping at
//! the first failure — because a script that continues past a failed step
//! reports success for work it did not do.

const std = @import("std");
const layout = @import("layout.zig");
const util = @import("util.zig");
const prompt = @import("report.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{ ScriptFailed, SpawnFailed };

/// The install-lifecycle events this package can raise.
///
/// Composer defines more, but the rest fire per PACKAGE inside the installer's
/// own loop (`pre-package-install`, `post-package-update`, …) and exist to let
/// plugins intervene in an installation step. Nothing here loads plugins, so
/// raising them would be an event with no possible listener.
pub const Event = enum {
    pre_install_cmd,
    post_install_cmd,
    pre_update_cmd,
    post_update_cmd,
    pre_autoload_dump,
    post_autoload_dump,
    post_create_project_cmd,
    pre_status_cmd,
    post_status_cmd,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .pre_install_cmd => "pre-install-cmd",
            .post_install_cmd => "post-install-cmd",
            .pre_update_cmd => "pre-update-cmd",
            .post_update_cmd => "post-update-cmd",
            .pre_autoload_dump => "pre-autoload-dump",
            .post_autoload_dump => "post-autoload-dump",
            .post_create_project_cmd => "post-create-project-cmd",
            .pre_status_cmd => "pre-status-cmd",
            .post_status_cmd => "post-status-cmd",
        };
    }
};

pub const Options = struct {
    /// Do not run anything. `--no-scripts`.
    disabled: bool = false,
    /// `COMPOSER_DEV_MODE`, which scripts branch on.
    dev: bool = true,
    /// The PHP binary `@php` and a PHP callable are run with.
    php: []const u8 = "php",
    /// This executable, for `@composer`. Empty means `@composer` cannot run,
    /// which is reported rather than silently skipped.
    self_binary: []const u8 = "",
    /// Print each command before running it.
    verbose: bool = false,
};

/// Run every command `event` declares in the ROOT manifest.
///
/// Returns the exit code of the first command that failed, or 0. Absent event,
/// absent `scripts` block and `disabled` are all "nothing to do" — 0, silently.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    lay: layout.Layout,
    event: Event,
    opts: Options,
) !u8 {
    if (opts.disabled) return 0;
    if (util.envIsTruthyIn(env, "HKM_PPKG_NO_SCRIPTS")) return 0;

    const source = Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(allocator, &.{ lay.root, "composer.json" }),
        allocator,
        .limited(8 * 1024 * 1024),
    ) catch return 0;

    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch return 0;
    if (root != .object) return 0;
    const scripts = root.object.get("scripts") orelse return 0;
    if (scripts != .object) return 0;

    var ctx = Context{
        .allocator = allocator,
        .io = io,
        .env = try dup(allocator, env, lay, opts),
        .lay = lay,
        .scripts = scripts.object,
        .opts = opts,
    };
    return ctx.dispatch(event.name(), 0);
}

/// Run a script by NAME rather than by event — `hkm ppkg run-script test`.
///
/// The same block holds a project's own tasks and its install hooks, and both
/// are reached the same way; the only difference is that an event name is one
/// this package raises and a task name is one a person types.
pub fn runNamed(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    lay: layout.Layout,
    name: []const u8,
    opts: Options,
) !u8 {
    if (opts.disabled) return 0;

    const source = Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(allocator, &.{ lay.root, "composer.json" }),
        allocator,
        .limited(8 * 1024 * 1024),
    ) catch {
        prompt.err("No composer.json here.");
        return 1;
    };

    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch {
        prompt.err("composer.json could not be parsed.");
        return 1;
    };
    const block = if (root == .object) root.object.get("scripts") else null;
    if (block == null or block.? != .object or block.?.object.get(name) == null) {
        prompt.err(try std.fmt.allocPrint(
            allocator,
            "No script named '{s}'. Run `ppkg run-script --list` to see what is declared.",
            .{name},
        ));
        return 1;
    }

    var ctx = Context{
        .allocator = allocator,
        .io = io,
        .env = try dup(allocator, env, lay, opts),
        .lay = lay,
        .scripts = block.?.object,
        .opts = opts,
    };
    return ctx.dispatch(name, 0);
}

/// What a project declares, for reporting without running anything.
pub fn declared(allocator: std.mem.Allocator, root: std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (root != .object) return out.toOwnedSlice(allocator);
    const scripts = root.object.get("scripts") orelse return out.toOwnedSlice(allocator);
    if (scripts != .object) return out.toOwnedSlice(allocator);
    var it = scripts.object.iterator();
    while (it.next()) |e| try out.append(allocator, e.key_ptr.*);
    return out.toOwnedSlice(allocator);
}

const Context = struct {
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    lay: layout.Layout,
    scripts: std.json.ObjectMap,
    opts: Options,

    /// Run one named script. `depth` bounds `@self` recursion, which a manifest
    /// can otherwise make unbounded with two scripts that call each other.
    /// The error set is written out rather than inferred: `dispatch` and `one`
    /// call each other, and Zig cannot infer two mutually recursive sets.
    const Fail = std.mem.Allocator.Error;

    fn dispatch(self: *Context, name: []const u8, depth: usize) Fail!u8 {
        if (depth > 16) {
            prompt.err("scripts: too deeply nested — a script referring to itself?");
            return 1;
        }

        const entry = self.scripts.get(name) orelse return 0;
        switch (entry) {
            .string => |cmd| return self.one(cmd, depth),
            .array => |list| {
                for (list.items) |item| {
                    if (item != .string) continue;
                    const code = try self.one(item.string, depth);
                    // Stop at the first failure. Continuing would run the rest
                    // of a sequence whose precondition did not hold.
                    if (code != 0) return code;
                }
                return 0;
            },
            else => return 0,
        }
    }

    fn one(self: *Context, raw: []const u8, depth: usize) Fail!u8 {
        const cmd = std.mem.trim(u8, raw, " \t\r\n");
        if (cmd.len == 0) return 0;

        if (cmd[0] == '@') {
            const space = std.mem.indexOfScalar(u8, cmd, ' ');
            const word = if (space) |at| cmd[1..at] else cmd[1..];
            const rest = if (space) |at| std.mem.trim(u8, cmd[at + 1 ..], " \t") else "";

            if (std.mem.eql(u8, word, "putenv")) return self.putenv(rest);
            if (std.mem.eql(u8, word, "php")) return self.spawnShell(
                try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ self.opts.php, rest }),
            );
            if (std.mem.eql(u8, word, "composer")) {
                if (self.opts.self_binary.len == 0) {
                    prompt.warn(try std.fmt.allocPrint(
                        self.allocator,
                        "scripts: '@composer {s}' skipped — this build does not know its own path.",
                        .{rest},
                    ));
                    return 0;
                }
                return self.spawnShell(try std.fmt.allocPrint(
                    self.allocator,
                    "{s} {s}",
                    .{ self.opts.self_binary, rest },
                ));
            }
            // `@some-script` — another entry in the same block.
            return self.dispatch(word, depth + 1);
        }

        // `Vendor\Class::method` — a PHP callable, not a program on PATH.
        if (isCallable(cmd)) return self.callable(cmd);

        return self.spawnShell(cmd);
    }

    /// `@putenv KEY=VALUE` — scoped to the rest of THIS event, because `env` is
    /// a copy made per `run()` call and never written back to the process.
    fn putenv(self: *Context, assignment: []const u8) Fail!u8 {
        const at = std.mem.indexOfScalar(u8, assignment, '=') orelse {
            try self.env.put(assignment, "");
            return 0;
        };
        try self.env.put(assignment[0..at], assignment[at + 1 ..]);
        return 0;
    }

    /// A static method call, run in a PHP process that has the project's
    /// autoloader loaded.
    ///
    /// Composer calls it in-process, which lets a callable inspect the
    /// `Event` object it is handed. That object is Composer's own API and is
    /// not reproduced: a callable expecting one gets a PHP error naming the
    /// missing class, which is a better outcome than a silent no-op.
    fn callable(self: *Context, spec: []const u8) Fail!u8 {
        const autoload = try std.fs.path.join(self.allocator, &.{ self.lay.vendor, "autoload.php" });
        if (!util.fileExists(self.io, autoload)) {
            prompt.warn(try std.fmt.allocPrint(
                self.allocator,
                "scripts: '{s}' needs {s}, which does not exist yet.",
                .{ spec, autoload },
            ));
            return 0;
        }

        // Single-quoted in the PHP source with `'` escaped, so a class name can
        // never close the literal and become code.
        const php = try std.fmt.allocPrint(
            self.allocator,
            "require {s}; $c = {s}; if (!is_callable($c)) {{ fwrite(STDERR, \"script callable not found: \" . {s} . PHP_EOL); exit(1); }} $r = $c(); exit(is_int($r) ? $r : 0);",
            .{
                try phpLiteral(self.allocator, autoload),
                try phpLiteral(self.allocator, spec),
                try phpLiteral(self.allocator, spec),
            },
        );

        return self.spawn(&.{ self.opts.php, "-r", php });
    }

    /// Run a command line through the shell, as Composer's ProcessExecutor
    /// does: `scripts` entries in the wild use pipes, `&&`, globs and quoting,
    /// and splitting on spaces would break every one of them.
    fn spawnShell(self: *Context, cmd: []const u8) Fail!u8 {
        if (self.opts.verbose) prompt.muted(try std.fmt.allocPrint(self.allocator, "  > {s}", .{cmd}));
        return self.spawn(&.{ "/bin/sh", "-c", cmd });
    }

    fn spawn(self: *Context, argv: []const []const u8) Fail!u8 {
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.env,
            .cwd = .{ .path = self.lay.root },
            // Scripts are the user's own commands: their output is the point,
            // and an interactive one may legitimately want stdin.
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch {
            prompt.err(try std.fmt.allocPrint(self.allocator, "scripts: could not run '{s}'.", .{argv[argv.len - 1]}));
            return 1;
        };

        return switch (child.wait(self.io) catch return 1) {
            .exited => |code| code,
            else => 1,
        };
    }
};

/// The environment a script sees: the caller's, plus the bin directory at the
/// FRONT of `PATH` and the `COMPOSER_*` variables scripts read.
fn dup(
    allocator: std.mem.Allocator,
    env: *EnvMap,
    lay: layout.Layout,
    opts: Options,
) !*EnvMap {
    const out = try allocator.create(EnvMap);
    out.* = .init(allocator);

    var it = env.iterator();
    while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);

    // `"test": "phpunit"` resolves to the project's own phpunit, not whichever
    // one happens to be installed globally. Prepended, so the project wins.
    const path = env.get("PATH") orelse "";
    try out.put("PATH", try std.fmt.allocPrint(allocator, "{s}:{s}", .{ lay.bin, path }));

    try out.put("COMPOSER_DEV_MODE", if (opts.dev) "1" else "0");
    try out.put("COMPOSER_BIN_DIR", lay.bin);
    try out.put("COMPOSER_VENDOR_DIR", lay.vendor);
    if (opts.self_binary.len > 0) try out.put("COMPOSER_BINARY", opts.self_binary);
    return out;
}

/// `Vendor\Class::method` — a `::` outside any whitespace.
fn isCallable(cmd: []const u8) bool {
    const at = std.mem.indexOf(u8, cmd, "::") orelse return false;
    if (at == 0 or at + 2 >= cmd.len) return false;
    // A shell command containing `::` would also contain a space or a slash
    // before it; a callable is one bare token.
    for (cmd) |c| {
        if (c == ' ' or c == '\t' or c == '/' or c == '|' or c == '&') return false;
    }
    return true;
}

/// A PHP single-quoted string literal.
fn phpLiteral(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\\' or c == '\'') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "every event has the name composer.json spells" {
    try testing.expectEqualStrings("post-install-cmd", Event.post_install_cmd.name());
    try testing.expectEqualStrings("pre-update-cmd", Event.pre_update_cmd.name());
    try testing.expectEqualStrings("post-autoload-dump", Event.post_autoload_dump.name());
}

test "a callable is told apart from a shell command" {
    try testing.expect(isCallable("Acme\\Hooks::afterInstall"));
    try testing.expect(isCallable("Composer\\Config::disableProcessTimeout"));

    // These are commands that happen to contain `::` or look similar.
    try testing.expect(!isCallable("phpunit"));
    try testing.expect(!isCallable("php -r 'X::y();'"));
    try testing.expect(!isCallable("bin/console cache:clear"));
    try testing.expect(!isCallable("./x::y"));
    try testing.expect(!isCallable("::y"));
    try testing.expect(!isCallable("X::"));
}

test "a class name cannot escape the PHP literal it is put in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("'Acme\\\\Hooks::run'", try phpLiteral(a, "Acme\\Hooks::run"));
    // The injection attempt: a quote in the name closes nothing.
    try testing.expectEqualStrings(
        "'x\\'; system(\\'rm -rf /\\'); \\''",
        try phpLiteral(a, "x'; system('rm -rf /'); '"),
    );
}

test "declared lists a project's script events without running any" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"scripts": {"post-install-cmd": "x", "test": ["a", "b"]}}
    , .{});
    const events = try declared(a, root);
    try testing.expectEqual(@as(usize, 2), events.len);

    // No scripts block at all, and a non-object one, are both empty.
    try testing.expectEqual(@as(usize, 0), (try declared(a, try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"name": "acme/app"}
    , .{}))).len);
}
