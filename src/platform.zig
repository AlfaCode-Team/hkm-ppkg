//! Platform requirements — `php`, `ext-*`, `lib-*`, `composer-*-api`.
//!
//! A `require` entry naming one of these is not a package to fetch; it is an
//! assertion about the machine. Ignoring them, which this package did until
//! now, means a resolver will happily select a release that needs PHP 8.4 for a
//! runtime that is 8.1 — and the failure surfaces as a parse error inside a
//! vendor file, several steps away from the decision that caused it.
//!
//! ## Where the facts come from
//!
//! One `php -r` probe, run at most once per command, emitting JSON. Not from
//! reading `php.ini`, not from guessing at a binary's name: the answer that
//! matters is what the interpreter *this project runs on* reports about itself,
//! and only that interpreter can say.
//!
//! `config.platform` in composer.json overrides any of it. That is not a
//! convenience — it is how a developer on PHP 8.5 resolves a lock that has to
//! run on the 8.1 in production, and an override must therefore win even when
//! the real value is available and higher.
//!
//! ## What `unmodelled` means now
//!
//! `lib-*` (openssl's libssl, curl's libcurl, intl's ICU) IS determined:
//! `probe.php` ports Composer's whole `PlatformRepository` library switch, and
//! its output matches `composer show --platform` name for name. An absent
//! `lib-*` therefore means absent, exactly as it does for an extension.
//!
//! `unmodelled` is left for the one genuinely unknowable case: no interpreter
//! answered, so nothing about this machine was inspected. The tempting
//! shortcut would be to call that satisfied, which turns a requirement the
//! author wrote down into no requirement at all. A checker that says "I did
//! not check this" is useful; one that says "fine" when it did not look is
//! worse than no checker.

const std = @import("std");
const lock = @import("lock.zig");
const constraint = @import("constraint.zig");
const manifest = @import("manifest.zig");

const Io = std.Io;
const EnvMap = std.process.Environ.Map;

/// The Composer APIs this package reports itself as providing.
///
/// Read from Composer 2.10.3's own source (`Composer::RUNTIME_API_VERSION` and
/// `PluginInterface::PLUGIN_API_VERSION`) rather than invented, because a
/// package that requires `composer-runtime-api ^2.2` is asking whether
/// `InstalledVersions` has the methods it is about to call — and this package
/// installs Composer's own `InstalledVersions.php`, so the honest answer is
/// whatever that file's Composer release provides.
pub const runtime_api_version = "2.2.2";
pub const plugin_api_version = "2.9.0";

pub const Error = error{
    ProbeFailed,
    MalformedProbe,
};

/// One platform fact: a package name and the version it is present at.
pub const Fact = struct {
    name: []const u8,
    /// As reported (`8.5.10`).
    pretty: []const u8,
    /// Composer-normalised (`8.5.10.0`) — what constraints are matched against.
    normalized: []const u8,
    /// Did this come from `config.platform` rather than from the runtime?
    overridden: bool = false,
    /// A name this machine ANSWERS TO without having a library of that name.
    ///
    /// `lib-libxml` provides `lib-dom-libxml`: a constraint on the latter is
    /// satisfied, and a listing of what is installed must not claim it. Composer
    /// models this as a provide link and `show --platform` omits it.
    provided: bool = false,
};

/// The verdict on one requirement.
pub const Verdict = union(enum) {
    /// Present, and the constraint accepts it.
    satisfied: struct { have: []const u8 },
    /// Present, but at a version the constraint rejects.
    conflict: struct { have: []const u8 },
    /// Not present at all — an extension that is not loaded.
    missing,
    /// Nothing could be asked — there was no interpreter to probe. NOT a pass,
    /// and NOT the same as `missing`.
    unmodelled,
    /// The operator waived this one with `--ignore-platform-req`. Distinct
    /// from `satisfied` so a report can say the check was skipped rather than
    /// claim a machine passed something nobody asked it.
    ignored,
};

/// Which platform requirements to stop enforcing — `--ignore-platform-reqs`
/// and its per-name form.
///
/// The flag exists for two situations that are not the same, and Composer
/// spells the difference with a trailing `+`:
///
///   * `--ignore-platform-req=ext-gd` — build a tree on a machine that will
///     never run it (a CI image assembling a deploy artefact for elsewhere);
///   * `--ignore-platform-req=php+` — ignore only the UPPER bound, which is
///     how a project tests against a PHP newer than its dependencies admit
///     without pretending its lower bounds do not exist.
///
/// Ignoring everything is the blunt instrument, and it is deliberately not the
/// default for anything: a platform requirement is the one check that says
/// whether the code about to be installed can run at all.
pub const Ignore = struct {
    /// `--ignore-platform-reqs` — every requirement, both bounds.
    all: bool = false,
    /// Names from `--ignore-platform-req=…`, `+` suffix included as written.
    names: []const []const u8 = &.{},

    pub const none: Ignore = .{};

    /// Is anything being ignored at all?
    pub fn any(self: Ignore) bool {
        return self.all or self.names.len > 0;
    }

    /// Is this requirement ignored outright?
    pub fn covers(self: Ignore, name: []const u8) bool {
        if (self.all) return true;
        for (self.names) |raw| {
            if (std.mem.endsWith(u8, raw, "+")) continue; // upper bound only
            if (matches(raw, name)) return true;
        }
        return false;
    }

    /// Is only this requirement's UPPER bound ignored?
    pub fn upperBoundOnly(self: Ignore, name: []const u8) bool {
        for (self.names) |raw| {
            if (!std.mem.endsWith(u8, raw, "+")) continue;
            if (matches(raw[0 .. raw.len - 1], name)) return true;
        }
        return false;
    }

    /// Composer accepts a `*` in these names, so that `ext-*` turns off every
    /// extension requirement without turning off the `php` one.
    fn matches(pattern: []const u8, name: []const u8) bool {
        if (std.mem.eql(u8, pattern, "*")) return true;
        const star = std.mem.indexOfScalar(u8, pattern, '*') orelse
            return std.ascii.eqlIgnoreCase(pattern, name);
        const head = pattern[0..star];
        const tail = pattern[star + 1 ..];
        if (name.len < head.len + tail.len) return false;
        return std.ascii.startsWithIgnoreCase(name, head) and
            std.ascii.endsWithIgnoreCase(name, tail);
    }
};

pub const Platform = struct {
    facts: []const Fact,
    /// Did an interpreter actually answer?
    ///
    /// False when there was no usable `php` and the only facts are
    /// `config.platform` overrides. The distinction is the difference between
    /// "this machine does not have ext-json" and "nothing here could be asked",
    /// and reporting the first when the second is true is a claim about a
    /// machine that was never inspected.
    probed: bool = true,

    pub const empty: Platform = .{ .facts = &.{}, .probed = false };

    pub fn versionOf(self: Platform, name: []const u8) ?Fact {
        for (self.facts) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
        }
        return null;
    }

    /// Judge one platform requirement.
    pub fn check(self: Platform, allocator: std.mem.Allocator, dep: manifest.Dep) Verdict {
        const fact = self.versionOf(dep.name) orelse {
            // `lib-*` used to land here unconditionally as `unmodelled`,
            // because none of them were determined. They are now — `probe.php`
            // ports Composer's whole `PlatformRepository` library switch, and
            // its output matches `composer show --platform` name for name — so
            // an absent one means absent, exactly as it does for an extension.
            //
            // What is still genuinely unknowable is a machine with no
            // interpreter to ask. That is not the same as a missing extension
            // and must not be reported as one.
            return if (self.probed) .missing else .unmodelled;
        };

        // A constraint this package cannot parse must not become a rejection:
        // the requirement is real, our reading of it is what failed, and
        // failing an install over that would be worse than not checking.
        const c = constraint.parse(allocator, dep.constraint) catch
            return .{ .satisfied = .{ .have = fact.pretty } };

        if (c.accepts(fact.normalized)) return .{ .satisfied = .{ .have = fact.pretty } };
        return .{ .conflict = .{ .have = fact.pretty } };
    }

    /// `check`, with `--ignore-platform-req` applied.
    ///
    /// An ignored requirement returns `ignored` rather than `satisfied`: the
    /// caller stops enforcing it, and a report can still say the check was
    /// waived instead of claiming the machine passed one it was never asked.
    pub fn checkWith(
        self: Platform,
        allocator: std.mem.Allocator,
        dep: manifest.Dep,
        ignore: Ignore,
    ) Verdict {
        if (ignore.covers(dep.name)) return .ignored;

        if (ignore.upperBoundOnly(dep.name)) {
            const fact = self.versionOf(dep.name) orelse
                return if (self.probed) .missing else .unmodelled;
            const c = constraint.parse(allocator, dep.constraint) catch
                return .{ .satisfied = .{ .have = fact.pretty } };
            const lifted = c.withoutUpperBounds(allocator) catch c;
            if (lifted.accepts(fact.normalized)) return .ignored;
            return .{ .conflict = .{ .have = fact.pretty } };
        }

        return self.check(allocator, dep);
    }
};

/// The PHP program that reports the runtime to us.
///
/// A FILE rather than a string literal, because half of it is a port of
/// Composer's `PlatformRepository` library switch — regex for regex — and
/// keeping it as PHP means `php -l` checks it and its output can be diffed
/// against `composer show --platform` directly. Passed on stdin so there is
/// nothing to install alongside the binary.
const probe_source = @embedFile("probe.php");

/// Ask an interpreter about itself.
///
/// `php_bin` is the binary to run — the caller's choice, because which PHP a
/// project runs on is a fact about the project, not about this process.
pub fn detect(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    php_bin: []const u8,
    overrides: []const manifest.Dep,
) !Platform {
    var facts: std.ArrayList(Fact) = .empty;

    const json = probe(allocator, io, env, php_bin) catch |e| {
        // No interpreter is not the same as "nothing is required". Overrides
        // still stand on their own — a project pinning config.platform is
        // describing a machine that is not this one anyway.
        if (overrides.len == 0) return e;
        try applyOverrides(allocator, &facts, overrides);
        return .{ .facts = try facts.toOwnedSlice(allocator), .probed = false };
    };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return Error.MalformedProbe;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return Error.MalformedProbe,
    };

    const php_pretty = trimPhpVersion(switch (root.get("php") orelse return Error.MalformedProbe) {
        .string => |s| s,
        else => return Error.MalformedProbe,
    });

    try add(allocator, &facts, "php", php_pretty, false);

    // Every php-* variant carries the interpreter's OWN version, not a version
    // of its own: `php-64bit: ^8.1` is asking "is this 8.1+ and 64-bit", one
    // question in one constraint.
    if (boolOf(root, "debug")) try add(allocator, &facts, "php-debug", php_pretty, false);
    if (boolOf(root, "zts")) try add(allocator, &facts, "php-zts", php_pretty, false);
    if (boolOf(root, "ipv6")) try add(allocator, &facts, "php-ipv6", php_pretty, false);
    if (root.get("int_size")) |v| switch (v) {
        .integer => |n| if (n == 8) try add(allocator, &facts, "php-64bit", php_pretty, false),
        else => {},
    };

    if (root.get("ext")) |v| switch (v) {
        .object => |exts| {
            var it = exts.iterator();
            while (it.next()) |kv| {
                const raw = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try add(allocator, &facts, kv.key_ptr.*, extensionVersion(raw), false);
            }
        },
        else => {},
    };

    // `lib-*`. Previously these came back as `unmodelled` and were reported as
    // unchecked — never as satisfied, which was the safe direction but meant a
    // project declaring `lib-openssl: ^3.0` got no answer at all.
    if (root.get("lib")) |v| switch (v) {
        .object => |libs| {
            var it = libs.iterator();
            while (it.next()) |kv| {
                const raw = switch (kv.value_ptr.*) {
                    .string => |str| str,
                    else => continue,
                };
                try add(allocator, &facts, kv.key_ptr.*, raw, false);
            }
        },
        else => {},
    };
    if (root.get("libprov")) |v| switch (v) {
        .object => |libs| {
            var it = libs.iterator();
            while (it.next()) |kv| {
                const raw = switch (kv.value_ptr.*) {
                    .string => |str| str,
                    else => continue,
                };
                try addProvided(allocator, &facts, kv.key_ptr.*, raw);
            }
        },
        else => {},
    };

    try add(allocator, &facts, "composer-runtime-api", runtime_api_version, false);
    try add(allocator, &facts, "composer-plugin-api", plugin_api_version, false);

    try applyOverrides(allocator, &facts, overrides);

    return .{ .facts = try facts.toOwnedSlice(allocator) };
}

/// `config.platform` entries replace what was detected, and add what was not.
///
/// A value of `false` in Composer's schema means "pretend this is absent"; that
/// is spelled here by removing the fact rather than recording a version, so a
/// masked extension reads as `missing` and not as version "false".
fn applyOverrides(
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(Fact),
    overrides: []const manifest.Dep,
) !void {
    for (overrides) |o| {
        var replaced = false;
        for (facts.items, 0..) |f, i| {
            if (!std.ascii.eqlIgnoreCase(f.name, o.name)) continue;
            if (o.constraint.len == 0 or std.mem.eql(u8, o.constraint, "false")) {
                _ = facts.orderedRemove(i);
            } else {
                facts.items[i] = .{
                    .name = f.name,
                    .pretty = o.constraint,
                    .normalized = try lock.normalizeVersion(allocator, o.constraint),
                    .overridden = true,
                };
            }
            replaced = true;
            break;
        }
        if (!replaced and o.constraint.len > 0 and !std.mem.eql(u8, o.constraint, "false")) {
            try add(allocator, facts, o.name, o.constraint, true);
        }
    }
}

fn add(
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(Fact),
    name: []const u8,
    pretty: []const u8,
    overridden: bool,
) !void {
    try facts.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .pretty = try allocator.dupe(u8, pretty),
        .normalized = lock.normalizeVersion(allocator, pretty) catch try allocator.dupe(u8, "0.0.0.0"),
        .overridden = overridden,
    });
}

/// A name the machine answers to without owning a library of that name.
fn addProvided(
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(Fact),
    name: []const u8,
    pretty: []const u8,
) !void {
    // A real library of the same name always wins; the probe already avoids
    // emitting both, and this is the second guard because the consequence of
    // getting it wrong — reporting a provided alias as installed — is a claim
    // about the machine that is not true.
    for (facts.items) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return;
    }
    try facts.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .pretty = try allocator.dupe(u8, pretty),
        .normalized = lock.normalizeVersion(allocator, pretty) catch try allocator.dupe(u8, "0.0.0.0"),
        .provided = true,
    });
}

fn boolOf(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

/// `8.5.10-dev` / `8.5.10RC1` → `8.5.10`.
///
/// Composer normalises `PHP_VERSION` directly and only strips on failure. The
/// result is the same for every version that parses, and stripping first avoids
/// depending on which shapes the normaliser happens to reject.
fn trimPhpVersion(raw: []const u8) []const u8 {
    var end: usize = 0;
    while (end < raw.len and (std.ascii.isDigit(raw[end]) or raw[end] == '.')) : (end += 1) {}
    if (end == 0) return raw;
    return std.mem.trimEnd(u8, raw[0..end], ".");
}

/// An extension version that is not a version at all becomes `0`.
///
/// Real values from a live runtime include `2.1.0-dev`, `1.9.1-mysql` and the
/// empty string. Composer keeps the leading `\d+\.\d+\.\d+` if there is one and
/// falls back to `0` otherwise, so that `ext-foo: *` still matches a loaded
/// extension whose version string is nonsense.
fn extensionVersion(raw: []const u8) []const u8 {
    if (raw.len == 0) return "0";
    var end: usize = 0;
    while (end < raw.len and (std.ascii.isDigit(raw[end]) or raw[end] == '.')) : (end += 1) {}
    const head = std.mem.trimEnd(u8, raw[0..end], ".");
    if (head.len == 0 or !std.ascii.isDigit(head[0])) return "0";
    return head;
}

fn probe(allocator: std.mem.Allocator, io: Io, env: *EnvMap, php_bin: []const u8) ![]const u8 {
    // The script arrives on STDIN, which is what `php` with no file argument
    // reads. `-r` cannot be used: the source is a real `.php` file so that
    // `php -l` can check it, and `-r` expects a body with no `<?php` opener.
    // Nothing is written to disk, so there is no temp file to clean up and no
    // path for a concurrent run to collide on.
    var child = std.process.spawn(io, .{
        .argv = &.{ php_bin, "-d", "error_reporting=0" },
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        // Discarded on purpose. A deprecation notice or an ini warning on
        // stderr is not our problem, and letting it through would put noise in
        // the middle of a command's output for a probe the user did not ask for.
        .stderr = .ignore,
    }) catch return Error.ProbeFailed;

    // Written and closed BEFORE stdout is read. `php` reads its whole script
    // before executing a line of it, and the source is well under a pipe
    // buffer, so this cannot block; closing is what tells the interpreter the
    // script has ended.
    if (child.stdin) |f| {
        var buf: [4096]u8 = undefined;
        var writer = f.writer(io, &buf);
        writer.interface.writeAll(probe_source) catch {};
        writer.interface.flush() catch {};
        f.close(io);
        child.stdin = null;
    }

    // Read to EOF BEFORE waiting. A child that fills the pipe buffer blocks on
    // write while the parent blocks in wait(), and neither ever moves — a
    // deadlock that only appears once the output grows past the buffer, which
    // for an extension list is a machine-dependent number of extensions.
    var out: std.ArrayList(u8) = .empty;
    if (child.stdout) |f| {
        var buf: [4096]u8 = undefined;
        var reader = f.reader(io, &buf);
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch break;
            out.appendSlice(allocator, chunk) catch break;
            reader.interface.toss(chunk.len);
        }
    }

    const term = child.wait(io) catch return Error.ProbeFailed;
    switch (term) {
        .exited => |c| if (c != 0) return Error.ProbeFailed,
        else => return Error.ProbeFailed,
    }
    if (out.items.len == 0) return Error.ProbeFailed;
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "php version strings are trimmed to their numeric head" {
    try testing.expectEqualStrings("8.5.10", trimPhpVersion("8.5.10"));
    try testing.expectEqualStrings("8.5.10", trimPhpVersion("8.5.10-dev"));
    try testing.expectEqualStrings("8.4.1", trimPhpVersion("8.4.1RC2"));
    try testing.expectEqualStrings("8.2", trimPhpVersion("8.2+ubuntu"));
}

test "an extension version that is not a version becomes 0" {
    // Real values seen from live runtimes. `0` rather than a rejection is
    // deliberate: the extension IS loaded, so `ext-foo: *` must still match.
    try testing.expectEqualStrings("0", extensionVersion(""));
    try testing.expectEqualStrings("0", extensionVersion("mysqlnd 8.5.10"));
    try testing.expectEqualStrings("2.1.0", extensionVersion("2.1.0-dev"));
    try testing.expectEqualStrings("1.9.1", extensionVersion("1.9.1-mysql"));
    try testing.expectEqualStrings("7", extensionVersion("7."));
}

test "a lib- requirement is unmodelled, never silently satisfied" {
    // The whole point of the verdict existing. If this ever returns .satisfied,
    // a requirement the author wrote down has become no requirement at all.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const p: Platform = .empty;
    const v = p.check(arena.allocator(), .{ .name = "lib-icu", .constraint = "^70" });
    try testing.expect(v == .unmodelled);
}

test "a missing extension is missing, and a present one is judged on its version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p: Platform = .{ .facts = &.{
        .{ .name = "php", .pretty = "8.5.10", .normalized = "8.5.10.0" },
        .{ .name = "ext-json", .pretty = "8.5.10", .normalized = "8.5.10.0" },
    } };

    try testing.expect(p.check(a, .{ .name = "ext-imagick", .constraint = "*" }) == .missing);
    try testing.expect(p.check(a, .{ .name = "ext-json", .constraint = "*" }) == .satisfied);
    try testing.expect(p.check(a, .{ .name = "php", .constraint = "^8.1" }) == .satisfied);

    // The case this whole file exists for: a package that cannot run here.
    const too_new = p.check(a, .{ .name = "php", .constraint = "^9.0" });
    try testing.expect(too_new == .conflict);
    try testing.expectEqualStrings("8.5.10", too_new.conflict.have);
}

test "config.platform overrides a real runtime, and false masks an extension" {
    // A developer on 8.5 resolving a lock for the 8.1 in production. The
    // override must WIN over the higher real value, or the point is lost.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var facts: std.ArrayList(Fact) = .empty;
    try add(al, &facts, "php", "8.5.10", false);
    try add(al, &facts, "ext-imagick", "3.7.0", false);

    try applyOverrides(al, &facts, &.{
        .{ .name = "php", .constraint = "8.1.2" },
        .{ .name = "ext-imagick", .constraint = "false" },
        .{ .name = "ext-newthing", .constraint = "1.0.0" },
    });

    const p: Platform = .{ .facts = facts.items };
    try testing.expectEqualStrings("8.1.2", p.versionOf("php").?.pretty);
    try testing.expect(p.versionOf("php").?.overridden);
    try testing.expect(p.versionOf("ext-imagick") == null);
    try testing.expectEqualStrings("1.0.0", p.versionOf("ext-newthing").?.pretty);

    try testing.expect(p.check(al, .{ .name = "php", .constraint = "^8.5" }) == .conflict);
    try testing.expect(p.check(al, .{ .name = "php", .constraint = "^8.1" }) == .satisfied);
}

test "an absent lib-* is missing when the machine was probed, and unknown when it was not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const probed: Platform = .{ .facts = &.{
        .{ .name = "lib-openssl", .pretty = "3.6.3", .normalized = "3.6.3.0" },
    } };

    // Detected, and judged like any other platform fact.
    try testing.expect(probed.check(a, .{ .name = "lib-openssl", .constraint = "^3.0" }) == .satisfied);
    try testing.expect(probed.check(a, .{ .name = "lib-openssl", .constraint = "^1.0" }) == .conflict);

    // Absent from a machine that WAS inspected means absent — which is what
    // Composer reports, and what `lib-*` used to be exempted from.
    try testing.expect(probed.check(a, .{ .name = "lib-nonexistent", .constraint = "*" }) == .missing);

    // Nothing answered: "this machine does not have it" would be a claim about
    // a machine nobody managed to inspect.
    const unprobed: Platform = .{ .facts = &.{}, .probed = false };
    try testing.expect(unprobed.check(a, .{ .name = "lib-openssl", .constraint = "^3.0" }) == .unmodelled);
    try testing.expect(unprobed.check(a, .{ .name = "ext-json", .constraint = "*" }) == .unmodelled);
}

test "a provided library satisfies a constraint without being listed as installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `lib-libxml` provides `lib-dom-libxml`; `composer check-platform-reqs`
    // prints exactly "provided by lib-libxml" for this, and `show --platform`
    // does not list it at all.
    var facts: std.ArrayList(Fact) = .empty;
    try add(a, &facts, "lib-libxml", "2.9.13", false);
    try addProvided(a, &facts, "lib-dom-libxml", "2.9.13");
    const plat: Platform = .{ .facts = facts.items };

    try testing.expect(plat.check(a, .{ .name = "lib-dom-libxml", .constraint = "^2.9" }) == .satisfied);
    try testing.expect(plat.versionOf("lib-dom-libxml").?.provided);
    try testing.expect(!plat.versionOf("lib-libxml").?.provided);

    // A real library of the same name always wins over the alias.
    var reversed: std.ArrayList(Fact) = .empty;
    try add(a, &reversed, "lib-zip", "1.11.4", false);
    try addProvided(a, &reversed, "lib-zip", "9.9.9");
    try testing.expectEqual(@as(usize, 1), reversed.items.len);
    try testing.expectEqualStrings("1.11.4", reversed.items[0].pretty);
}

test "the probe is a php file, not a -r fragment" {
    // `php -r` takes a body with no opener; this is passed on stdin because it
    // is a real file that `php -l` can check. Getting that pairing wrong is a
    // parse error at the top of every platform check.
    try testing.expect(std.mem.startsWith(u8, probe_source, "<?php"));
    try testing.expect(std.mem.indexOf(u8, probe_source, "'lib' => (object) $lib") != null);
    try testing.expect(std.mem.indexOf(u8, probe_source, "'libprov' => (object) $libprov") != null);
}

test "Ignore: the blanket form covers everything" {
    const all: Ignore = .{ .all = true };
    try std.testing.expect(all.covers("php"));
    try std.testing.expect(all.covers("ext-anything"));
    try std.testing.expect(all.any());
}

test "Ignore: a named requirement, and only that one" {
    const one: Ignore = .{ .names = &.{"ext-gd"} };
    try std.testing.expect(one.covers("ext-gd"));
    // The whole point of the per-name form: `php` is still enforced.
    try std.testing.expect(!one.covers("php"));
    try std.testing.expect(!one.covers("ext-gd-extra"));
}

test "Ignore: a trailing + waives the ceiling, not the requirement" {
    const upper: Ignore = .{ .names = &.{"php+"} };
    // `covers` must stay false — the requirement is still checked, against a
    // constraint with its upper bound lifted. Treating `+` as a full waiver
    // would let a project install on a PHP BELOW its own floor.
    try std.testing.expect(!upper.covers("php"));
    try std.testing.expect(upper.upperBoundOnly("php"));
    try std.testing.expect(!upper.upperBoundOnly("ext-gd"));
}

test "Ignore: a wildcard spans a family without spanning php" {
    const exts: Ignore = .{ .names = &.{"ext-*"} };
    try std.testing.expect(exts.covers("ext-gd"));
    try std.testing.expect(exts.covers("ext-intl"));
    try std.testing.expect(!exts.covers("php"));
}

test "checkWith: an ignored requirement reports ignored, not satisfied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plat: Platform = .{ .facts = &.{}, .probed = true };
    const dep: manifest.Dep = .{ .name = "ext-gd", .constraint = "*" };

    // Without the flag it is simply absent.
    try std.testing.expectEqual(Verdict.missing, plat.check(arena.allocator(), dep));
    // With it, the check was WAIVED — a different claim from "this machine has
    // it", and a report that conflated them would be lying about the machine.
    try std.testing.expectEqual(
        Verdict.ignored,
        plat.checkWith(arena.allocator(), dep, .{ .names = &.{"ext-gd"} }),
    );
}

test "checkWith: php+ passes a version above the ceiling and fails one below the floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plat: Platform = .{ .facts = &.{
        .{ .name = "php", .pretty = "8.5.10", .normalized = "8.5.10.0" },
    }, .probed = true };
    const upper: Ignore = .{ .names = &.{"php+"} };

    // 8.5 is above the declared ceiling: waived.
    try std.testing.expectEqual(
        Verdict.ignored,
        plat.checkWith(a, .{ .name = "php", .constraint = "^8.1 <8.3" }, upper),
    );
    // 8.5 is below a floor of 9: still a conflict, because lifting the ceiling
    // says nothing about the floor.
    const below = plat.checkWith(a, .{ .name = "php", .constraint = ">=9.0" }, upper);
    try std.testing.expect(below == .conflict);
}
