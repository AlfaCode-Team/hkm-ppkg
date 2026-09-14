//! The `ppkg` command line — argument parsing, dispatch and reporting for every
//! Composer command this package implements.
//!
//! It lives in the package rather than in any one host so that there is ONE
//! front-end. The standalone `ppkg` binary (app/main.zig) and a host that embeds
//! the package as a subcommand (`hkm ppkg`) run exactly this code; what differs
//! between them — the version, where releases are published, where the binary
//! lives, any commands the host adds — arrives in `Options`, and nothing else.
//!
//! Output goes through `report`, like the rest of the package. The text below
//! spells the tool `ppkg`; a host that spells it differently passes its own
//! `Options.program` and `report` rewrites the command on its way out.

const std = @import("std");
const ppkg = @import("root.zig");
const report = @import("report.zig");
const util = @import("util.zig");
const manifest = ppkg.manifest;
const autoload = ppkg.autoload;
const installer = ppkg.install;
const lockfile = ppkg.lock;
const inspect = ppkg.inspect;
const resolver = ppkg.resolve;

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

/// What the host running this command line knows and the package cannot.
pub const Options = struct {
    /// How a user invokes the tool: `ppkg` for the standalone binary, the whole
    /// prefix (`hkm ppkg`) for a host that embeds it as a subcommand.
    program: []const u8 = "ppkg",
    /// The running release, for `--version` and `self-update`. Empty = unknown.
    version: []const u8 = "",
    /// The GitHub `owner/repo` whose releases `self-update` compares against.
    release_repo: []const u8 = "AlfaCode-Team/hkm-ppkg",
    /// Absolute path of the running executable, or empty when unknown.
    /// `self-update` guesses from it how the binary was installed.
    executable: []const u8 = "",
    /// The command line that re-enters this tool — `/usr/local/bin/ppkg`, or
    /// `/opt/hkm/bin/hkm ppkg`. `@composer` in a script and COMPOSER_BINARY use
    /// it. Empty = unknown, and a `@composer` entry is reported as skipped
    /// rather than run through a path that might be wrong.
    self_command: []const u8 = "",
    /// Commands a host adds on top of the package's own.
    extension: ?Extension = null,
};

/// A host's own subcommands — `hkm ppkg test-env`, which builds a vendor/ out
/// of an hkm kernel and so has no business in a package manager.
pub const Extension = struct {
    /// Offered any word the package does not recognise as a command of its
    /// own, with the global flags already applied and stripped from `rest`.
    /// Returns the exit code of a command it ran, or null to decline the word.
    /// A host cannot redefine a package command.
    dispatch: *const fn (
        allocator: std.mem.Allocator,
        io: Io,
        env: *EnvMap,
        sub: []const u8,
        rest: []const []const u8,
    ) anyerror!?u8,
    /// Extra rows for the command index, spelled like the package's own:
    /// `.{ "ppkg test-env <dir>", "what it does" }`.
    usage: []const [2][]const u8 = &.{},
    /// Extra words for shell completion, space-separated.
    words: []const u8 = "",
};

/// Set once per `run`. Process-global for the same reason `report`'s sink is:
/// this is a single-invocation command line, and threading the options through
/// forty command functions to reach the three that read them buys nothing.
var host: Options = .{};

/// `ppkg …` — `args` begins at the subcommand: `argv[1..]` for the standalone
/// binary, `argv[2..]` under a host's `hkm ppkg`.
///
/// `global` is peeled off HERE rather than being dispatched as a command of its
/// own. It is a prefix, not an operation: it means "run the following command
/// in `$COMPOSER_HOME`", and handling it by re-entering the dispatcher would
/// make the two mutually recursive — which Zig cannot infer an error set
/// through, and which would also let `global global global` nest arbitrarily.
pub fn run(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8, options: Options) !u8 {
    host = options;
    report.setProgram(options.program);

    if (args.len > 0 and eq(args[0], "global")) {
        if (args.len == 1) {
            report.err("Which command? `ppkg global <subcommand> …`.");
            return 2;
        }
        const home = ppkg.project.globalDir(allocator, io, env) orelse {
            report.err("$COMPOSER_HOME could not be determined — set COMPOSER_HOME or HOME.");
            return 1;
        };
        report.note(try std.fmt.allocPrint(allocator, "Operating in {s}", .{home}));

        // `PWD` is what `util.absPath` resolves a relative path against, so
        // setting it is what makes every downstream command treat the global
        // directory as the project — including the ones that take no path
        // argument at all.
        var scoped: EnvMap = .init(allocator);
        var it = env.iterator();
        while (it.next()) |e| try scoped.put(e.key_ptr.*, e.value_ptr.*);
        try scoped.put("PWD", home);

        return usageErrors(dispatch(allocator, io, &scoped, args[1..]));
    }
    return usageErrors(dispatch(allocator, io, env, args));
}

/// A malformed invocation is exit code 2, like every other usage error here.
///
/// `error.MissingValue` comes only from `takeGlobals`, which has already said
/// what was wrong; letting it reach the binary's top level printed a second,
/// less useful line ("ppkg stopped: MissingValue") and exited 1.
fn usageErrors(result: anyerror!u8) anyerror!u8 {
    return result catch |e| switch (e) {
        error.MissingValue => 2,
        else => e,
    };
}

// ── options every command accepts ─────────────────────────────────────────────

/// The flags Composer puts on EVERY command.
///
/// They are peeled off before dispatch rather than repeated in each command's
/// own loop, for two reasons. A caller who learns that `-q` works on `install`
/// is entitled to expect it on `show`; and every per-command loop ends in
/// "unknown option", so a global flag missing from one of them is not ignored —
/// it is a hard error on a flag the tool documents as universal.
const Global = struct {
    /// `-q` — stdout only. Errors still reach stderr; see report.setQuiet.
    quiet: bool = false,
    /// `-v`, `-vv`, `-vvv`. Accepted and recorded; this tool's output is not
    /// yet tiered, so it currently changes nothing and says so under --help
    /// rather than pretending.
    verbosity: u8 = 0,
    /// `-n` — never report. Anything that would ask takes its default.
    no_interaction: bool = false,
    /// `--profile` — print elapsed wall time and peak RSS at the end.
    profile: bool = false,
    /// `--no-cache` — do not read or write the download/metadata cache.
    no_cache: bool = false,
    /// `--no-plugins` — accepted and INERT: nothing here loads a composer
    /// plugin, so the flag already describes this tool's behaviour. Accepting
    /// it matters because build scripts pass it unconditionally.
    no_plugins: bool = false,
    /// `--ansi` / `--no-ansi`.
    ansi: ?bool = null,
    /// `-d` / `--working-dir`.
    working_dir: ?[]const u8 = null,
};

/// Recognise the global flag at `args[i.*]` and record it in `g`, advancing
/// `i` past a value it consumes (`-d DIR`). False when it is not one.
///
/// The ONE list of what counts as a global flag: `takeGlobals` and
/// `leadingGlobals` both read it, so "is this ours?" cannot be answered two
/// different ways.
fn applyGlobal(g: *Global, args: []const []const u8, i: *usize) error{MissingValue}!bool {
    const a = args[i.*];
    if (eq(a, "-q") or eq(a, "--quiet")) {
        g.quiet = true;
    } else if (eq(a, "-v") or eq(a, "--verbose")) {
        g.verbosity = @max(g.verbosity, 1);
    } else if (eq(a, "-vv")) {
        g.verbosity = @max(g.verbosity, 2);
    } else if (eq(a, "-vvv")) {
        g.verbosity = 3;
    } else if (eq(a, "-n") or eq(a, "--no-interaction")) {
        g.no_interaction = true;
    } else if (eq(a, "--profile")) {
        g.profile = true;
    } else if (eq(a, "--no-cache")) {
        g.no_cache = true;
    } else if (eq(a, "--no-plugins")) {
        g.no_plugins = true;
    } else if (eq(a, "--ansi")) {
        g.ansi = true;
    } else if (eq(a, "--no-ansi")) {
        g.ansi = false;
    } else if (eq(a, "-d") or eq(a, "--working-dir")) {
        if (i.* + 1 >= args.len) return error.MissingValue;
        i.* += 1;
        g.working_dir = args[i.*];
    } else if (std.mem.startsWith(u8, a, "--working-dir=")) {
        g.working_dir = a["--working-dir=".len..];
    } else {
        return false;
    }
    return true;
}

/// Strip the global flags out of `args` and apply the ones with an immediate
/// effect. Returns the arguments the command itself should parse.
fn takeGlobals(allocator: std.mem.Allocator, args: []const []const u8, g: *Global) ![]const []const u8 {
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    // Everything after a bare `--` belongs to the command (or to a program it
    // runs), and must not be examined for flags of ours.
    var terminated = false;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (terminated) {
            try rest.append(allocator, a);
            continue;
        }
        if (eq(a, "--")) {
            terminated = true;
            try rest.append(allocator, a);
            continue;
        }
        const taken = applyGlobal(g, args, &i) catch |e| {
            report.err("--working-dir needs a directory.");
            return e;
        };
        if (!taken) try rest.append(allocator, a);
    }

    report.setQuiet(g.quiet);
    report.setColor(g.ansi);
    return rest.toOwnedSlice(allocator);
}

/// How many of `args` are global flags standing before the first word that is
/// not one: three in `-q -d app install`, one in `-q phpunit -v`.
///
/// A `-d` with nothing after it ends the run rather than being swallowed, so
/// `takeGlobals` is the one that reports it.
fn leadingGlobals(args: []const []const u8) usize {
    var scratch: Global = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const start = i;
        const taken = applyGlobal(&scratch, args, &i) catch return start;
        if (!taken) return start;
    }
    return args.len;
}

/// What a command runs with once the global flags are applied.
const Scoped = struct {
    args: []const []const u8,
    env: *EnvMap,
};

/// The global flags, for a command that does not read them itself: stripped
/// out of `args`, and applied — `-q` / `--ansi` to the output, `--no-cache` to
/// the fetcher, and `-d DIR` by making DIR the current directory, as
/// Composer's `chdir` does, so a relative path given to the command resolves
/// inside it.
///
/// `only_leading` takes only the flags before the first other word — for
/// `exec`, whose remaining arguments belong to the program it runs.
///
/// Null when `-d` names no directory; that is reported here.
fn withGlobals(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    args: []const []const u8,
    only_leading: bool,
) !?Scoped {
    var g: Global = .{};
    const n = if (only_leading) leadingGlobals(args) else args.len;
    const taken = try takeGlobals(allocator, args[0..n], &g);
    const stripped = if (n == args.len) taken else try std.mem.concat(allocator, []const u8, &.{ taken, args[n..] });

    if (g.no_cache) ppkg.fetch.bypass_cache = true;

    const dir = g.working_dir orelse return .{ .args = stripped, .env = env };
    const abs = try util.absPath(allocator, env, dir);
    if (!util.dirExists(Dir.cwd(), io, abs)) {
        report.err(try std.fmt.allocPrint(allocator, "--working-dir {s}: no such directory.", .{dir}));
        return null;
    }

    // Both halves of "the current directory": the process's, for the code that
    // opens a relative path directly, and `PWD`, which `util.absPath` resolves
    // against so that a path reached through a symlink keeps the spelling the
    // user typed.
    try std.process.setCurrentPath(io, abs);
    const scoped = try allocator.create(EnvMap);
    scoped.* = .init(allocator);
    var it = env.iterator();
    while (it.next()) |e| try scoped.put(e.key_ptr.*, e.value_ptr.*);
    try scoped.put("PWD", abs);
    return .{ .args = stripped, .env = scoped };
}

/// The project directory a command should act on.
///
/// `-d` outranks a positional path, which is Composer's rule: `-d` is what a
/// wrapper script passes, and a positional is what a person typed.
fn targetDir(g: Global, positional: []const u8) []const u8 {
    return g.working_dir orelse positional;
}

/// `--ignore-platform-req=NAME`, repeated, plus the blanket `--ignore-platform-reqs`.
///
/// Returns true when `a` was one of them.
fn takeIgnorePlatform(
    allocator: std.mem.Allocator,
    a: []const u8,
    names: *std.ArrayList([]const u8),
    all: *bool,
) !bool {
    if (eq(a, "--ignore-platform-reqs")) {
        all.* = true;
        return true;
    }
    if (std.mem.startsWith(u8, a, "--ignore-platform-req=")) {
        try names.append(allocator, a["--ignore-platform-req=".len..]);
        return true;
    }
    return false;
}

fn dispatch(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    // `args` begins at the command word — or at global flags standing before
    // it. Composer takes `composer -d app install` as readily as `composer
    // install -d app`, and wrapper scripts write the first form, so those flags
    // are moved behind the word, where every command looks for them.
    const lead = leadingGlobals(args);
    if (lead == args.len) {
        usage();
        return 0;
    }
    const sub = args[lead];
    const rest = if (lead == 0) args[1..] else try std.mem.concat(allocator, []const u8, &.{ args[0..lead], args[lead + 1 ..] });

    // Composer's spelling. Undecorated on stdout, because what reads it is
    // usually a script comparing versions, not a person.
    if (eq(sub, "--version") or eq(sub, "-V")) {
        report.raw(try std.fmt.allocPrint(allocator, "{s} {s}", .{
            host.program,
            if (host.version.len > 0) host.version else "unknown",
        }));
        return 0;
    }

    // These parse the global flags themselves, alongside their own options —
    // there `-d` outranks a positional path, Composer's rule for a command
    // that takes both. Handing them flags already applied would apply `-d`
    // twice, the second time relative to the first.
    if (readsOwnGlobals(sub)) return (try route(allocator, io, env, sub, rest)).?;

    // Every other command gets them applied here, so `-q`, `-d` and
    // `--no-cache` mean the same thing whichever command they are given to.
    // `exec` keeps only those before the binary's name: what follows belongs
    // to the program it runs (`ppkg exec phpunit -v`).
    const scoped = (try withGlobals(allocator, io, env, rest, eq(sub, "exec"))) orelse return 1;

    if (try route(allocator, io, scoped.env, sub, scoped.args)) |code| return code;

    // A host's own commands, for a word the package does not know.
    if (host.extension) |ext| {
        if (try ext.dispatch(allocator, io, scoped.env, sub, scoped.args)) |code| return code;
    }

    report.err(try std.fmt.allocPrint(allocator, "Unknown subcommand '{s}'.", .{sub}));
    usage();
    return 2;
}

/// The commands that read the global flags themselves (`takeGlobals` in their
/// own argument loop). Every other command has them applied by `dispatch`.
fn readsOwnGlobals(sub: []const u8) bool {
    const words = [_][]const u8{
        "autoload",   "dump-autoload", "dump",   "install", "update", "upgrade", "u",
        "repository", "repo",          "policy", "require", "req",    "r",       "remove",
        "rm",         "archive",
    };
    for (words) |w| {
        if (eq(sub, w)) return true;
    }
    return false;
}

/// The package's own commands. Null for a word that is not one of them.
fn route(allocator: std.mem.Allocator, io: Io, env: *EnvMap, sub: []const u8, rest: []const []const u8) !?u8 {
    if (eq(sub, "autoload") or eq(sub, "dump-autoload") or eq(sub, "dump")) {
        return try autoloadCmd(allocator, io, env, rest);
    }
    if (eq(sub, "install")) {
        return try installCmd(allocator, io, env, rest);
    }
    if (eq(sub, "resolve")) {
        return try resolveCmd(allocator, io, env, rest);
    }
    if (eq(sub, "update") or eq(sub, "upgrade") or eq(sub, "u")) {
        return try updateCmd(allocator, io, env, rest);
    }
    if (eq(sub, "config")) {
        return try configCmd(allocator, io, env, rest);
    }
    if (eq(sub, "init")) {
        return try initCmd(allocator, io, env, rest);
    }
    if (eq(sub, "audit")) {
        return try auditCmd(allocator, io, env, rest);
    }
    if (eq(sub, "search") or eq(sub, "find")) {
        return try searchCmd(allocator, io, env, rest);
    }
    if (eq(sub, "status")) {
        return try simpleCmd(allocator, io, env, rest, .status);
    }
    if (eq(sub, "suggests") or eq(sub, "suggest")) {
        return try simpleCmd(allocator, io, env, rest, .suggests);
    }
    if (eq(sub, "fund") or eq(sub, "funding")) {
        return try simpleCmd(allocator, io, env, rest, .fund);
    }
    if (eq(sub, "clear-cache") or eq(sub, "clearcache") or eq(sub, "cc")) {
        return try simpleCmd(allocator, io, env, rest, .clear_cache);
    }
    if (eq(sub, "bump")) {
        return try bumpCmd(allocator, io, env, rest);
    }
    if (eq(sub, "reinstall")) {
        return try reinstallCmd(allocator, io, env, rest);
    }
    if (eq(sub, "exec")) {
        return try execCmd(allocator, io, env, rest);
    }
    if (eq(sub, "home") or eq(sub, "browse")) {
        return try targetCmd(allocator, io, env, rest, .home);
    }
    if (eq(sub, "archive")) {
        return try archiveCmd(allocator, io, env, rest);
    }
    if (eq(sub, "diagnose") or eq(sub, "doctor")) {
        return try diagnoseCmd(allocator, io, env, rest);
    }
    if (eq(sub, "create-project") or eq(sub, "create")) {
        return try createProjectCmd(allocator, io, env, rest);
    }
    if (eq(sub, "self-update") or eq(sub, "selfupdate")) {
        return try selfUpdateCmd(allocator, io, rest);
    }
    if (eq(sub, "prohibits") or eq(sub, "why-not")) {
        return try targetCmd(allocator, io, env, rest, .prohibits);
    }
    if (eq(sub, "about")) {
        about();
        return 0;
    }
    if (eq(sub, "run-script") or eq(sub, "run") or eq(sub, "script")) {
        return try runScriptCmd(allocator, io, env, rest);
    }
    if (eq(sub, "require") or eq(sub, "req") or eq(sub, "r")) {
        return try editCmd(allocator, io, env, rest, .require);
    }
    if (eq(sub, "remove") or eq(sub, "rm")) {
        return try editCmd(allocator, io, env, rest, .remove);
    }
    if (eq(sub, "outdated")) {
        return try outdatedCmd(allocator, io, env, rest);
    }
    if (eq(sub, "check-platform-reqs") or eq(sub, "platform")) {
        return try platformCmd(allocator, io, env, rest);
    }
    if (eq(sub, "content-hash")) {
        return try contentHashCmd(allocator, io, env, rest);
    }
    if (eq(sub, "lock")) {
        return try lockCmd(allocator, io, env, rest);
    }
    if (eq(sub, "compat")) {
        return try compatCmd(allocator, io, env, rest);
    }
    if (eq(sub, "repository") or eq(sub, "repo")) {
        return try repositoryCmd(allocator, io, env, rest);
    }
    if (eq(sub, "policy")) {
        return try policyCmd(allocator, io, env, rest);
    }
    if (eq(sub, "completion")) {
        return try completionCmd(allocator, rest);
    }
    if (eq(sub, "list")) {
        // Composer's `list` is the COMMAND index, not the package list. It
        // used to alias `show` here, which meant the one command a newcomer
        // types to find out what exists answered a different question.
        usage();
        return 0;
    }
    if (eq(sub, "show")) {
        return try inspectCmd(allocator, io, env, rest, .show);
    }
    if (eq(sub, "why") or eq(sub, "depends")) {
        return try inspectCmd(allocator, io, env, rest, .why);
    }
    if (eq(sub, "licenses") or eq(sub, "license")) {
        return try inspectCmd(allocator, io, env, rest, .licenses);
    }
    if (eq(sub, "validate")) {
        return try inspectCmd(allocator, io, env, rest, .validate);
    }
    if (eq(sub, "help") or eq(sub, "--help") or eq(sub, "-h")) {
        usage();
        return 0;
    }

    return null;
}

fn autoloadCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args_in: []const []const u8) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    var target: []const u8 = ".";
    var dev = true;
    var optimize = false;
    var check = false;
    var authoritative = false;
    var apcu = false;
    var apcu_prefix: ?[]const u8 = null;
    var strict_psr = false;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--no-dev")) {
            dev = false;
        } else if (eq(a, "--dev")) {
            dev = true;
        } else if (eq(a, "-o") or eq(a, "--optimize") or eq(a, "--optimize-autoloader")) {
            optimize = true;
        } else if (eq(a, "-a") or eq(a, "--classmap-authoritative")) {
            // Implies -o: an authoritative classmap that was not built from a
            // scan resolves nothing at all.
            authoritative = true;
            optimize = true;
        } else if (eq(a, "--apcu") or eq(a, "--apcu-autoloader")) {
            apcu = true;
        } else if (std.mem.startsWith(u8, a, "--apcu-prefix=")) {
            apcu = true;
            apcu_prefix = a["--apcu-prefix=".len..];
        } else if (std.mem.startsWith(u8, a, "--apcu-autoloader-prefix=")) {
            apcu = true;
            apcu_prefix = a["--apcu-autoloader-prefix=".len..];
        } else if (eq(a, "--strict-psr")) {
            strict_psr = true;
        } else if (eq(a, "--check") or eq(a, "--dry-run")) {
            // Generate and COMPARE rather than write. This is how the generator
            // is held to its claim of Composer parity: run Composer, run this,
            // and a clean --check is the evidence.
            check = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }

    const root_dir = try util.absPath(allocator, env, targetDir(g, target));

    const root = (try manifest.read(allocator, io, root_dir)) orelse {
        report.err(try std.fmt.allocPrint(allocator, "No composer.json in {s}.", .{root_dir}));
        return 1;
    };

    // `config.vendor-dir` moves the tree, and the generated autoloader is
    // written in terms of where it landed.
    const lay = try ppkg.layout.resolve(allocator, env, root_dir, root);
    const vendor_dir = lay.vendor;

    const installed = manifest.readInstalled(allocator, io, vendor_dir) catch |e| {
        report.err(switch (e) {
            error.NoInstalledJson => try std.fmt.allocPrint(
                allocator,
                "{s}/composer/installed.json is missing — run `ppkg install` (or `composer install`) once to lay down the tree, then this command maintains it.",
                .{lay.label(allocator, vendor_dir)},
            ),
            else => "vendor/composer/installed.json could not be parsed.",
        });
        return 1;
    };

    report.intro("ppkg autoload");

    const cfg = ppkg.settings.load(allocator, io, env, root_dir);

    const started = std.Io.Timestamp.now(io, .awake);
    const plan = try autoload.plan(allocator, io, lay, root, installed, .{
        .dev = dev,
        .optimize = optimize or cfg.optimizeAutoloader(),
        .suffix = cfg.autoloaderSuffix(),
    });
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    report.item("packages", try std.fmt.allocPrint(allocator, "{d}", .{installed.len}));
    report.item("psr-4 rules", try std.fmt.allocPrint(allocator, "{d}", .{plan.psr4.len}));
    if (plan.psr0.len > 0) report.item("psr-0 rules", try std.fmt.allocPrint(allocator, "{d}", .{plan.psr0.len}));
    report.item("classmap", try std.fmt.allocPrint(allocator, "{d} classes", .{plan.classes.len}));
    report.item("files", try std.fmt.allocPrint(allocator, "{d}", .{plan.files.len}));

    if (check) {
        const differing = try compare(allocator, io, vendor_dir, plan);
        report.blank();
        if (differing == 0) {
            report.ok("Generated output matches what is on disk.");
            report.outro(try std.fmt.allocPrint(allocator, "checked in {d}ms", .{elapsed_ms}));
            return 0;
        }
        report.warn(try std.fmt.allocPrint(allocator, "{d} file(s) differ from what is on disk.", .{differing}));
        return 1;
    }

    if (strict_psr) {
        const violations = try autoload.strictPsrViolations(allocator, io, plan, lay.root, vendor_dir);
        if (violations.len > 0) {
            report.blank();
            // Composer's wording, because it is the message people search
            // for when they hit this.
            for (violations) |v| {
                report.err(try std.fmt.allocPrint(
                    allocator,
                    "Class {s} located in {s} does not comply with psr-4 autoloading standard (rule: {s} => {s}).",
                    .{ v.fqcn, lay.label(allocator, v.path), v.prefix, lay.label(allocator, v.dir) },
                ));
            }
            report.warn(try std.fmt.allocPrint(
                allocator,
                "{d} class(es) cannot be loaded by the psr-4 rule that claims them.",
                .{violations.len},
            ));
            return 1;
        }
    }

    try autoload.write(allocator, io, vendor_dir, plan);

    // The loader itself, regenerated with this dump's shape. `dump-autoload`
    // writes it in Composer too — the two files name the same suffix, so one
    // regenerated without the other leaves autoload.php calling a class that
    // no longer exists.
    const status = ppkg.runtime.generate(allocator, io, vendor_dir, .{
        .suffix = plan.hash,
        .check_platform = ppkg.util.fileExists(io, try std.fs.path.join(allocator, &.{ vendor_dir, "composer", "platform_check.php" })),
        .has_files = plan.files.len > 0,
        .has_include_paths = plan.include_paths.len > 0,
        .classmap_authoritative = authoritative or cfg.classmapAuthoritative(),
        .apcu_prefix = if (apcu or cfg.apcuAutoloader())
            (apcu_prefix orelse cfg.apcuPrefix() orelse plan.hash)
        else
            null,
        .use_include_path = cfg.useIncludePath(),
        .prepend = cfg.prependAutoloader(),
    });
    if (status == .failed) {
        report.err("The loader could not be written. Check the vendor directory is writable.");
        return 1;
    }

    report.blank();
    report.ok("Autoloader regenerated.");
    report.outro(try std.fmt.allocPrint(allocator, "{d}ms  ·  no network", .{elapsed_ms}));
    return 0;
}

/// Compare generated output against the files currently on disk.
///
/// Reports per file rather than as one verdict, because the interesting failure
/// is "the classmap matches but files/ does not" — which localises the bug to
/// one emitter instead of to "the generator".
fn outdatedCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var opts: inspect.OutdatedOptions = .{};

    for (args) |a| {
        if (eq(a, "--constrained") or eq(a, "-c")) {
            opts.constrained_only = true;
        } else if (eq(a, "--with-dev-branches")) {
            opts.with_dev = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }

    const root_dir = try util.absPath(allocator, env, target);
    return inspect.outdated(allocator, io, env, root_dir, opts) catch |e| {
        report.err(switch (e) {
            error.NoInstalledJson => "No vendor/composer/installed.json — nothing is installed here yet.",
            else => "The comparison could not be produced.",
        });
        return 1;
    };
}

fn resolveCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var opts: resolver.Options = .{};

    for (args) |a| {
        if (eq(a, "--no-dev")) {
            opts.dev = false;
        } else if (eq(a, "--check")) {
            opts.check = true;
        } else if (eq(a, "--with-dev-branches")) {
            opts.with_dev_branches = true;
        } else if (eq(a, "--refresh")) {
            opts.refresh = true;
        } else if (eq(a, "--ignore-unsupported")) {
            opts.ignore_unsupported = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }

    return resolver.command(allocator, io, env, try util.absPath(allocator, env, target), opts);
}

const Report = enum { show, why, licenses, validate };

/// The read-only reports. They share argument handling because they share the
/// same shape: an optional project path, and for `why` a required package name.
fn inspectCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    args: []const []const u8,
    which: Report,
) !u8 {
    var target: []const u8 = ".";
    var subject: []const u8 = "";

    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        }
        // An argument that names an existing directory is the PROJECT; anything
        // else is the package name or filter. Deciding on the `vendor/package`
        // shape instead looks reasonable and is wrong in both directions — a
        // filter like `symfony` has no slash, and a project path has plenty.
        if (util.dirExists(std.Io.Dir.cwd(), io, a)) {
            target = a;
        } else {
            subject = a;
        }
    }

    const root_dir = try util.absPath(allocator, env, target);

    if (which == .why and subject.len == 0) {
        report.err("Usage: `ppkg why <vendor/package>`");
        return 2;
    }

    return switch (which) {
        .show => inspect.show(allocator, io, root_dir, subject),
        .why => inspect.why(allocator, io, root_dir, subject),
        .licenses => inspect.licenses(allocator, io, root_dir),
        .validate => inspect.validate(allocator, io, root_dir),
    } catch |e| {
        report.err(switch (e) {
            error.NoInstalledJson => "No vendor/composer/installed.json — nothing is installed here yet.",
            error.MalformedInstalled => "vendor/composer/installed.json could not be parsed.",
            else => "The report could not be produced.",
        });
        return 1;
    };
}

fn installCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args_in: []const []const u8) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    var target: []const u8 = ".";
    var opts: installer.Options = .{};
    var no_scripts = false;
    var ignore_names: std.ArrayList([]const u8) = .empty;
    var ignore_all = false;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--no-dev")) {
            opts.dev = false;
        } else if (eq(a, "--dev")) {
            // Composer's default; accepted so a script that states it works.
            opts.dev = true;
        } else if (eq(a, "-o") or eq(a, "--optimize") or eq(a, "--optimize-autoloader")) {
            opts.optimize = true;
        } else if (eq(a, "-a") or eq(a, "--classmap-authoritative")) {
            opts.classmap_authoritative = true;
        } else if (eq(a, "--apcu-autoloader")) {
            opts.apcu = true;
        } else if (std.mem.startsWith(u8, a, "--apcu-autoloader-prefix=")) {
            opts.apcu = true;
            opts.apcu_prefix = a["--apcu-autoloader-prefix=".len..];
        } else if (eq(a, "--apcu-autoloader-prefix") and i + 1 < args.len) {
            i += 1;
            opts.apcu = true;
            opts.apcu_prefix = args[i];
        } else if (eq(a, "--prefer-source")) {
            opts.prefer = .source;
        } else if (eq(a, "--prefer-dist")) {
            opts.prefer = .dist;
        } else if (std.mem.startsWith(u8, a, "--prefer-install=")) {
            const v = a["--prefer-install=".len..];
            opts.prefer = if (eq(v, "source")) .source else if (eq(v, "dist")) .dist else if (eq(v, "auto")) .auto else {
                report.err("--prefer-install takes source, dist or auto.");
                return 2;
            };
        } else if (eq(a, "--no-autoloader")) {
            opts.skip_autoloader = true;
        } else if (eq(a, "--download-only")) {
            opts.download_only = true;
        } else if (eq(a, "--no-progress")) {
            // The per-package lines are the progress. Silencing them leaves
            // the summary, which is what a log wants.
            report.setQuiet(false);
            opts.quiet_progress = true;
        } else if (eq(a, "--no-suggest")) {
            // Removed from Composer in 2.0 and still passed by old scripts.
            // Accepted and inert rather than an error on a flag that means
            // "print less" and never meant anything else.
        } else if (try takeIgnorePlatform(allocator, a, &ignore_names, &ignore_all)) {
            // recorded below
        } else if (eq(a, "--dry-run")) {
            opts.dry_run = true;
        } else if (eq(a, "--require-checksums")) {
            // Off by default: every GitHub zipball would be refused, and that
            // is most of what this installs. On, it is the switch for a build
            // that may not ship a byte nobody vouched for.
            ppkg.fetch.require_checksums = true;
        } else if (eq(a, "--force") or eq(a, "-f")) {
            opts.force = true;
        } else if (eq(a, "--ignore-unsupported")) {
            opts.ignore_unsupported = true;
        } else if (eq(a, "--no-scripts")) {
            no_scripts = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }
    opts.scripts = scriptOptions(env, no_scripts);
    opts.ignore_platform = .{ .all = ignore_all, .names = ignore_names.items };
    if (g.no_cache) ppkg.fetch.bypass_cache = true;

    const root_dir = try util.absPath(allocator, env, targetDir(g, target));

    report.intro("ppkg install");
    if (opts.dry_run) report.note("Dry run — nothing will be written.");
    if (opts.ignore_platform.any()) {
        report.warn("Platform requirements are being ignored; this tree may not run on this machine.");
    }

    const started = std.Io.Timestamp.now(io, .awake);
    const summary = installer.run(allocator, io, env, root_dir, opts) catch |e| {
        report.err(switch (e) {
            lockfile.Error.NoLockFile => "No composer.lock here. This command installs a LOCKED set of packages; creating a lock means resolving versions, which is `composer update` for now.",
            lockfile.Error.MalformedLock => "composer.lock could not be parsed.",
            else => "The install could not be completed.",
        });
        return 1;
    };
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    report.item("installed", try std.fmt.allocPrint(allocator, "{d}", .{summary.installed}));
    if (summary.linked > 0) report.item("linked", try std.fmt.allocPrint(allocator, "{d}  (path repositories)", .{summary.linked}));
    if (summary.reused > 0) report.item("already current", try std.fmt.allocPrint(allocator, "{d}", .{summary.reused}));
    if (summary.cached > 0) report.item("from cache", try std.fmt.allocPrint(allocator, "{d}", .{summary.cached}));
    if (summary.downloaded_bytes > 0) {
        report.item("downloaded", try std.fmt.allocPrint(allocator, "{d} KB", .{summary.downloaded_bytes / 1024}));
    }

    if (summary.binaries > 0) report.item(summary.bin_label, try std.fmt.allocPrint(allocator, "{d} launcher(s)", .{summary.binaries}));
    // Said out loud rather than left to be discovered. A GitHub zipball has no
    // published digest, so this is the normal state for a `vcs` tree and not an
    // alarm — but "N of these arrived with nothing to check them against" is a
    // fact an operator is entitled to have before they deploy it.
    if (summary.unverified > 0) {
        report.warn(try std.fmt.allocPrint(
            allocator,
            "{d} archive(s) had no checksum in the lock and were installed unverified. Pass --require-checksums to refuse instead.",
            .{summary.unverified},
        ));
    }

    switch (summary.runtime) {
        .generated => {},
        .failed => {
            report.blank();
            report.err(try std.fmt.allocPrint(
                allocator,
                "{s}/ has no autoload.php — the loader could not be written. Check the directory is writable.",
                .{summary.vendor_label},
            ));
            return 1;
        },
    }

    report.blank();
    if (summary.failed > 0) {
        report.warn(try std.fmt.allocPrint(allocator, "{d} package(s) could not be installed.", .{summary.failed}));
        return 1;
    }
    report.ok(try std.fmt.allocPrint(allocator, "{s}/ is up to date.", .{summary.vendor_label}));
    report.outro(try std.fmt.allocPrint(allocator, "{d}ms", .{elapsed_ms}));
    return 0;
}

fn compare(allocator: std.mem.Allocator, io: Io, vendor_dir: []const u8, plan: autoload.Plan) !usize {
    const dir = try std.fs.path.join(allocator, &.{ vendor_dir, "composer" });
    var differing: usize = 0;

    const cases = [_]struct { name: []const u8, body: []const u8 }{
        .{ .name = "autoload_psr4.php", .body = try autoload.renderFor(allocator, plan, .psr4) },
        .{ .name = "autoload_namespaces.php", .body = try autoload.renderFor(allocator, plan, .psr0) },
        .{ .name = "autoload_classmap.php", .body = try autoload.renderFor(allocator, plan, .classmap) },
        .{ .name = "autoload_files.php", .body = try autoload.renderFor(allocator, plan, .files) },
        .{ .name = "autoload_static.php", .body = try autoload.renderFor(allocator, plan, .static) },
    };

    for (cases) |c| {
        const path = try std.fs.path.join(allocator, &.{ dir, c.name });
        const current = Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch {
            report.warn(try std.fmt.allocPrint(allocator, "{s}: absent on disk", .{c.name}));
            differing += 1;
            continue;
        };
        if (std.mem.eql(u8, current, c.body)) {
            report.muted(try std.fmt.allocPrint(allocator, "    = {s}", .{c.name}));
            continue;
        }
        differing += 1;
        report.warn(try std.fmt.allocPrint(
            allocator,
            "{s}: differs ({d} bytes on disk, {d} generated){s}",
            .{ c.name, current.len, c.body.len, firstDifference(allocator, current, c.body) catch "" },
        ));
    }
    return differing;
}

/// A short excerpt at the first differing byte — enough to see WHICH rule went
/// wrong without dumping two 400 KB files at the reader.
fn firstDifference(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;

    const line_start = if (std.mem.lastIndexOfScalar(u8, a[0..i], '\n')) |p| p + 1 else 0;
    const a_line = a[line_start..@min(a.len, line_start + 120)];
    const b_line = b[line_start..@min(b.len, line_start + 120)];

    return std.fmt.allocPrint(allocator,
        \\
        \\      disk: {s}
        \\      ours: {s}
    , .{
        std.mem.sliceTo(a_line, '\n'),
        std.mem.sliceTo(b_line, '\n'),
    });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usage() void {
    report.intro("ppkg");
    report.section("Commands");
    report.item("ppkg install [path]", "build vendor/ from composer.lock — no resolution");
    report.item("ppkg autoload [path]", "regenerate vendor/composer/autoload_*.php — no network");
    report.item("ppkg resolve [path]", "resolve composer.json against packagist (--check diffs the lock)");
    report.item("ppkg outdated [path]", "compare installed versions against packagist");
    report.item("ppkg show [name]", "list installed packages");
    report.item("ppkg why <pkg>", "which installed packages require it");
    report.item("ppkg licenses", "licence summary of what is installed");
    report.item("ppkg validate", "check composer.json for mistakes that break installs later");
    report.item("ppkg check-platform-reqs", "does this machine satisfy every php/ext-* requirement");
    report.item("ppkg require <pkg>[:<c>]", "add a dependency, re-lock and install");
    report.item("ppkg remove <pkg>", "drop a dependency, re-lock and install");
    report.item("ppkg run-script <name>", "run one entry from the project's scripts block");
    report.item("ppkg update [path]", "resolve composer.json and WRITE composer.lock");
    report.item("ppkg lock --check", "is composer.lock in canonical form");
    report.item("ppkg update <pkg>…", "move only the named packages (-w / -W for their deps)");
    report.item("ppkg compat [path]", "can this tool handle this project, or is composer required");
    report.item("ppkg list", "this screen");
    if (host.extension) |ext| for (ext.usage) |row| report.item(row[0], row[1]);
    report.section("Manifest");
    report.item("ppkg init --name v/p", "write a new composer.json");
    report.item("ppkg config <key> [val]", "read or write one composer.json key (--list, --unset)");
    report.item("ppkg repository <action>", "list/add/remove/set-url/get-url/enable/disable");
    report.item("ppkg policy add-source", "record a dependency-policy source (NOT enforced)");
    report.item("ppkg bump", "raise each constraint to the version the lock pins");
    report.section("Reports");
    report.item("ppkg audit", "security advisories against the locked versions");
    report.item("ppkg search <terms>", "look a package up on packagist");
    report.item("ppkg status", "which installed packages differ from the lock");
    report.item("ppkg suggests", "optional companions that are not installed");
    report.item("ppkg fund", "how to support the installed packages");
    report.item("ppkg home <pkg>", "print a package's homepage url");
    report.item("ppkg prohibits <pkg> <v>", "what stands in the way of that version");
    report.section("Tree");
    report.item("ppkg exec [bin] [args]", "run a binary from the project's bin dir");
    report.item("ppkg reinstall <pkg>", "delete a package so the next install replaces it");
    report.item("ppkg clear-cache", "empty the download and metadata cache");
    report.item("ppkg archive [-f zip]", "write this project out as a tar or zip");
    report.section("Machine");
    report.item("ppkg diagnose", "can this machine and this project do the work");
    report.item("ppkg create-project v/p [dir]", "start a new project from a package");
    report.item("ppkg global <cmd> …", "run a command against $COMPOSER_HOME");
    report.item("ppkg self-update", "is a newer release out, and how to get it");
    report.item("ppkg completion <shell>", "a completion script for bash, zsh or fish");
    report.section("Options — every command");
    report.item("-q, --quiet", "no output on stdout; errors still go to stderr");
    report.item("-n, --no-interaction", "never prompt; take the default");
    report.item("-d, --working-dir DIR", "act on this project rather than the current directory");
    report.item("--no-cache", "neither read nor write the download cache");
    report.item("--ansi, --no-ansi", "force colour on or off");
    report.item("--no-plugins", "accepted and inert — no composer plugin is ever loaded");
    report.section("Options");
    report.item("--no-dev", "autoload: skip autoload-dev rules");
    report.item("-o, --optimize", "autoload: scan psr-4 roots into the classmap");
    report.item("--check", "autoload: compare against what is on disk instead of writing");
    report.item("-a, --classmap-authoritative", "autoload/install: never fall back to the filesystem");
    report.item("--apcu-autoloader", "autoload/install: memoise class lookups in APCu");
    report.item("--strict-psr", "autoload: fail when a class is not where psr-4 says");
    report.item("--dry-run", "install: report what would happen, write nothing");
    report.item("--force, -f", "install: reinstall packages already at the locked reference");
    report.item("--prefer-source / --prefer-dist", "install: a working copy, or a published archive");
    report.item("--ignore-platform-reqs", "install/update: do not enforce php/ext-* (also `=name`, `=php+`)");
    report.item("--no-autoloader", "install: place packages, generate nothing");
    report.item("--download-only", "install: fill the cache and stop");
    report.item("--no-progress", "install: drop the per-package lines, keep the summary");
    report.item("-w / -W", "update/require: also move dependencies / all dependencies");
    report.item("--prefer-lowest, --prefer-stable", "update: take the floor, or prefer stable releases");
    report.item("--lock", "update: rewrite the lock without moving any version");
    report.item("--root-reqs", "update: restrict the update to direct requirements");
    report.item("--dev", "require: write to require-dev instead of require");
    report.item("--fixed", "require: write the exact version, not a caret range");
    report.item("--no-update", "require/remove: edit composer.json only");
    report.item("--no-install", "require/remove: re-lock but do not touch vendor/");
    report.item("--no-scripts", "install/update/require: do not run the project's scripts");
    report.item("--require-checksums", "install: refuse a dist the lock records no checksum for");
    report.item("-f, --format", "archive: tar (default), tar.gz or zip");
    report.item("--dir, --file", "archive: where to write it, and under what name");
    report.item("--ignore-filters", "archive: ignore .gitignore and archive.exclude");
    report.item("--offline", "diagnose: skip the packagist reachability check");
    report.blank();
}

/// `ppkg check-platform-reqs [path] [--php <bin>]`
fn platformCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    // Which interpreter is asked matters: a machine can have several, and the
    // one that answers must be the one the project will actually run on.
    var php_bin: []const u8 = env.get("HKM_PHP") orelse "php";

    var i: usize = 0;
    var ignore_names: std.ArrayList([]const u8) = .empty;
    var ignore_all = false;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--php") and i + 1 < args.len) {
            i += 1;
            php_bin = args[i];
        } else if (std.mem.startsWith(u8, a, "--php=")) {
            php_bin = a["--php=".len..];
        } else if (try takeIgnorePlatform(allocator, a, &ignore_names, &ignore_all)) {
            // recorded above
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }
    const ignore: ppkg.platform.Ignore = .{ .all = ignore_all, .names = ignore_names.items };

    const root_dir = try util.absPath(allocator, env, target);
    return inspect.checkPlatformReqs(allocator, io, env, root_dir, php_bin, ignore);
}

/// `ppkg content-hash [path]` — what composer.lock's `content-hash` should
/// be for this composer.json, and whether the lock agrees.
///
/// A diagnostic rather than a convenience. "The lock file is not up to date
/// with the latest changes in composer.json" is a message with no detail
/// attached, and this is how you find out whether the lock is stale or the
/// hash is being computed wrongly.
fn contentHashCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        }
        target = a;
    }

    const root_dir = try util.absPath(allocator, env, target);
    const json_path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });

    const source = Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(8 * 1024 * 1024)) catch {
        report.err("No composer.json here.");
        return 1;
    };

    report.intro("ppkg content-hash");

    const computed = ppkg.contenthash.of(allocator, source) catch {
        report.err("composer.json could not be parsed.");
        return 1;
    };
    report.item("computed", computed);

    const lock_path = try std.fs.path.join(allocator, &.{ root_dir, "composer.lock" });
    const lock_src = Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(64 * 1024 * 1024)) catch {
        report.outro("no composer.lock to compare against");
        return 0;
    };

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, lock_src, .{}) catch {
        report.err("composer.lock could not be parsed.");
        return 1;
    };
    const recorded = blk: {
        if (parsed != .object) break :blk "";
        const v = parsed.object.get("content-hash") orelse break :blk "";
        break :blk if (v == .string) v.string else "";
    };

    if (recorded.len == 0) {
        report.warn("composer.lock records no content-hash.");
        return 0;
    }

    report.item("in composer.lock", recorded);
    report.blank();

    if (std.mem.eql(u8, recorded, computed)) {
        report.ok("The lock is current with composer.json.");
        report.outro("match");
        return 0;
    }

    report.warn("composer.json has changed since the lock was written.");
    report.outro("differs");
    return 1;
}

/// `ppkg lock --check [path]` — is composer.lock in canonical form?
///
/// Re-renders the lock from its own contents and compares bytes. A difference
/// means either this renderer disagrees with Composer, or the file has been
/// hand-edited — and knowing which is the point. It is also how the renderer
/// itself is verified: the input is a file Composer wrote and this code did not.
fn lockCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var check = false;
    var show_diff = false;

    for (args) |a| {
        if (eq(a, "--check")) {
            check = true;
        } else if (eq(a, "--diff")) {
            check = true;
            show_diff = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }

    if (!check) {
        report.err("Only `ppkg lock --check` is implemented — writing a lock needs a resolve.");
        return 2;
    }

    const root_dir = try util.absPath(allocator, env, target);
    const path = try std.fs.path.join(allocator, &.{ root_dir, "composer.lock" });

    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch {
        report.err("No composer.lock here.");
        return 1;
    };

    report.intro("ppkg lock --check");

    const rendered = ppkg.lockwrite.reRender(allocator, source) catch {
        report.err("composer.lock could not be parsed.");
        return 1;
    };

    report.item("on disk", try std.fmt.allocPrint(allocator, "{d} bytes", .{source.len}));
    report.item("re-rendered", try std.fmt.allocPrint(allocator, "{d} bytes", .{rendered.len}));
    report.blank();

    if (std.mem.eql(u8, source, rendered)) {
        report.ok("Byte-identical — the lock is in canonical form.");
        report.outro("match");
        return 0;
    }

    // Where they diverge is the only useful part of a failure. A byte offset
    // into a 200KB file is not; the line, with both sides, is.
    var line: usize = 1;
    var i: usize = 0;
    const n = @min(source.len, rendered.len);
    while (i < n and source[i] == rendered[i]) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    report.warn(try std.fmt.allocPrint(allocator, "First difference at line {d} (byte {d}).", .{ line, i }));

    if (show_diff) {
        report.muted(try std.fmt.allocPrint(allocator, "on disk:     {s}", .{sliceAround(source, i)}));
        report.muted(try std.fmt.allocPrint(allocator, "re-rendered: {s}", .{sliceAround(rendered, i)}));
    } else {
        report.note("Run with --diff to see both sides.");
    }

    report.outro("differs");
    return 1;
}

/// The line containing byte `at`, for a diff message.
fn sliceAround(s: []const u8, at: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, s[0..at], '\n')) |n| n + 1 else 0;
    const rest = s[start..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return rest[0..@min(end, 160)];
}

/// `ppkg update [path]` — resolve composer.json and write composer.lock.
///
/// The one command here that changes a file the rest of a team depends on, so
/// `--dry-run` reports exactly what would be written and touches nothing.
fn updateCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args_in: []const []const u8) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    var target: []const u8 = ".";
    var opts: resolver.Options = .{ .write = true };
    var no_scripts = false;
    var no_install = false;
    var only: std.ArrayList([]const u8) = .empty;
    var ignore_names: std.ArrayList([]const u8) = .empty;
    var ignore_all = false;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--no-dev")) {
            opts.dev = false;
        } else if (eq(a, "--dev")) {
            opts.dev = true;
        } else if (eq(a, "--dry-run")) {
            opts.dry_run = true;
            opts.write = false;
        } else if (eq(a, "--with-dev-branches")) {
            opts.with_dev_branches = true;
        } else if (eq(a, "--refresh")) {
            opts.refresh = true;
        } else if (eq(a, "--ignore-unsupported")) {
            opts.ignore_unsupported = true;
        } else if (eq(a, "--no-scripts")) {
            no_scripts = true;
        } else if (eq(a, "-w") or eq(a, "--with-dependencies")) {
            opts.with_dependencies = true;
        } else if (eq(a, "-W") or eq(a, "--with-all-dependencies")) {
            opts.with_all_dependencies = true;
        } else if (eq(a, "--prefer-lowest")) {
            opts.prefer_lowest = true;
        } else if (eq(a, "--prefer-stable")) {
            opts.prefer_stable = true;
        } else if (eq(a, "--root-reqs")) {
            opts.root_reqs_only = true;
        } else if (eq(a, "--lock")) {
            opts.lock_only = true;
        } else if (eq(a, "--no-install")) {
            no_install = true;
        } else if (eq(a, "--install")) {
            no_install = false;
        } else if (try takeIgnorePlatform(allocator, a, &ignore_names, &ignore_all)) {
            // recorded below
        } else if (std.mem.startsWith(u8, a, "--with=")) {
            // `--with vendor/name:^2.0` — a temporary constraint for this run.
            // Recorded as a package to move; the constraint itself needs a
            // manifest edit, which is `require`, so it is refused rather than
            // silently ignored.
            report.err("--with is not implemented: it changes a constraint for one run only. Use `ppkg require` to state the constraint, or edit composer.json.");
            return 2;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else if (std.mem.indexOfScalar(u8, a, '/') != null and !eq(a, ".") and !std.mem.startsWith(u8, a, "./") and !std.mem.startsWith(u8, a, "/")) {
            // A PACKAGE, not a path. `vendor/name` is the shape Composer takes
            // here, and a directory argument was this command's own extension
            // — so the two are told apart rather than one of them silently
            // winning. A real directory is still reachable as `./vendor/name`
            // or by `-d`, both of which are excluded above.
            try only.append(allocator, a);
        } else {
            target = a;
        }
    }
    opts.scripts = scriptOptions(env, no_scripts);
    opts.only = try only.toOwnedSlice(allocator);
    opts.ignore_platform = .{ .all = ignore_all, .names = ignore_names.items };
    if (g.no_cache) ppkg.fetch.bypass_cache = true;

    if (opts.only.len > 0 and opts.lock_only) {
        report.err("--lock moves nothing, so naming packages to update contradicts it.");
        return 2;
    }
    const root_dir = try util.absPath(allocator, env, targetDir(g, target));
    const code = try resolver.command(allocator, io, env, root_dir, opts);
    if (code != 0 or opts.dry_run or !opts.write) return code;

    // Composer's `update` installs what it just resolved. Skipping that leaves
    // a lock the tree does not match — every later command then reports a
    // vendor directory that is out of date, which is a state nobody asked for.
    if (no_install) return 0;

    const install_opts: installer.Options = .{
        .dev = opts.dev,
        .scripts = opts.scripts,
        .ignore_unsupported = opts.ignore_unsupported,
        .ignore_platform = opts.ignore_platform,
    };
    const summary = installer.run(allocator, io, env, root_dir, install_opts) catch {
        report.err("The lock was written, but the install that follows it failed. Run `ppkg install`.");
        return 1;
    };
    if (summary.failed > 0) return 1;
    return summary.exit_code;
}

/// `ppkg about`.
fn about() void {
    report.intro("ppkg");
    report.note("A Composer-compatible package manager, written in Zig.");
    report.blank();
    report.item("reads", "composer.json, composer.lock, vendor/composer/installed.json");
    report.item("writes", "the same files, byte-for-byte as Composer writes them");
    report.item("verified", "differentially, against Composer itself — see the repository");
    report.item("source", "https://github.com/AlfaCode-Team/hkm-ppkg");
    report.blank();
}

/// The commands that take only a project directory.
fn simpleCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    args: []const []const u8,
    which: enum { status, suggests, fund, clear_cache },
) !u8 {
    var target: []const u8 = ".";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        }
        target = a;
    }
    const root_dir = try util.absPath(allocator, env, target);

    report.intro(switch (which) {
        .status => "ppkg status",
        .suggests => "ppkg suggests",
        .fund => "ppkg fund",
        .clear_cache => "ppkg clear-cache",
    });

    return switch (which) {
        .status => ppkg.maintain.status(allocator, io, env, root_dir),
        .suggests => inspect.suggests(allocator, io, root_dir),
        .fund => inspect.fund(allocator, io, root_dir),
        .clear_cache => ppkg.maintain.clearCache(allocator, io, env, root_dir),
    } catch |e| reportRead(allocator, e);
}

/// The reports that take a package name.
fn targetCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    args: []const []const u8,
    which: enum { home, prohibits },
) !u8 {
    var target: []const u8 = ".";
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((eq(a, "-d") or eq(a, "--working-dir")) and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            try positional.append(allocator, a);
        }
    }

    const root_dir = try util.absPath(allocator, env, target);
    switch (which) {
        .home => {
            if (positional.items.len < 1) {
                report.err("Usage: `ppkg home <package>`");
                return 2;
            }
            return inspect.home(allocator, io, root_dir, positional.items[0]) catch |e| reportRead(allocator, e);
        },
        .prohibits => {
            if (positional.items.len < 2) {
                report.err("Usage: `ppkg prohibits <package> <version>`");
                return 2;
            }
            report.intro("ppkg prohibits");
            return inspect.prohibits(
                allocator,
                io,
                root_dir,
                positional.items[0],
                positional.items[1],
            ) catch |e| reportRead(allocator, e);
        },
    }
}

/// Turn the two errors every installed-tree report can raise into a message.
/// `ppkg repository <action> …` — read and edit `repositories`.
fn repositoryCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args_in: []const []const u8) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    var placement: ppkg.repository.Placement = .prepend;
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--append")) {
            placement = .append;
        } else if (std.mem.startsWith(u8, a, "--before=")) {
            placement = .{ .before = a["--before=".len..] };
        } else if (eq(a, "--before") and i + 1 < args.len) {
            i += 1;
            placement = .{ .before = args[i] };
        } else if (std.mem.startsWith(u8, a, "--after=")) {
            placement = .{ .after = a["--after=".len..] };
        } else if (eq(a, "--after") and i + 1 < args.len) {
            i += 1;
            placement = .{ .after = args[i] };
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            try positional.append(allocator, a);
        }
    }

    const root_dir = try util.absPath(allocator, env, g.working_dir orelse ".");
    const action: []const u8 = if (positional.items.len > 0) positional.items[0] else "list";
    const rest = if (positional.items.len > 1) positional.items[1..] else &[_][]const u8{};

    report.intro("ppkg repository");

    if (eq(action, "list")) {
        const entries = ppkg.repository.list(allocator, io, root_dir) catch |e| return reportRepo(allocator, e);
        for (entries) |entry| {
            report.item(
                try std.fmt.allocPrint(allocator, "[{s}]", .{if (entry.name.len > 0) entry.name else "(unnamed)"}),
                if (entry.isDisableEntry())
                    "disabled"
                else
                    try std.fmt.allocPrint(allocator, "{s}  {s}", .{ entry.kind, entry.url }),
            );
        }
        report.outro(try std.fmt.allocPrint(allocator, "{d} repositor{s}", .{
            entries.len,
            if (entries.len == 1) @as([]const u8, "y") else "ies",
        }));
        return 0;
    }

    if (eq(action, "add")) {
        if (rest.len < 2) {
            report.err("Usage: repository add <name> <type> <url>, or repository add <name> '<json>'.");
            return 2;
        }
        ppkg.repository.add(
            allocator,
            io,
            root_dir,
            rest[0],
            rest[1],
            if (rest.len > 2) rest[2] else null,
            placement,
        ) catch |e| return reportRepo(allocator, e);
        report.ok(try std.fmt.allocPrint(allocator, "{s} added.", .{rest[0]}));
        report.outro("composer.json written");
        return 0;
    }

    if (eq(action, "remove")) {
        if (rest.len < 1) {
            report.err("Which repository? `repository remove <name>`.");
            return 2;
        }
        ppkg.repository.remove(allocator, io, root_dir, rest[0]) catch |e| return reportRepo(allocator, e);
        report.ok(try std.fmt.allocPrint(allocator, "{s} removed.", .{rest[0]}));
        report.outro("composer.json written");
        return 0;
    }

    if (eq(action, "get-url")) {
        if (rest.len < 1) {
            report.err("Which repository? `repository get-url <name>`.");
            return 2;
        }
        const url = ppkg.repository.urlOf(allocator, io, root_dir, rest[0]) catch |e| return reportRepo(allocator, e);
        report.raw(url);
        return 0;
    }

    if (eq(action, "set-url")) {
        if (rest.len < 2) {
            report.err("Usage: repository set-url <name> <url>.");
            return 2;
        }
        ppkg.repository.setUrl(allocator, io, root_dir, rest[0], rest[1]) catch |e| return reportRepo(allocator, e);
        report.ok(try std.fmt.allocPrint(allocator, "{s} now points at {s}.", .{ rest[0], rest[1] }));
        report.outro("composer.json written");
        return 0;
    }

    if (eq(action, "enable") or eq(action, "disable")) {
        if (rest.len < 1) {
            report.err(try std.fmt.allocPrint(allocator, "Which repository? `repository {s} <name>`.", .{action}));
            return 2;
        }
        const on = eq(action, "enable");
        ppkg.repository.setEnabled(allocator, io, root_dir, rest[0], on) catch |e| return reportRepo(allocator, e);
        report.ok(try std.fmt.allocPrint(
            allocator,
            "{s} {s}.",
            .{ rest[0], if (on) "enabled" else "disabled" },
        ));
        report.outro("composer.json written");
        return 0;
    }

    report.err(try std.fmt.allocPrint(
        allocator,
        "Unknown action '{s}'. One of: list, add, remove, set-url, get-url, enable, disable.",
        .{action},
    ));
    return 2;
}

fn reportRepo(allocator: std.mem.Allocator, e: anyerror) u8 {
    report.err(switch (e) {
        ppkg.repository.Error.NoManifest => "No composer.json here.",
        ppkg.repository.Error.MalformedManifest => "composer.json could not be parsed.",
        ppkg.repository.Error.NotFound => "No repository by that name is declared here.",
        ppkg.repository.Error.BadDefinition => "That definition is not a type plus a url, nor a JSON object.",
        else => std.fmt.allocPrint(allocator, "The repository list could not be updated ({s}).", .{@errorName(e)}) catch "failed",
    });
    return 1;
}

/// `ppkg policy add-source <name> url <url>` — record a dependency-policy
/// source in `config.policy`.
///
/// The file is written exactly as Composer writes it, and NOTHING here reads it
/// back: policy EVALUATION — fetching the document and refusing packages it
/// forbids — is not implemented. Writing the config without enforcing it would
/// leave a project believing a policy is in force when no version of any
/// package is being checked against it, so the command says so every time
/// rather than in a footnote.
fn policyCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args_in: []const []const u8) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    if (args.len == 0) {
        report.err("Usage: policy add-source <name> url <url>.");
        return 2;
    }

    const root_dir = try util.absPath(allocator, env, g.working_dir orelse ".");
    report.intro("ppkg policy");

    if (!eq(args[0], "add-source")) {
        report.err(try std.fmt.allocPrint(allocator, "Unknown action '{s}'. Only add-source exists.", .{args[0]}));
        return 2;
    }
    if (args.len < 4) {
        report.err("Usage: policy add-source <name> url <url>.");
        return 2;
    }

    const name = args[1];
    const kind = args[2];
    const url = args[3];

    const path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const source = Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch {
        report.err("No composer.json here.");
        return 1;
    };

    var doc = ppkg.jsonedit.Document.init(allocator, source) catch {
        report.err("composer.json is not a JSON object.");
        return 1;
    };

    // config.policy.<name>.sources[] — appended, because a policy may draw on
    // more than one source and adding the second must not drop the first.
    var existing: std.json.Array = .init(allocator);
    if (std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch null) |parsed| {
        if (parsed == .object) {
            if (parsed.object.get("config")) |cfg| {
                if (cfg == .object) {
                    if (cfg.object.get("policy")) |pol| {
                        if (pol == .object) {
                            if (pol.object.get(name)) |entry| {
                                if (entry == .object) {
                                    if (entry.object.get("sources")) |srcs| {
                                        if (srcs == .array) existing = srcs.array;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var one: std.json.ObjectMap = .empty;
    try one.put(allocator, "type", .{ .string = kind });
    try one.put(allocator, "url", .{ .string = url });
    try existing.append(.{ .object = one });

    var entry: std.json.ObjectMap = .empty;
    try entry.put(allocator, "sources", .{ .array = existing });

    var policies: std.json.ObjectMap = .empty;
    try policies.put(allocator, name, .{ .object = entry });

    if (!try doc.addSubNode("config", "policy", .{ .object = policies })) {
        report.err("config is present but is not an object.");
        return 1;
    }
    try ppkg.util.writeFileAtomic(io, path, try doc.output());

    report.ok(try std.fmt.allocPrint(allocator, "{s}: {s} source recorded.", .{ name, kind }));
    report.warn("Policies are RECORDED here, not ENFORCED: nothing fetches the document or refuses a package it forbids. Use composer for the check itself.");
    report.outro("composer.json written");
    return 0;
}

/// `ppkg completion <shell>` — a completion script on stdout.
fn completionCmd(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const shell: []const u8 = if (args.len > 0) args[0] else "";

    const words = if (host.extension) |ext|
        (if (ext.words.len > 0) try std.mem.concat(allocator, u8, &.{ command_words, " ", ext.words }) else command_words)
    else
        command_words;

    if (try completionScript(allocator, shell, words)) |script| {
        report.raw(script);
        return 0;
    }

    report.err(try std.fmt.allocPrint(
        allocator,
        "Which shell? bash, zsh or fish{s}",
        .{if (shell.len > 0) " — not that one." else "."},
    ));
    return 2;
}

/// Every subcommand, in one place, so the three completion scripts and the
/// usage screen cannot drift apart. A host's extra words are appended at run
/// time — see `Extension.words`.
const command_words =
    "about archive audit autoload browse bump check-platform-reqs clear-cache compat completion " ++
    "config content-hash create-project diagnose dump-autoload exec fund global home init install " ++
    "licenses list lock outdated policy prohibits reinstall remove repository require resolve " ++
    "run-script search self-update show status suggests update validate why";

/// The script for `shell`, or null for a shell there is none for.
///
/// Built for however the tool is invoked. Standalone, the command word is the
/// first argument (`ppkg install`); under a host it is the second (`hkm ppkg
/// install`), and the script must hook the HOST's executable and wait for the
/// subcommand word before offering anything.
///
/// Written out per shell rather than generated from one template: each wants a
/// different shape, and a generator covering all three would be longer than the
/// scripts and harder to check against a real shell. Concatenated rather than
/// formatted because these are full of `${...}` — a format string would need
/// every brace in three shell dialects escaped correctly, which is a bug
/// waiting to happen in a file nobody runs.
fn completionScript(allocator: std.mem.Allocator, shell: []const u8, words: []const u8) !?[]const u8 {
    // `hkm ppkg` → exe `hkm`, anchor `ppkg`, depth 2. `ppkg` → all three `ppkg`/1.
    var it = std.mem.tokenizeScalar(u8, host.program, ' ');
    const exe = it.next() orelse "ppkg";
    var anchor = exe;
    var depth: usize = 1;
    while (it.next()) |w| {
        anchor = w;
        depth += 1;
    }

    if (eq(shell, "bash")) {
        const func = try std.mem.concat(allocator, u8, &.{ "_", host.program });
        for (func) |*c| {
            if (c.* == ' ' or c.* == '-') c.* = '_';
        }
        return try std.mem.concat(allocator, u8, &.{
            "# ",                                         host.program,
            " completion — source this, or drop it in /etc/bash_completion.d\n",
            func,                                         "() {\n",
            "    local cur prev\n",                       "    cur=\"${COMP_WORDS[COMP_CWORD]}\"\n",
            "    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n", "    if [ \"$prev\" = \"",
            anchor,                                       "\" ] || [ \"$prev\" = \"global\" ]; then\n",
            "        COMPREPLY=( $(compgen -W \"",        words,
            "\" -- \"$cur\") )\n",                        "        return 0\n",
            "    fi\n",                                   "    COMPREPLY=( $(compgen -f -- \"$cur\") )\n",
            "}\n",                                        "complete -F ",
            func,                                         " ",
            exe,
        });
    }
    if (eq(shell, "zsh")) {
        const at_command = if (depth == 1)
            "(( CURRENT == 2 ))"
        else
            try std.fmt.allocPrint(allocator, "(( CURRENT == {d} )) && [[ ${{words[{d}]}} == {s} ]]", .{ depth + 1, depth, anchor });
        return try std.mem.concat(allocator, u8, &.{
            "#compdef ", exe,            "\n",
            "# ",        host.program,
            " completion — put this on your $fpath as _",
            exe,         "\n",           "_",
            exe,         "() {\n",       "    if ",
            at_command,  "; then\n",     "        compadd -- ",
            words,       "\n",           "        return\n",
            "    fi\n",  "    _files\n", "}\n",
            "_",         exe,            " \"$@\"",
        });
    }
    if (eq(shell, "fish")) {
        const at_command = if (depth == 1)
            "__fish_use_subcommand"
        else
            try std.mem.concat(allocator, u8, &.{ "__fish_seen_subcommand_from ", anchor });
        return try std.mem.concat(allocator, u8, &.{
            "# ",           host.program,
            " completion — save as ~/.config/fish/completions/",
            exe,            ".fish\n",
            "complete -c ", exe,
            " -n '",        at_command,
            "' -a '",       words,
            "'",
        });
    }
    return null;
}

fn reportRead(allocator: std.mem.Allocator, e: anyerror) u8 {
    report.err(switch (e) {
        error.NoInstalledJson => "No installed tree here — run `ppkg install` first.",
        error.MalformedInstalled => "vendor/composer/installed.json could not be parsed.",
        else => std.fmt.allocPrint(allocator, "Failed: {s}", .{@errorName(e)}) catch "Failed.",
    });
    return 1;
}

/// `ppkg config …`
fn configCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var do_list = false;
    var do_unset = false;
    var positional: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--list") or eq(a, "-l")) {
            do_list = true;
        } else if (eq(a, "--unset")) {
            do_unset = true;
        } else if ((eq(a, "-d") or eq(a, "--working-dir")) and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            try positional.append(allocator, a);
        }
    }

    const root_dir = try util.absPath(allocator, env, target);

    if (do_list or positional.items.len == 0) {
        report.intro("ppkg config");
        return ppkg.config.list(allocator, io, root_dir);
    }
    if (do_unset) {
        report.intro("ppkg config");
        return ppkg.config.unset(allocator, io, root_dir, positional.items[0]);
    }
    if (positional.items.len == 1) {
        // Bare value on stdout — no frame, so a shell can capture it.
        return ppkg.config.get(allocator, io, root_dir, positional.items[0]);
    }
    report.intro("ppkg config");
    return ppkg.config.set(allocator, io, root_dir, positional.items[0], positional.items[1]);
}

/// `ppkg init --name vendor/package …`
fn initCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var opts: ppkg.config.InitOptions = .{};
    var require: std.ArrayList(ppkg.manifest.Dep) = .empty;
    var require_dev: std.ArrayList(ppkg.manifest.Dep) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;

        if (eq(a, "--name") and next != null) {
            i += 1;
            opts.name = next.?;
        } else if (eq(a, "--description") and next != null) {
            i += 1;
            opts.description = next.?;
        } else if (eq(a, "--type") and next != null) {
            i += 1;
            opts.kind = next.?;
        } else if (eq(a, "--license") and next != null) {
            i += 1;
            opts.license = next.?;
        } else if (eq(a, "--homepage") and next != null) {
            i += 1;
            opts.homepage = next.?;
        } else if (eq(a, "--author") and next != null) {
            i += 1;
            opts.author = next.?;
        } else if (eq(a, "--stability") or eq(a, "-s")) {
            if (next) |v| {
                i += 1;
                opts.stability = v;
            }
        } else if (eq(a, "--autoload") and next != null) {
            i += 1;
            opts.autoload = next.?;
        } else if (eq(a, "--require") and next != null) {
            i += 1;
            const spec = ppkg.edit.Spec.parse(next.?);
            try require.append(allocator, .{ .name = spec.name, .constraint = spec.constraint orelse "*" });
        } else if (eq(a, "--require-dev") and next != null) {
            i += 1;
            const spec = ppkg.edit.Spec.parse(next.?);
            try require_dev.append(allocator, .{ .name = spec.name, .constraint = spec.constraint orelse "*" });
        } else if (eq(a, "--force") or eq(a, "-f")) {
            opts.force = true;
        } else if ((eq(a, "-d") or eq(a, "--working-dir")) and next != null) {
            i += 1;
            target = next.?;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }

    opts.require = require.items;
    opts.require_dev = require_dev.items;

    const root_dir = try util.absPath(allocator, env, target);
    report.intro("ppkg init");
    return ppkg.config.init(allocator, io, root_dir, opts);
}

/// `ppkg audit [path]`
fn auditCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var opts: ppkg.advisory.Options = .{};
    for (args) |a| {
        if (eq(a, "--no-dev")) {
            opts.dev = false;
        } else if (eq(a, "--advisory-only") or eq(a, "--no-fail")) {
            opts.advisory_only = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }
    const root_dir = try util.absPath(allocator, env, target);
    report.intro("ppkg audit");
    return ppkg.advisory.audit(allocator, io, env, root_dir, opts);
}

/// `ppkg search <terms…>`
fn searchCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    _ = env;
    var limit: usize = 15;
    var terms: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((eq(a, "--limit") or eq(a, "-n")) and i + 1 < args.len) {
            i += 1;
            limit = std.fmt.parseInt(usize, args[i], 10) catch 15;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            try terms.append(allocator, a);
        }
    }

    if (terms.items.len == 0) {
        report.err("Usage: `ppkg search <terms…>`");
        return 2;
    }

    const query = try std.mem.join(allocator, " ", terms.items);
    report.intro("ppkg search");
    return ppkg.advisory.search(allocator, io, query, limit, ppkg.advisory.default_repo);
}

/// `ppkg bump [path]`
fn bumpCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var opts: ppkg.maintain.BumpOptions = .{};
    for (args) |a| {
        if (eq(a, "--dry-run")) {
            opts.dry_run = true;
        } else if (eq(a, "--no-dev")) {
            opts.dev = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }
    const root_dir = try util.absPath(allocator, env, target);
    report.intro("ppkg bump");
    return ppkg.maintain.bump(allocator, io, root_dir, opts);
}

/// `ppkg reinstall <pkg>…`
fn reinstallCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((eq(a, "-d") or eq(a, "--working-dir")) and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            try names.append(allocator, a);
        }
    }
    const root_dir = try util.absPath(allocator, env, target);
    report.intro("ppkg reinstall");
    return ppkg.maintain.reinstall(allocator, io, env, root_dir, names.items);
}

/// `ppkg exec [binary] [args…]`
///
/// Everything after the binary name is the BINARY's, so no option parsing runs
/// past it — `ppkg exec phpunit --filter X` must pass `--filter` on rather
/// than reject it.
fn execCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var start: usize = 0;

    if (args.len >= 2 and (eq(args[0], "-d") or eq(args[0], "--working-dir"))) {
        target = args[1];
        start = 2;
    }

    const root_dir = try util.absPath(allocator, env, target);
    return ppkg.maintain.exec(allocator, io, env, root_dir, args[start..]);
}

/// How this build runs a project's `scripts`.
///
/// The two paths it fills in are the ones a library cannot know: which PHP to
/// use, and where this executable is so that `@composer …` can re-enter it.
///
/// `self_binary` comes from the host (`Options.self_command`): argv[0] is not
/// reachable from here, and inventing a path that might be wrong is worse than
/// saying so — `@composer` reports that it was skipped instead.
fn scriptOptions(env: *EnvMap, disabled: bool) ppkg.scripts.Options {
    return .{
        .disabled = disabled,
        .php = env.get("HKM_PHP") orelse "php",
        .self_binary = host.self_command,
    };
}

/// `ppkg run-script <name> [--] [args…]`
///
/// Composer's `run-script`. The project's own tasks — `test`, `lint`, `cs-fix`
/// — live in the same `scripts` block as the install hooks and are invoked by
/// NAME, which is what this does.
fn runScriptCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var name: ?[]const u8 = null;
    var list = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--list") or eq(a, "-l")) {
            list = true;
        } else if ((eq(a, "-d") or eq(a, "--working-dir")) and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else if (name == null) {
            name = a;
        }
    }

    const root_dir = try util.absPath(allocator, env, target);
    const root = (try manifest.read(allocator, io, root_dir)) orelse {
        report.err("No composer.json here.");
        return 1;
    };

    if (list or name == null) {
        report.intro("ppkg run-script");
        if (root.scripts.len == 0) {
            report.note("This project declares no scripts.");
            return 0;
        }
        report.section("Scripts");
        for (root.scripts) |sname| report.item(sname, "");
        report.blank();
        return 0;
    }

    const lay = try ppkg.layout.resolve(allocator, env, root_dir, root);
    return ppkg.scripts.runNamed(
        allocator,
        io,
        env,
        lay,
        name.?,
        scriptOptions(env, false),
    );
}

/// `ppkg require <pkg>[:<constraint>]…` and `ppkg remove <pkg>…`
///
/// The two commands that change what a project depends on. `-d <dir>` chooses
/// the project, because unlike every other subcommand here the bare arguments
/// are PACKAGE NAMES — a trailing path would be indistinguishable from one.
fn editCmd(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    args_in: []const []const u8,
    which: enum { require, remove },
) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    var target: []const u8 = ".";
    var opts: ppkg.edit.Options = .{};
    var no_scripts = false;
    var names: std.ArrayList([]const u8) = .empty;
    var ignore_names: std.ArrayList([]const u8) = .empty;
    var ignore_all = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--dev") or eq(a, "--dev-only")) {
            opts.dev = true;
        } else if (eq(a, "--fixed")) {
            opts.fixed = true;
        } else if (eq(a, "-W") or eq(a, "--with-all-dependencies")) {
            opts.with_all_dependencies = true;
        } else if (eq(a, "-w") or eq(a, "--with-dependencies")) {
            opts.with_dependencies = true;
        } else if (eq(a, "--update-no-dev")) {
            opts.update_no_dev = true;
        } else if (eq(a, "--prefer-lowest")) {
            opts.prefer_lowest = true;
        } else if (eq(a, "--prefer-stable")) {
            opts.prefer_stable = true;
        } else if (try takeIgnorePlatform(allocator, a, &ignore_names, &ignore_all)) {
            // recorded below
        } else if (eq(a, "--no-update")) {
            opts.no_update = true;
        } else if (eq(a, "--no-install")) {
            opts.no_install = true;
        } else if (eq(a, "--dry-run")) {
            opts.dry_run = true;
        } else if (eq(a, "--sort-packages")) {
            opts.sort = true;
        } else if (eq(a, "--no-sort-packages")) {
            opts.sort = false;
        } else if (eq(a, "--refresh")) {
            opts.refresh = true;
        } else if (eq(a, "-o") or eq(a, "--optimize") or eq(a, "--optimize-autoloader")) {
            opts.optimize = true;
        } else if (eq(a, "--ignore-unsupported")) {
            opts.ignore_unsupported = true;
        } else if (eq(a, "--no-scripts")) {
            no_scripts = true;
        } else if ((eq(a, "-d") or eq(a, "--working-dir")) and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, a, "--working-dir=")) {
            target = a["--working-dir=".len..];
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            try names.append(allocator, a);
        }
    }

    opts.scripts = scriptOptions(env, no_scripts);
    opts.ignore_platform = .{ .all = ignore_all, .names = ignore_names.items };
    if (g.no_cache) ppkg.fetch.bypass_cache = true;

    const root_dir = try util.absPath(allocator, env, targetDir(g, target));

    const started = std.Io.Timestamp.now(io, .awake);
    switch (which) {
        .require => {
            report.intro("ppkg require");
            var specs: std.ArrayList(ppkg.edit.Spec) = .empty;
            for (names.items) |n| try specs.append(allocator, ppkg.edit.Spec.parse(n));
            const code = try ppkg.edit.require(allocator, io, env, root_dir, specs.items, opts);
            return finishEdit(allocator, io, started, code, opts);
        },
        .remove => {
            report.intro("ppkg remove");
            const code = try ppkg.edit.remove(allocator, io, env, root_dir, names.items, opts);
            return finishEdit(allocator, io, started, code, opts);
        },
    }
}

fn finishEdit(
    allocator: std.mem.Allocator,
    io: Io,
    started: std.Io.Timestamp,
    code: u8,
    opts: ppkg.edit.Options,
) !u8 {
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    report.blank();
    if (code == 0) {
        // Say what actually happened. "everything agrees" after `--no-update`
        // would be a claim about a lock this run deliberately did not touch.
        report.ok(if (opts.dry_run)
            "Nothing was written."
        else if (opts.no_update)
            "composer.json updated. composer.lock is now stale — run `ppkg update`."
        else if (opts.no_install)
            "composer.json and composer.lock agree. Run `ppkg install` for vendor/."
        else
            "composer.json, composer.lock and vendor/ agree.");
        report.outro(try std.fmt.allocPrint(allocator, "{d}ms", .{elapsed_ms}));
    }
    return code;
}

/// `ppkg compat [path]` — would this project survive being handled here?
///
/// The question this command answers is the one to ask BEFORE switching a
/// project over, and it answers it without touching anything.
/// The project's composer.json as raw json.
///
/// `compat` needs `extra` and `config.allow-plugins` as they were WRITTEN —
/// both are arbitrary objects belonging to whichever tool declared them, so
/// there is nothing for the manifest parser to model.
fn rootJson(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) ?std.json.Value {
    const path = std.fs.path.join(allocator, &.{ root_dir, "composer.json" }) catch return null;
    const body = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch null;
}

fn compatCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        }
        target = a;
    }

    const root_dir = try util.absPath(allocator, env, target);
    const root = (try ppkg.manifest.read(allocator, io, root_dir)) orelse {
        report.err("No composer.json here.");
        return 1;
    };

    report.intro("ppkg compat");

    // With a tree on disk there is more to say than the manifest can answer —
    // which plugins are actually installed, and what each one would have done.
    // Without one, the manifest-only audit is all there is, which is the right
    // answer for a fresh checkout.
    const lay = try ppkg.layout.resolve(allocator, env, root_dir, root);
    const audit = if (ppkg.manifest.readInstalled(allocator, io, lay.vendor) catch null) |installed|
        try ppkg.compat.auditInstalled(
            allocator,
            root,
            rootJson(allocator, io, root_dir) orelse .null,
            installed,
        )
    else
        try ppkg.compat.audit(allocator, root);
    if (audit.findings.len == 0) {
        report.ok("Nothing in this composer.json is unsupported.");
        report.note("install, update, autoload and the inspection commands will behave as composer does.");
        report.outro("compatible");
        return 0;
    }

    for (audit.findings) |f| {
        const line = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ f.subject, f.detail });
        switch (f.severity) {
            .blocking => report.err(line),
            .warning => report.warn(line),
        }
    }

    report.blank();
    report.item("blocking", try std.fmt.allocPrint(allocator, "{d}", .{audit.blocking()}));
    report.item("warnings", try std.fmt.allocPrint(allocator, "{d}", .{audit.warnings()}));

    if (audit.blocking() > 0) {
        report.outro("use composer for this project");
        return 1;
    }
    report.outro("usable, with the caveats above");
    return 0;
}

/// `ppkg archive [pkg] [-f tar|tar.gz|zip] [--dir D] [--file N] [--ignore-filters]`
///
/// Only the ROOT project is archived. Composer also accepts a package name and
/// archives that dependency instead; that is a different command wearing the
/// same name — it resolves and downloads — and it is not implemented, so it is
/// refused by name rather than silently archiving the wrong thing.
fn archiveCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args_in: []const []const u8) !u8 {
    var g: Global = .{};
    const args = try takeGlobals(allocator, args_in, &g);

    var target: []const u8 = ".";
    var format: ppkg.pack.Format = .tar;
    var out_dir: []const u8 = ".";
    var file_name: ?[]const u8 = null;
    var ignore_filters = false;
    var positional: usize = 0;
    var format_given = false;
    var dir_given = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((eq(a, "-f") or eq(a, "--format")) and i + 1 < args.len) {
            i += 1;
            format = ppkg.pack.Format.parse(args[i]) orelse {
                report.err(try std.fmt.allocPrint(
                    allocator,
                    "Unknown archive format '{s}'. Use tar, tar.gz or zip.",
                    .{args[i]},
                ));
                return 2;
            };
            format_given = true;
        } else if (std.mem.startsWith(u8, a, "--format=")) {
            format = ppkg.pack.Format.parse(a["--format=".len..]) orelse {
                report.err("Unknown archive format. Use tar, tar.gz or zip.");
                return 2;
            };
            format_given = true;
        } else if (eq(a, "--dir") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
            dir_given = true;
        } else if (std.mem.startsWith(u8, a, "--dir=")) {
            out_dir = a["--dir=".len..];
            dir_given = true;
        } else if (eq(a, "--file") and i + 1 < args.len) {
            i += 1;
            file_name = args[i];
        } else if (std.mem.startsWith(u8, a, "--file=")) {
            file_name = a["--file=".len..];
        } else if (eq(a, "--ignore-filters")) {
            ignore_filters = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            positional += 1;
            if (positional > 1) {
                report.err("Archiving a named PACKAGE is not implemented — this archives the project in `path`.");
                return 2;
            }
            target = a;
        }
    }

    const root_dir = try util.absPath(allocator, env, targetDir(g, target));

    // `config.archive-format` and `config.archive-dir` — the project's stated
    // defaults, below an explicit flag and above the built-in ones.
    const cfg = ppkg.settings.load(allocator, io, env, root_dir);
    if (!format_given) {
        format = ppkg.pack.Format.parse(cfg.archiveFormat()) orelse format;
    }
    if (!dir_given) out_dir = cfg.archiveDir();
    const root = (try manifest.read(allocator, io, root_dir)) orelse {
        report.err(try std.fmt.allocPrint(allocator, "No composer.json in {s}.", .{root_dir}));
        return 1;
    };

    report.intro("ppkg archive");

    // A root package usually declares no version — Composer defaults to
    // `1.0.0+no-version-set` and puts that in the filename, so the archive says
    // plainly that the version is not one the project claimed.
    const version = if (root.version.len > 0) root.version else "1.0.0+no-version-set";
    const name = if (root.name.len > 0) root.name else std.fs.path.basename(root_dir);

    const stem = file_name orelse try ppkg.pack.archiveName(allocator, name, version);
    const dest = try std.fs.path.join(allocator, &.{
        try util.absPath(allocator, env, out_dir),
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, format.suffix() }),
    });

    const stats = ppkg.pack.create(allocator, io, root_dir, dest, root, .{
        .format = format,
        .ignore_filters = ignore_filters,
    }) catch |e| {
        report.err(switch (e) {
            error.NothingToArchive => "nothing to archive — every file is excluded.",
            else => "the archive could not be written.",
        });
        return 1;
    };

    report.item("files", try std.fmt.allocPrint(allocator, "{d}", .{stats.files}));
    report.item("written", stats.path);
    report.outro(try std.fmt.allocPrint(allocator, "{d} bytes", .{stats.bytes}));
    return 0;
}

/// `ppkg diagnose [path] [--offline]`
fn diagnoseCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var target: []const u8 = ".";
    var offline = false;

    for (args) |a| {
        if (eq(a, "--offline") or eq(a, "--no-network")) {
            offline = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else {
            target = a;
        }
    }

    return ppkg.diagnose.run(
        allocator,
        io,
        env,
        try util.absPath(allocator, env, target),
        .{ .offline = offline },
    );
}

/// `ppkg create-project <vendor/package> [dir] [version] [--no-install] [--no-dev]`
fn createProjectCmd(allocator: std.mem.Allocator, io: Io, env: *EnvMap, args: []const []const u8) !u8 {
    var name: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var version: []const u8 = "";
    var opts: ppkg.project.CreateOptions = .{};
    var no_scripts = false;

    for (args) |a| {
        if (eq(a, "--no-install")) {
            opts.no_install = true;
        } else if (eq(a, "--no-dev")) {
            opts.dev = false;
        } else if (eq(a, "--no-scripts")) {
            no_scripts = true;
        } else if (eq(a, "--ignore-lock") or eq(a, "--no-lock")) {
            // Re-resolve rather than honouring the versions the package's
            // author shipped. Off by default: their lock is a statement about
            // what they tested.
            opts.prefer_lock = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        } else if (name == null) {
            name = a;
        } else if (dir == null) {
            dir = a;
        } else {
            version = a;
        }
    }

    const package = name orelse {
        report.err("Which package? `ppkg create-project vendor/package [dir] [version]`.");
        return 2;
    };

    opts.constraint = version;
    opts.scripts = scriptOptions(env, no_scripts);

    // The directory Composer picks when none is given: the package's own name,
    // without the vendor.
    const into = dir orelse blk: {
        const slash = std.mem.lastIndexOfScalar(u8, package, '/') orelse break :blk package;
        break :blk package[slash + 1 ..];
    };

    return ppkg.project.createProject(
        allocator,
        io,
        env,
        package,
        try util.absPath(allocator, env, into),
        opts,
    );
}

/// `ppkg self-update`
fn selfUpdateCmd(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "-") and !eq(a, "--check")) {
            report.err(try std.fmt.allocPrint(allocator, "Unknown option '{s}'.", .{a}));
            return 2;
        }
    }

    report.intro("ppkg self-update");

    const exe = host.executable;
    const how = ppkg.project.installationOf(exe);

    report.item("running", if (host.version.len > 0) host.version else "unknown");
    if (exe.len > 0) report.item("binary", exe);

    const latest = ppkg.project.latestRelease(allocator, io, host.release_repo) orelse {
        report.warn("The release list could not be read — no network, or the API is rate-limited.");
        report.outro("unknown");
        return 0;
    };
    report.item("latest release", latest);

    if (!ppkg.project.isNewer(host.version, latest)) {
        report.ok("Already on the newest release.");
        report.outro("current");
        return 0;
    }

    // Deliberately does NOT replace the binary — see `project.zig`. Whatever
    // put this file here (Homebrew, an installer, a build tree) owns it, and a
    // package manager overwriting a file Homebrew believes it manages leaves
    // the machine in a state neither tool can reason about.
    report.note(try std.fmt.allocPrint(allocator, "{s} is available.", .{latest}));
    report.item("upgrade with", how.upgradeCommand(allocator, exe));
    report.outro("update available");
    return 0;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "completion hooks the executable the user actually types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer host = .{};

    // Standalone: the command word is the first argument.
    host = .{ .program = "ppkg" };
    const bash = (try completionScript(a, "bash", "install")).?;
    try testing.expect(std.mem.endsWith(u8, bash, "complete -F _ppkg ppkg"));
    try testing.expect(std.mem.indexOf(u8, bash, "[ \"$prev\" = \"ppkg\" ]") != null);
    try testing.expect(std.mem.indexOf(u8, (try completionScript(a, "zsh", "install")).?, "(( CURRENT == 2 ))") != null);
    try testing.expect(std.mem.indexOf(u8, (try completionScript(a, "fish", "install")).?, "complete -c ppkg -n '__fish_use_subcommand'") != null);

    // Under a host: the HOST's executable is hooked, and nothing is offered
    // until the subcommand word has been typed.
    host = .{ .program = "hkm ppkg" };
    try testing.expect(std.mem.endsWith(u8, (try completionScript(a, "bash", "install")).?, "complete -F _hkm_ppkg hkm"));
    try testing.expect(std.mem.indexOf(u8, (try completionScript(a, "zsh", "install")).?, "(( CURRENT == 3 )) && [[ ${words[2]} == ppkg ]]") != null);
    try testing.expect(std.mem.indexOf(u8, (try completionScript(a, "fish", "install")).?, "complete -c hkm -n '__fish_seen_subcommand_from ppkg'") != null);

    try testing.expect((try completionScript(a, "powershell", "install")) == null);
}

test "global flags are found before the command word, and only there for exec" {
    try testing.expectEqual(@as(usize, 0), leadingGlobals(&.{ "install", "-q" }));
    try testing.expectEqual(@as(usize, 3), leadingGlobals(&.{ "-q", "-d", "app", "install" }));
    try testing.expectEqual(@as(usize, 1), leadingGlobals(&.{ "--working-dir=app", "show" }));
    // `exec -q phpunit -v`: the -v belongs to phpunit.
    try testing.expectEqual(@as(usize, 1), leadingGlobals(&.{ "-q", "phpunit", "-v" }));
    // A trailing -d is left for takeGlobals to report, not silently eaten.
    try testing.expectEqual(@as(usize, 0), leadingGlobals(&.{"-d"}));
    try testing.expectEqual(@as(usize, 0), leadingGlobals(&.{}));
}

test "takeGlobals strips every global flag, and nothing after --" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g: Global = .{};
    const rest = try takeGlobals(a, &.{ "symfony", "-q", "--no-cache", "-d", "app", "-n", "--", "-q" }, &g);
    try testing.expectEqual(@as(usize, 3), rest.len);
    try testing.expectEqualStrings("symfony", rest[0]);
    try testing.expectEqualStrings("--", rest[1]);
    try testing.expectEqualStrings("-q", rest[2]);
    try testing.expect(g.quiet and g.no_cache and g.no_interaction);
    try testing.expectEqualStrings("app", g.working_dir.?);

    var h: Global = .{};
    try testing.expectError(error.MissingValue, takeGlobals(a, &.{"-d"}, &h));
}

test "every command either reads the global flags itself or is routed through withGlobals" {
    // The eight that read them themselves must really be package commands —
    // a typo here would send that word through `.?` on a null route.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "autoload", "install", "update", "repository", "policy", "require", "remove", "archive" }) |w| {
        try testing.expect(readsOwnGlobals(w));
    }
    try testing.expect(!readsOwnGlobals("show"));
    try testing.expect(!readsOwnGlobals("exec"));
}
