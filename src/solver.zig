//! Dependency resolution — choosing a version for every package.
//!
//! ## What this is, and what it is not
//!
//! A backtracking search: decide packages one at a time, always taking the
//! highest version that satisfies every constraint accumulated so far, and undo
//! the most recent decision when a requirement cannot be met. That is enough for
//! the shape real PHP dependency graphs have, and it produces the same answer as
//! Composer on them.
//!
//! It is NOT Composer's solver. Composer runs a CDCL SAT solver that learns from
//! each conflict, so it can prove a graph unsatisfiable and explain exactly why.
//! This one can only report the requirement it got stuck on, and on a
//! pathological graph it can exhaust its step budget rather than answer. Both
//! limits are reported honestly rather than disguised as a resolution failure —
//! `.exhausted` is a distinct outcome from `.unsatisfiable` precisely because
//! "I could not find one" and "there is not one" are different claims.
//!
//! ## Stability is a pool filter, not a constraint
//!
//! `^1.0.0` accepts `1.0.0-beta1` — verified against Composer's own Semver. What
//! keeps a beta out of an ordinary install is `minimum-stability`, applied when
//! candidates are collected. Conflating the two yields a resolver that cannot
//! install a pre-release even when the project explicitly asks for one.

const std = @import("std");
const constraint = @import("constraint.zig");
const packagist = @import("packagist.zig");

const Io = std.Io;

pub const Requirement = struct {
    name: []const u8,
    text: []const u8,
    parsed: constraint.Constraint,
    /// The package that asked for it — used to explain a conflict.
    origin: []const u8,
};

pub const Decision = struct {
    name: []const u8,
    candidate: packagist.Candidate,
};

pub const Outcome = union(enum) {
    solved: []const Decision,
    /// A requirement no available version can satisfy.
    unsatisfiable: Conflict,
    /// The search budget ran out. NOT the same claim as unsatisfiable.
    exhausted: usize,
    /// Metadata for a package could not be obtained at all.
    unavailable: []const u8,
};

pub const Conflict = struct {
    name: []const u8,
    /// Every constraint currently in force on that package.
    demands: []const Requirement,
    /// What the pool actually offered, newest first.
    ///
    /// Without this a conflict report says only "nothing satisfies ^1.0", which
    /// is the same message whether the package has no releases, only older ones,
    /// or a dev branch whose alias does not cover the range. Those have
    /// completely different fixes.
    available: []const []const u8 = &.{},
};

pub const Options = struct {
    /// Lowest stability a candidate may have to be considered.
    minimum_stability: constraint.Stability = .stable,
    /// Prefer a stable release even when a less stable one is newer.
    prefer_stable: bool = true,
    /// Consider dev branches. Costs a second metadata request per package.
    with_dev: bool = false,
    /// Upper bound on decisions attempted, so a pathological graph terminates.
    max_steps: usize = 20_000,
    metadata: packagist.Options = .{},
};

/// A platform requirement is satisfied by the environment, not by a package.
pub fn isPlatform(name: []const u8) bool {
    return std.mem.eql(u8, name, "php") or
        std.mem.eql(u8, name, "hhvm") or
        std.mem.startsWith(u8, name, "ext-") or
        std.mem.startsWith(u8, name, "lib-") or
        std.mem.startsWith(u8, name, "php-") or
        std.mem.startsWith(u8, name, "composer-");
}

/// Where candidate lists come from. Injected so the search can be tested
/// without a network — the tests below resolve real graph shapes offline.
pub const Pool = struct {
    context: *anyopaque,
    lookup: *const fn (context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const packagist.Candidate,

    pub fn candidates(self: Pool, allocator: std.mem.Allocator, name: []const u8) ![]const packagist.Candidate {
        return self.lookup(self.context, allocator, name);
    }
};

/// A Pool backed by the live Packagist metadata API.
pub const NetworkPool = struct {
    io: Io,
    cache_dir: []const u8,
    opts: packagist.Options,

    pub fn pool(self: *NetworkPool) Pool {
        return .{ .context = self, .lookup = fetchFor };
    }

    fn fetchFor(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const packagist.Candidate {
        const self: *NetworkPool = @ptrCast(@alignCast(context));
        return packagist.versionsOf(allocator, self.io, self.cache_dir, name, self.opts);
    }
};

/// Resolve `roots` to a concrete set of versions.
pub fn solve(
    allocator: std.mem.Allocator,
    pool: Pool,
    roots: []const Requirement,
    opts: Options,
) !Outcome {
    var state: State = .{
        .allocator = allocator,
        .pool = pool,
        .opts = opts,
        .demands = .empty,
        .stack = .empty,
        .steps = 0,
    };

    for (roots) |r| {
        if (isPlatform(r.name)) continue;
        try state.demands.append(allocator, r);
    }

    return state.search();
}

const State = struct {
    allocator: std.mem.Allocator,
    pool: Pool,
    opts: Options,
    /// Every constraint in force, from roots and from chosen packages.
    demands: std.ArrayList(Requirement),
    stack: std.ArrayList(Frame),
    steps: usize,

    /// One decision, with everything needed to undo it.
    const Frame = struct {
        name: []const u8,
        candidates: []const packagist.Candidate,
        /// Index of the candidate currently chosen.
        index: usize,
        /// `demands` length before this decision added any, for the undo.
        demand_mark: usize,
    };

    fn search(self: *State) !Outcome {
        while (true) {
            self.steps += 1;
            if (self.steps > self.opts.max_steps) return .{ .exhausted = self.steps };

            const picked = (try self.mostConstrained()) orelse return self.finish();
            const next = picked.name;

            if (picked.unavailable) return .{ .unavailable = next };

            if (picked.viable.len == 0) {
                // A package constrained only by the ROOT can never be fixed by
                // undoing a decision — nothing on the stack put those demands
                // there. Backtracking would walk the entire search space to
                // reach the same answer, which is how a naive solver turns a
                // one-line "this constraint cannot be met" into an exhausted
                // step budget.
                const fixable = self.anyDemandFromStack(next);
                if (fixable and try self.backtrack()) continue;

                return .{ .unsatisfiable = .{
                    .name = next,
                    .demands = try self.demandsOn(next),
                    .available = try self.offered(picked.all),
                } };
            }

            try self.choose(next, picked.viable, 0);
        }
    }

    const Pick = struct {
        name: []const u8,
        all: []const packagist.Candidate,
        viable: []const packagist.Candidate,
        unavailable: bool = false,
    };

    /// The undecided package with the FEWEST viable candidates.
    ///
    /// Minimum-remaining-values, the standard ordering heuristic for a
    /// backtracking search: deciding the most constrained package first finds
    /// the dead end immediately instead of after exploring every combination of
    /// the packages that were never in question. Taking demands in insertion
    /// order instead is what made this search exhaust its budget on a graph it
    /// can otherwise solve in a second — a package with one possible version
    /// was being decided last, after `aws/aws-sdk-php` had been tried at
    /// hundreds of them.
    fn mostConstrained(self: *State) !?Pick {
        var best: ?Pick = null;

        for (self.demands.items) |d| {
            if (isPlatform(d.name)) continue;
            if (self.decisionOf(d.name) != null) continue;
            if (best != null and std.mem.eql(u8, best.?.name, d.name)) continue;

            const all = self.pool.candidates(self.allocator, d.name) catch {
                return Pick{ .name = d.name, .all = &.{}, .viable = &.{}, .unavailable = true };
            };
            const viable = try self.viableFor(d.name, all);

            // Nothing beats zero: stop looking the moment a dead end appears.
            if (viable.len == 0) return Pick{ .name = d.name, .all = all, .viable = viable };

            if (best == null or viable.len < best.?.viable.len) {
                best = .{ .name = d.name, .all = all, .viable = viable };
            }
        }
        return best;
    }

    /// Is any demand on `name` owed to a decision still on the stack?
    fn anyDemandFromStack(self: *State, name: []const u8) bool {
        for (self.demands.items) |d| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            if (self.decisionOf(d.origin) != null) return true;
        }
        return false;
    }

    fn decisionOf(self: *State, name: []const u8) ?*Frame {
        for (self.stack.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// Candidates for `name` that satisfy every demand and pass the stability
    /// filter, best first.
    fn viableFor(self: *State, name: []const u8, all: []const packagist.Candidate) ![]const packagist.Candidate {
        var out: std.ArrayList(packagist.Candidate) = .empty;

        for (all) |c| {
            const v = constraint.parseVersion(c.version) orelse continue;
            if (@intFromEnum(v.stability) < @intFromEnum(self.opts.minimum_stability)) continue;

            var ok = true;
            for (self.demands.items) |d| {
                if (!std.mem.eql(u8, d.name, name)) continue;
                if (!satisfiedBy(c, v, d)) {
                    ok = false;
                    break;
                }
            }
            if (ok) try out.append(self.allocator, c);
        }

        const items = try out.toOwnedSlice(self.allocator);
        std.mem.sort(packagist.Candidate, items, self.opts, betterFirst);
        return items;
    }

    /// Take candidate `index` of `name` and fold in what it requires.
    fn choose(self: *State, name: []const u8, candidates: []const packagist.Candidate, index: usize) !void {
        const mark = self.demands.items.len;
        try self.stack.append(self.allocator, .{
            .name = name,
            .candidates = candidates,
            .index = index,
            .demand_mark = mark,
        });

        for (try candidates[index].requires(self.allocator)) |dep| {
            if (isPlatform(dep.name)) continue;
            const parsed = constraint.parse(self.allocator, dep.constraint) catch continue;
            try self.demands.append(self.allocator, .{
                .name = dep.name,
                .text = dep.constraint,
                .parsed = parsed,
                .origin = name,
            });
        }
    }

    /// Undo decisions until one has an untried candidate left.
    ///
    /// Returns false when the stack empties, which is the only honest way to
    /// say "there is no assignment", as opposed to "I gave up".
    fn backtrack(self: *State) !bool {
        while (self.stack.items.len > 0) {
            const frame = self.stack.items[self.stack.items.len - 1];
            self.demands.shrinkRetainingCapacity(frame.demand_mark);
            _ = self.stack.pop();

            if (frame.index + 1 < frame.candidates.len) {
                // Re-check the next candidate against the demands as they stand
                // now, which are fewer than when it was first considered.
                var i = frame.index + 1;
                while (i < frame.candidates.len) : (i += 1) {
                    const v = constraint.parseVersion(frame.candidates[i].version) orelse continue;
                    if (self.acceptable(frame.candidates[i], v)) {
                        try self.choose(frame.name, frame.candidates, i);
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn acceptable(self: *State, c: packagist.Candidate, v: constraint.Version) bool {
        for (self.demands.items) |d| {
            if (!std.mem.eql(u8, d.name, c.name)) continue;
            if (!satisfiedBy(c, v, d)) return false;
        }
        return true;
    }

    /// The versions the pool held, newest first, capped for readability.
    fn offered(self: *State, all: []const packagist.Candidate) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (all) |c| {
            if (out.items.len >= 12) break;
            try out.append(self.allocator, c.version);
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Every demand currently in force on one package, for a conflict report.
    fn demandsOn(self: *State, name: []const u8) ![]const Requirement {
        var out: std.ArrayList(Requirement) = .empty;
        for (self.demands.items) |d| {
            if (std.mem.eql(u8, d.name, name)) try out.append(self.allocator, d);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn finish(self: *State) !Outcome {
        var out: std.ArrayList(Decision) = .empty;
        for (self.stack.items) |f| {
            try out.append(self.allocator, .{ .name = f.name, .candidate = f.candidates[f.index] });
        }
        const items = try out.toOwnedSlice(self.allocator);
        std.mem.sort(Decision, items, {}, decisionByName);
        return .{ .solved = items };
    }
};

/// Does this candidate satisfy one demand — directly, or through its branch
/// alias?
fn satisfiedBy(c: packagist.Candidate, v: constraint.Version, d: Requirement) bool {
    if (d.parsed.matches(v)) return true;

    // A dev branch matches a numeric range only via the alias the package
    // itself declares. Falling back to the alias unconditionally would let any
    // branch satisfy anything; it is gated on the package having said so.
    if (c.branchAlias()) |alias| {
        if (constraint.parseVersion(alias)) |av| return d.parsed.matches(av);
    }
    return false;
}

fn decisionByName(_: void, a: Decision, b: Decision) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Ordering of candidates: the one to try first sorts first.
///
/// Newest wins, except that `prefer_stable` puts every stable release ahead of
/// every unstable one regardless of number — which is what stops a resolution
/// from silently landing on an alpha that happens to be newer.
fn betterFirst(opts: Options, a: packagist.Candidate, b: packagist.Candidate) bool {
    const va = constraint.parseVersion(a.version) orelse return false;
    const vb = constraint.parseVersion(b.version) orelse return true;

    if (opts.prefer_stable) {
        const sa = va.stability == .stable or va.stability == .patch;
        const sb = vb.stability == .stable or vb.stability == .patch;
        if (sa != sb) return sa;
    }
    return va.order(vb) == .gt;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A pool built from a literal table, so the search is testable with no network.
const FakePool = struct {
    entries: []const Entry,

    const Entry = struct {
        name: []const u8,
        /// `"1.2.0"` or `"1.2.0 requires other:^1.0"`.
        versions: []const []const u8,
    };

    fn pool(self: *FakePool) Pool {
        return .{ .context = self, .lookup = lookup };
    }

    fn lookup(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const packagist.Candidate {
        const self: *FakePool = @ptrCast(@alignCast(context));
        for (self.entries) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;

            var out: std.ArrayList(packagist.Candidate) = .empty;
            for (e.versions) |spec| {
                var it = std.mem.splitSequence(u8, spec, " requires ");
                const version = it.next().?;

                var obj: std.json.ObjectMap = .empty;
                try obj.put(allocator, "name", .{ .string = name });
                try obj.put(allocator, "version", .{ .string = version });

                if (it.next()) |reqs| {
                    var req_obj: std.json.ObjectMap = .empty;
                    var parts = std.mem.splitScalar(u8, reqs, ',');
                    while (parts.next()) |pair| {
                        const at = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
                        try req_obj.put(allocator, std.mem.trim(u8, pair[0..at], " "), .{ .string = pair[at + 1 ..] });
                    }
                    try obj.put(allocator, "require", .{ .object = req_obj });
                }

                try out.append(allocator, .{
                    .name = name,
                    .version = version,
                    .version_normalized = version,
                    .raw = .{ .object = obj },
                });
            }
            return out.toOwnedSlice(allocator);
        }
        return error.NotFound;
    }
};

fn req(a: std.mem.Allocator, name: []const u8, text: []const u8) !Requirement {
    return .{ .name = name, .text = text, .parsed = try constraint.parse(a, text), .origin = "__root__" };
}

fn versionOf(outcome: Outcome, name: []const u8) ?[]const u8 {
    switch (outcome) {
        .solved => |ds| {
            for (ds) |d| if (std.mem.eql(u8, d.name, name)) return d.candidate.version;
            return null;
        },
        else => return null,
    }
}

test "picks the highest version satisfying the root constraint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/lib", .versions = &.{ "2.0.0", "1.5.0", "1.2.0" } },
    } };
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/lib", "^1.0")}, .{});

    try testing.expectEqualStrings("1.5.0", versionOf(outcome, "acme/lib").?);
}

test "a transitive requirement is resolved too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/app", .versions = &.{"1.0.0 requires acme/core:^2.0"} },
        .{ .name = "acme/core", .versions = &.{ "2.3.0", "2.0.0", "1.0.0" } },
    } };
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/app", "^1.0")}, .{});

    try testing.expectEqualStrings("1.0.0", versionOf(outcome, "acme/app").?);
    try testing.expectEqualStrings("2.3.0", versionOf(outcome, "acme/core").?);
}

test "backtracks when the newest choice cannot satisfy a later requirement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // app 2.0 needs core ^3.0, which does not exist; the solver must fall back
    // to app 1.0. A search that only ever took the newest would fail here.
    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/app", .versions = &.{ "2.0.0 requires acme/core:^3.0", "1.0.0 requires acme/core:^2.0" } },
        .{ .name = "acme/core", .versions = &.{ "2.1.0", "2.0.0" } },
    } };
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/app", "*")}, .{});

    try testing.expectEqualStrings("1.0.0", versionOf(outcome, "acme/app").?);
    try testing.expectEqualStrings("2.1.0", versionOf(outcome, "acme/core").?);
}

test "two packages demanding the same dependency agree on one version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/one", .versions = &.{"1.0.0 requires acme/shared:^1.2"} },
        .{ .name = "acme/two", .versions = &.{"1.0.0 requires acme/shared:<1.5"} },
        .{ .name = "acme/shared", .versions = &.{ "1.9.0", "1.4.0", "1.1.0" } },
    } };
    const outcome = try solve(a, fake.pool(), &.{
        try req(a, "acme/one", "*"),
        try req(a, "acme/two", "*"),
    }, .{});

    // 1.9.0 satisfies ^1.2 but not <1.5; 1.1.0 satisfies <1.5 but not ^1.2.
    try testing.expectEqualStrings("1.4.0", versionOf(outcome, "acme/shared").?);
}

test "an impossible requirement is reported as unsatisfiable, with the demands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/lib", .versions = &.{ "1.0.0", "2.0.0" } },
    } };
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/lib", "^9.0")}, .{});

    switch (outcome) {
        .unsatisfiable => |c| {
            try testing.expectEqualStrings("acme/lib", c.name);
            try testing.expectEqual(@as(usize, 1), c.demands.len);
            try testing.expectEqualStrings("^9.0", c.demands[0].text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "minimum-stability keeps pre-releases out of the pool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/lib", .versions = &.{ "2.0.0-beta1", "1.9.0" } },
    } };

    // The constraint ACCEPTS the beta — stability is what excludes it.
    const stable = try solve(a, fake.pool(), &.{try req(a, "acme/lib", "*")}, .{});
    try testing.expectEqualStrings("1.9.0", versionOf(stable, "acme/lib").?);

    const loose = try solve(a, fake.pool(), &.{try req(a, "acme/lib", "*")}, .{
        .minimum_stability = .dev,
        .prefer_stable = false,
    });
    try testing.expectEqualStrings("2.0.0-beta1", versionOf(loose, "acme/lib").?);
}

test "prefer-stable takes a stable release over a newer unstable one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/lib", .versions = &.{ "2.0.0-beta1", "1.9.0" } },
    } };
    // Both are in the pool, but stable still wins on ordering.
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/lib", "*")}, .{
        .minimum_stability = .dev,
        .prefer_stable = true,
    });
    try testing.expectEqualStrings("1.9.0", versionOf(outcome, "acme/lib").?);
}

test "a package with no metadata is reported as unavailable, not unsatisfiable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{} };
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/missing", "*")}, .{});

    switch (outcome) {
        .unavailable => |name| try testing.expectEqualStrings("acme/missing", name),
        else => return error.TestUnexpectedResult,
    }
}

test "a dev branch satisfies a numeric range through its declared alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exactly the kernel's own case: alfacode-team/http is on dev-master and
    // required at ^1.0, which only works because the package declares
    // {"dev-master": "1.0.x-dev"}.
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "name", .{ .string = "acme/lib" });
    try obj.put(a, "version", .{ .string = "dev-master" });
    var alias_obj: std.json.ObjectMap = .empty;
    try alias_obj.put(a, "dev-master", .{ .string = "1.0.x-dev" });
    var extra_obj: std.json.ObjectMap = .empty;
    try extra_obj.put(a, "branch-alias", .{ .object = alias_obj });
    try obj.put(a, "extra", .{ .object = extra_obj });

    const c = packagist.Candidate{
        .name = "acme/lib",
        .version = "dev-master",
        .version_normalized = "dev-master",
        .raw = .{ .object = obj },
    };
    try testing.expectEqualStrings("1.0.x-dev", c.branchAlias().?);

    const demand = try req(a, "acme/lib", "^1.0");
    const v = constraint.parseVersion("dev-master").?;
    try testing.expect(satisfiedBy(c, v, demand));

    // And an alias that does not cover the range still fails.
    const far = try req(a, "acme/lib", "^9.0");
    try testing.expect(!satisfiedBy(c, v, far));
}

test "a branch with no declared alias satisfies no numeric range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "name", .{ .string = "acme/lib" });
    try obj.put(a, "version", .{ .string = "dev-master" });

    const c = packagist.Candidate{
        .name = "acme/lib",
        .version = "dev-master",
        .version_normalized = "dev-master",
        .raw = .{ .object = obj },
    };
    try testing.expect(c.branchAlias() == null);
    try testing.expect(!satisfiedBy(c, constraint.parseVersion("dev-master").?, try req(a, "acme/lib", "^1.0")));
}

test "platform requirements are not resolved as packages" {
    try testing.expect(isPlatform("php"));
    try testing.expect(isPlatform("ext-json"));
    try testing.expect(isPlatform("composer-runtime-api"));
    try testing.expect(!isPlatform("psr/log"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: FakePool = .{ .entries = &.{
        .{ .name = "acme/lib", .versions = &.{"1.0.0 requires php:>=8.4,ext-json:*"} },
    } };
    // Would be `.unavailable` for "php" if platform packages were looked up.
    const outcome = try solve(a, fake.pool(), &.{try req(a, "acme/lib", "*")}, .{});
    try testing.expectEqualStrings("1.0.0", versionOf(outcome, "acme/lib").?);
}
