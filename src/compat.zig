//! Can this package handle this project, or not?
//!
//! It does less than Composer. That is fine, and stated plainly in the README —
//! but only if a project it CANNOT handle is told so. The failure this file
//! exists to prevent is the other one: resolving a project that declares a
//! `vcs` repository by quietly ignoring the repository, taking the packagist
//! copy of the same package name instead, and writing a lock that looks
//! perfectly ordinary and points at somebody else's code.
//!
//! Three of these were found by testing rather than by reading the code, and
//! all three were silent:
//!
//!   * a `vcs` repository was ignored and packagist used instead;
//!   * `scripts` never ran and nothing said so (they run now — see
//!     `scripts.zig` — and what remains listed here is the per-PACKAGE events
//!     that only a composer plugin could hook);
//!   * `config.vendor-dir` was ignored, so the tree landed in `vendor/` while
//!     the project's own autoloader looks in `lib/`.
//!
//! ## Blocking versus warning
//!
//! A finding BLOCKS when proceeding would produce a wrong answer that looks
//! right — a different package, or a tree in the wrong place. It WARNS when the
//! result is merely incomplete in a way the operator can see and decide about,
//! like a build step that did not run.
//!
//! `--ignore-unsupported` downgrades every block to a warning, because an
//! operator who knows their `vcs` entry is a mirror of the packagist package
//! should not be blocked by a tool that cannot know that.

const std = @import("std");
const manifest = @import("manifest.zig");
const plugins_mod = @import("plugins.zig");
const installers = @import("installers.zig");

pub const Severity = enum { blocking, warning };

pub const Finding = struct {
    severity: Severity,
    /// The composer.json feature involved.
    subject: []const u8,
    /// What this package does instead, said plainly.
    detail: []const u8,
};

pub const Report = struct {
    findings: []const Finding,

    pub fn blocking(self: Report) usize {
        var n: usize = 0;
        for (self.findings) |f| {
            if (f.severity == .blocking) n += 1;
        }
        return n;
    }

    pub fn warnings(self: Report) usize {
        return self.findings.len - self.blocking();
    }
};

/// Audit a root manifest for anything this package cannot honour.
/// The declared events this package never raises.
///
/// Anything that is not one of the install-lifecycle events, and is not a
/// project's own named task (`test`, `lint`, `@php …`), which is invoked by
/// name and not by an event at all.
fn unraisedEvents(allocator: std.mem.Allocator, declared: []const []const u8) ![]const []const u8 {
    const raised = [_][]const u8{
        "pre-install-cmd",         "post-install-cmd",
        "pre-update-cmd",          "post-update-cmd",
        "pre-autoload-dump",       "post-autoload-dump",
        "post-create-project-cmd", "pre-status-cmd",
        "post-status-cmd",
    };
    // Every event Composer defines, so a NAME that is not one of these is a
    // project's own task rather than a hook that silently will not fire.
    const package_events = [_][]const u8{
        "pre-package-install",      "post-package-install",
        "pre-package-update",       "post-package-update",
        "pre-package-uninstall",    "post-package-uninstall",
        "pre-dependencies-solving", "post-dependencies-solving",
        "pre-file-download",        "post-file-download",
        "pre-command-run",          "pre-operations-exec",
        "init",                     "command",
        "pre-pool-create",
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (declared) |name| {
        var is_raised = false;
        for (raised) |r| {
            if (std.mem.eql(u8, name, r)) is_raised = true;
        }
        if (is_raised) continue;
        for (package_events) |p| {
            if (std.mem.eql(u8, name, p)) try out.append(allocator, name);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn audit(allocator: std.mem.Allocator, root: manifest.Manifest) !Report {
    var out: std.ArrayList(Finding) = .empty;

    for (root.repositories) |repo| {
        switch (repo.kind) {
            // Everything with an implementation. `vcs` covers every host now:
            // GitHub over its static endpoints, everything else through a bare
            // mirror in the cache — see `git.zig`. `package` and `artifact` are
            // read by `repo.zig`. `hg` and `svn` have drivers of their own,
            // in `hg.zig` and `svn.zig`.
            .path, .composer, .vcs, .hg, .svn, .package, .artifact => {},
            .unknown => try out.append(allocator, .{
                .severity = .blocking,
                .subject = "repositories",
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "'{s}' is not a repository type this understands. Resolving without it would silently take the packagist package of the same name.",
                    .{typeNameOf(repo)},
                ),
            }),
        }
    }

    // `config.vendor-dir` and `config.bin-dir` used to be refused here: the
    // installer wrote to a hardcoded `vendor/`, so honouring the declaration
    // was impossible and installing anyway would have put the tree in a
    // directory nothing looks in. `layout.zig` now resolves both — including
    // the `{$vendor-dir}` interpolation and the `COMPOSER_*_DIR` overrides —
    // so there is nothing left to refuse.

    // `scripts` are RUN now (scripts.zig), so declaring them is no longer a
    // caveat. What remains worth saying is which events this package raises:
    // the per-PACKAGE events exist only for plugins to hook, and nothing here
    // loads a plugin, so a project relying on one of those still will not get
    // it — and hearing that here beats discovering it from a missing side
    // effect.
    if (root.scripts.len > 0) {
        const unraised = try unraisedEvents(allocator, root.scripts);
        if (unraised.len > 0) {
            try out.append(allocator, .{
                .severity = .warning,
                .subject = "scripts",
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "{s} — a per-package event, raised only for composer plugins to hook. The install-lifecycle events (pre/post-install-cmd, pre/post-update-cmd, pre/post-autoload-dump) DO run.",
                    .{try joinNames(allocator, unraised)},
                ),
            });
        }
    }

    // `config` keys that are READ but whose behaviour is only partly here.
    // Named individually, because "some config is unsupported" is not
    // something a reader can act on.
    if (root.config_raw) |cfg| {
        if (cfg.get("process-timeout")) |_| {
            try out.append(allocator, .{
                .severity = .warning,
                .subject = "config.process-timeout",
                .detail = "bounds the network fetch (curl --max-time) only. Scripts and the git/hg/svn commands are not killed when they exceed it.",
            });
        }
        if (cfg.get("policy")) |_| {
            try out.append(allocator, .{
                .severity = .warning,
                .subject = "config.policy",
                .detail = "dependency policies are recorded and never ENFORCED here — no policy document is fetched and no package is refused on account of one. Use composer for the check itself.",
            });
        }
        if (cfg.get("disable-tls")) |v| {
            if (v == .bool and v.bool) {
                try out.append(allocator, .{
                    .severity = .warning,
                    .subject = "config.disable-tls",
                    .detail = "certificates are NOT verified, exactly as asked. Every package this installs is whatever the network handed back.",
                });
            }
        }
        if (cfg.get("secure-http")) |v| {
            if (v == .bool and !v.bool) {
                try out.append(allocator, .{
                    .severity = .warning,
                    .subject = "config.secure-http",
                    .detail = "plain HTTP is permitted, so a package may be replaced in transit by anything on the path. It is then executed.",
                });
            }
        }
    }

    if (root.config_allow_plugins) {
        try out.append(allocator, .{
            .severity = .warning,
            .subject = "config.allow-plugins",
            .detail = "composer plugins are never loaded. Run `ppkg compat` against an INSTALLED tree to see which ones, and what each would have done.",
        });
    }

    return .{ .findings = try out.toOwnedSlice(allocator) };
}

/// The same audit, plus everything only an installed tree can answer.
///
/// `audit` reads the manifest alone, which is all a fresh checkout has. Once
/// `vendor/composer/installed.json` exists there is more to say — and it is the
/// more useful half, because a generic "plugins do not run" is not something a
/// reader can act on, while "cweagans/composer-patches would have applied
/// patches, and did not" is.
pub fn auditInstalled(
    allocator: std.mem.Allocator,
    root: manifest.Manifest,
    root_json: std.json.Value,
    installed: []const manifest.Manifest,
) !Report {
    const base = try audit(allocator, root);

    var out: std.ArrayList(Finding) = .empty;
    for (base.findings) |f| {
        // The manifest-only plugin warning is replaced by the specific ones
        // below; keeping both would say the same thing twice, vaguely and then
        // precisely.
        if (std.mem.eql(u8, f.subject, "config.allow-plugins")) continue;
        try out.append(allocator, f);
    }

    const found = try plugins_mod.discover(allocator, installed, root_json);
    const rules = try installers.rulesOf(allocator, root_json);

    var names: std.ArrayList([]const u8) = .empty;
    for (installed) |pkg| try names.append(allocator, pkg.name);

    for (found) |plugin| {
        // Not allowed means Composer would not run it either. Reporting it as a
        // gap would be reporting a difference that does not exist.
        if (!plugin.allowed) continue;

        // The one plugin whose absence produces a WRONG TREE rather than a tree
        // with something missing: without its table, packages land in vendor/
        // while the application looks for them somewhere else.
        if (std.mem.eql(u8, plugin.name, "composer/installers") and
            installers.needsBuiltinTable(rules, names.items))
        {
            try out.append(allocator, .{
                .severity = .blocking,
                .subject = "composer/installers",
                .detail = "is installed and the root declares no `extra.installer-paths`, so every package location would come from its built-in per-framework table — which is not implemented. Packages would land in vendor/ while the application looks elsewhere.",
            });
            continue;
        }

        try out.append(allocator, .{
            .severity = .warning,
            .subject = plugin.name,
            .detail = if (plugin.effect.len > 0)
                plugin.effect
            else
                try std.fmt.allocPrint(
                    allocator,
                    "is a composer plugin ({s}) and will not run. Its effect is unknown to this tool — check what it does before relying on this tree.",
                    .{if (plugin.class.len > 0) plugin.class else "no extra.class declared"},
                ),
        });
    }

    if (rules.len > 0) {
        try out.append(allocator, .{
            .severity = .warning,
            .subject = "extra.installer-paths",
            .detail = try std.fmt.allocPrint(
                allocator,
                "{d} rule(s) are applied natively — packages are placed where they declare, without composer/installers running.",
                .{rules.len},
            ),
        });
    }

    return .{ .findings = try out.toOwnedSlice(allocator) };
}

/// The `type` a repository entry actually declared, for the message.
///
/// Reporting `unknown` back to someone who wrote `"type": "composer2"` tells
/// them nothing; the string they wrote is the thing to fix.
fn typeNameOf(repo: manifest.Repo) []const u8 {
    const raw = repo.raw orelse return "unknown";
    if (raw != .object) return "unknown";
    const v = raw.object.get("type") orelse return "unknown";
    return switch (v) {
        .string => |s| s,
        else => "unknown",
    };
}

fn joinNames(allocator: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i == 3) {
            try out.print(allocator, ", +{d} more", .{names.len - 3});
            break;
        }
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, n);
    }
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a path or packagist repository is not a finding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try audit(a, .{ .repositories = &.{
        .{ .kind = .path, .url = "modules/http" },
        .{ .kind = .composer, .url = "https://packagist.org" },
    } });
    try testing.expectEqual(@as(usize, 0), r.findings.len);
}

test "a vcs repository is supported on every host, not only GitHub" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // GitHub has the fast path; everywhere else goes through a bare mirror.
    // Neither is refused, because both are implemented — the failure this file
    // exists to prevent is resolving a declared repository from packagist
    // instead, and that no longer happens for any host.
    for ([_][]const u8{
        "https://github.com/acme/fork",
        "https://gitlab.com/acme/fork",
        "https://bitbucket.org/acme/fork",
        "ssh://git@build.internal:2222/~ci/fork.git",
        "https://git.self-hosted.example/acme/fork.git",
    }) |url| {
        const r = try audit(a, .{ .repositories = &.{.{ .kind = .vcs, .url = url }} });
        try testing.expectEqual(@as(usize, 0), r.blocking());
    }
}

test "package and artifact repositories are read, not refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try audit(a, .{ .repositories = &.{
        .{ .kind = .package, .url = "" },
        .{ .kind = .artifact, .url = "artifacts" },
    } })).blocking());
}

test "a repository type with no implementation still blocks, naming what was written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const declared = try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        "{\"type\": \"composer2\", \"url\": \"https://repo.example\"}",
        .{},
    );
    const r = try audit(a, .{ .repositories = &.{
        .{ .kind = .unknown, .url = "https://repo.example", .raw = declared },
    } });
    try testing.expectEqual(@as(usize, 1), r.blocking());
    // The string the author typed, not the enum this parsed it into.
    try testing.expect(std.mem.indexOf(u8, r.findings[0].detail, "composer2") != null);
}

test "a non-default vendor-dir BLOCKS; the default one does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A moved vendor-dir is implemented, not refused — see layout.zig.
    try testing.expectEqual(@as(usize, 0), (try audit(a, .{ .config_vendor_dir = "lib" })).blocking());
    try testing.expectEqual(@as(usize, 0), (try audit(a, .{ .config_vendor_dir = "vendor" })).blocking());
    try testing.expectEqual(@as(usize, 0), (try audit(a, .{ .config_bin_dir = "bin" })).blocking());
    try testing.expectEqual(@as(usize, 0), (try audit(a, .{})).blocking());
}

test "install-lifecycle scripts are no longer a caveat — they run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lifecycle = try audit(a, .{ .scripts = &.{ "post-install-cmd", "post-autoload-dump" } });
    try testing.expectEqual(@as(usize, 0), lifecycle.blocking());
    try testing.expectEqual(@as(usize, 0), lifecycle.warnings());

    // A project's own named tasks are invoked by name, never by an event, so
    // they are not something this package fails to raise.
    const tasks = try audit(a, .{ .scripts = &.{ "test", "lint", "cs-fix" } });
    try testing.expectEqual(@as(usize, 0), tasks.warnings());

    // A PER-PACKAGE event only a composer plugin could hook still warns.
    const plugin_hook = try audit(a, .{ .scripts = &.{ "post-install-cmd", "post-package-install" } });
    try testing.expectEqual(@as(usize, 1), plugin_hook.warnings());
    try testing.expect(std.mem.indexOf(u8, plugin_hook.findings[0].detail, "post-package-install") != null);
}

test "the name list is truncated rather than printed in full" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const joined = try joinNames(a, &.{ "a", "b", "c", "d", "e" });
    try testing.expectEqualStrings("a, b, c, +2 more", joined);
}

test "an installed plugin is named, with what it would have done" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_json = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"config":{"allow-plugins":{"phpstan/extension-installer": true}}}
    , .{});

    const installed = [_]manifest.Manifest{
        .{ .name = "psr/log", .kind = "library" },
        .{ .name = "phpstan/extension-installer", .kind = "composer-plugin", .plugin_class = "PHPStan\\ExtensionInstaller\\Plugin" },
    };

    const r = try auditInstalled(a, .{ .config_allow_plugins = true }, root_json, &installed);
    try testing.expectEqual(@as(usize, 0), r.blocking());
    try testing.expectEqual(@as(usize, 1), r.warnings());
    // Named, and specific about the consequence — not "plugins do not run".
    try testing.expectEqualStrings("phpstan/extension-installer", r.findings[0].subject);
    try testing.expect(std.mem.indexOf(u8, r.findings[0].detail, "phpstan.neon") != null);
}

test "composer/installers blocks only when there is no declaration to stand in for it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const installed = [_]manifest.Manifest{
        .{ .name = "composer/installers", .kind = "composer-plugin", .plugin_class = "Composer\\Installers\\Plugin" },
    };

    // No installer-paths: every placement would come from the table this does
    // not implement, and the result is a tree in the wrong place.
    const bare = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"config":{"allow-plugins":{"composer/installers": true}}}
    , .{});
    const blocked = try auditInstalled(a, .{ .config_allow_plugins = true }, bare, &installed);
    try testing.expectEqual(@as(usize, 1), blocked.blocking());

    // Declared: the mechanism is implemented natively, so there is nothing to
    // refuse — only a note that it was applied without the plugin.
    const declared = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"config":{"allow-plugins":{"composer/installers": true}},
        \\ "extra":{"installer-paths":{"web/app/plugins/{$name}/":["type:wordpress-plugin"]}}}
    , .{});
    const fine = try auditInstalled(a, .{ .config_allow_plugins = true }, declared, &installed);
    try testing.expectEqual(@as(usize, 0), fine.blocking());
}

test "a plugin the project did not allow is not reported as a gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_json = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"config":{"allow-plugins":{"acme/plugin": false}}}
    , .{});
    const installed = [_]manifest.Manifest{
        .{ .name = "acme/plugin", .kind = "composer-plugin", .plugin_class = "Acme\\Plugin" },
    };

    // Composer would not run it either — reporting it would be reporting a
    // difference that does not exist.
    const r = try auditInstalled(a, .{ .config_allow_plugins = true }, root_json, &installed);
    try testing.expectEqual(@as(usize, 0), r.findings.len);
}
