//! Composer's version constraint algebra.
//!
//! The foundation every resolution step stands on: "does version V satisfy
//! constraint C". Ported from `composer/semver`'s `VersionParser`, because the
//! rules are not the ones a reasonable person would guess and the differences
//! are silent —
//!
//!   * `~1.2` means `>=1.2 <2.0`, NOT `>=1.2 <1.3`. Tilde increments the
//!     component one place LEFT of the last one written. (`~1.2.3` does mean
//!     `>=1.2.3 <1.3.0`, which is where the wrong intuition comes from.)
//!   * every bound carries an implicit `-dev` suffix, so `^1.2.3` is
//!     `>=1.2.3.0-dev <2.0.0.0-dev` — that is what lets a dev build of a
//!     version satisfy a constraint on it.
//!   * versions normalise to FOUR components, so `1.2.3` is `1.2.3.0` and
//!     comparison is on the four, not three.
//!
//! Getting any of these subtly wrong yields a resolver that picks a plausible
//! but different version set from Composer's, which is the worst possible
//! outcome: it installs, it runs, and it disagrees with the lock everyone else
//! has.

const std = @import("std");

/// Release stability, ordered as PHP's `version_compare` orders the suffixes.
///
/// `patch` above `stable` is not a typo: `1.0.0-pl1` is a patched release and
/// sorts ABOVE `1.0.0`, exactly as `version_compare` says.
/// The value Composer pads a branch alias with (`1.2.x-dev` →
/// `1.2.9999999.9999999-dev`), so the alias sorts above every tagged release on
/// that branch.
pub const branch_alias_pad: u32 = 9999999;

pub const Stability = enum(u8) {
    dev = 0,
    alpha = 1,
    beta = 2,
    rc = 3,
    stable = 4,
    patch = 5,
};

/// Parse a `minimum-stability` value. Unknown text means `stable`, which is
/// the safe direction: a typo must not silently widen the pool to dev builds.
pub fn stabilityFromName(name: []const u8) Stability {
    const table = [_]struct { []const u8, Stability }{
        .{ "dev", .dev },
        .{ "alpha", .alpha },
        .{ "beta", .beta },
        .{ "rc", .rc },
        .{ "RC", .rc },
        .{ "stable", .stable },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
    }
    return .stable;
}

pub const Version = struct {
    parts: [4]u32 = .{ 0, 0, 0, 0 },
    stability: Stability = .stable,
    /// The number after the suffix: `beta2` → 2.
    stability_num: u32 = 0,
    /// A non-numeric branch (`dev-master`); compares equal only to itself.
    branch: []const u8 = "",

    pub fn isBranch(self: Version) bool {
        return self.branch.len > 0;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        // A named branch is not on the numeric line at all. Composer treats two
        // different branches as incomparable; ordering them arbitrarily but
        // consistently keeps sorts total without implying one is "newer".
        if (a.isBranch() or b.isBranch()) {
            if (a.isBranch() and b.isBranch()) return std.mem.order(u8, a.branch, b.branch);
            return if (a.isBranch()) .lt else .gt;
        }

        for (a.parts, b.parts) |x, y| {
            if (x != y) return if (x < y) .lt else .gt;
        }
        const sa = @intFromEnum(a.stability);
        const sb = @intFromEnum(b.stability);
        if (sa != sb) return if (sa < sb) .lt else .gt;
        if (a.stability_num != b.stability_num) {
            return if (a.stability_num < b.stability_num) .lt else .gt;
        }
        return .eq;
    }
};

/// Parse a version, normalised or not: `1.2.3`, `v1.2`, `1.2.3.0`,
/// `1.0.0-beta2`, `2.0.x-dev`, `dev-master`.
pub fn parseVersion(raw: []const u8) ?Version {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;

    if (std.mem.startsWith(u8, s, "dev-")) {
        return .{ .branch = s[4..], .stability = .dev };
    }
    // The `<branch>-dev` spelling of the same thing, when the branch is not
    // numeric (`master-dev`). A numeric one (`2.0.x-dev`) is a real range.
    if (s[0] == 'v' or s[0] == 'V') s = s[1..];
    if (s.len == 0) return null;

    // Build metadata never affects precedence.
    if (std.mem.indexOfScalar(u8, s, '+')) |at| s = s[0..at];

    var numeric = s;
    var suffix: []const u8 = "";
    if (std.mem.indexOfAny(u8, s, "-")) |at| {
        numeric = s[0..at];
        suffix = s[at + 1 ..];
    }

    var out: Version = .{};
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, numeric, '.');
    while (it.next()) |part| {
        if (count >= 4) break;
        // `13.2.x-dev` is a BRANCH ALIAS, and Composer normalises it to
        // `13.2.9999999.9999999-dev` — padded to the maximum so it outranks
        // every real release on that branch. Zeroing instead makes
        // `13.2.x-dev` fail `^13.2.6`, which is how a lock referring to a
        // branch alias stops resolving.
        if (part.len == 1 and (part[0] == 'x' or part[0] == 'X' or part[0] == '*')) {
            while (count < 4) : (count += 1) out.parts[count] = branch_alias_pad;
            break;
        }
        if (part.len == 0) return null;
        out.parts[count] = std.fmt.parseInt(u32, part, 10) catch return null;
        count += 1;
    }
    if (count == 0) return null;

    if (suffix.len > 0) {
        const parsed = parseStability(suffix) orelse return .{
            .parts = out.parts,
            .branch = "",
            .stability = .stable,
        };
        out.stability = parsed.stability;
        out.stability_num = parsed.number;
    }
    return out;
}

const ParsedStability = struct { stability: Stability, number: u32 };

fn parseStability(raw: []const u8) ?ParsedStability {
    var s = raw;
    // Composer writes `-beta.2` and `-beta2`; both mean the same thing.
    var stability: Stability = .stable;
    var matched: usize = 0;

    const table = [_]struct { name: []const u8, s: Stability }{
        .{ .name = "dev", .s = .dev },
        .{ .name = "alpha", .s = .alpha },
        .{ .name = "a", .s = .alpha },
        .{ .name = "beta", .s = .beta },
        .{ .name = "b", .s = .beta },
        .{ .name = "rc", .s = .rc },
        .{ .name = "patch", .s = .patch },
        .{ .name = "pl", .s = .patch },
        .{ .name = "p", .s = .patch },
    };
    // Longest name first, so `alpha` is not read as `a` with a trailing `lpha`.
    var best: usize = 0;
    for (table) |entry| {
        if (s.len >= entry.name.len and std.ascii.eqlIgnoreCase(s[0..entry.name.len], entry.name)) {
            if (entry.name.len > best) {
                best = entry.name.len;
                stability = entry.s;
            }
        }
    }
    if (best == 0) return null;
    matched = best;

    var rest = s[matched..];
    rest = std.mem.trimStart(u8, rest, ".-");
    const number = std.fmt.parseInt(u32, rest, 10) catch 0;
    return .{ .stability = stability, .number = number };
}

// ── constraints ───────────────────────────────────────────────────────────────

pub const Op = enum { eq, ne, lt, lte, gt, gte };

/// One comparison. `any` is the unconstrained `*`.
pub const Term = struct {
    op: Op,
    version: Version,
    any: bool = false,

    pub fn matches(self: Term, v: Version) bool {
        if (self.any) return true;

        // A branch satisfies only an exact match on itself. Comparing
        // `dev-master` against `>=1.0` numerically would be meaningless, and
        // answering "true" there is how a resolver picks a branch nobody asked
        // for.
        if (v.isBranch() or self.version.isBranch()) {
            if (self.op != .eq and self.op != .ne) return false;
            const same = v.isBranch() and self.version.isBranch() and
                std.mem.eql(u8, v.branch, self.version.branch);
            return if (self.op == .eq) same else !same;
        }

        const o = v.order(self.version);
        return switch (self.op) {
            .eq => o == .eq,
            .ne => o != .eq,
            .lt => o == .lt,
            .lte => o != .gt,
            .gt => o == .gt,
            .gte => o != .lt,
        };
    }
};

/// A disjunction of conjunctions: `(a AND b) OR (c AND d)`.
///
/// Every Composer constraint reduces to this shape, which is why no general
/// boolean solver is needed to evaluate one.
pub const Constraint = struct {
    groups: []const []const Term,

    pub fn matches(self: Constraint, v: Version) bool {
        if (self.groups.len == 0) return true;
        for (self.groups) |group| {
            var all = true;
            for (group) |term| {
                if (!term.matches(v)) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
        return false;
    }

    /// Does `raw` (a version string) satisfy this?
    pub fn accepts(self: Constraint, raw: []const u8) bool {
        const v = parseVersion(raw) orelse return false;
        return self.matches(v);
    }
};

pub const Error = error{BadConstraint};

/// Parse a constraint expression.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Constraint {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .{ .groups = &.{} };

    var groups: std.ArrayList([]const Term) = .empty;

    // `||` (and the legacy single `|`) separate alternatives.
    var alt = std.mem.splitSequence(u8, trimmed, "||");
    while (alt.next()) |chunk| {
        var single = std.mem.splitScalar(u8, chunk, '|');
        while (single.next()) |piece| {
            const group = try parseGroup(allocator, piece);
            if (group.len > 0) try groups.append(allocator, group);
        }
    }

    if (groups.items.len == 0) return .{ .groups = &.{} };
    return .{ .groups = try groups.toOwnedSlice(allocator) };
}

/// One conjunction: comma- or space-separated terms, or a hyphen range.
fn parseGroup(allocator: std.mem.Allocator, text: []const u8) ![]const Term {
    const chunk = std.mem.trim(u8, text, " \t\r\n");
    if (chunk.len == 0) return &.{};

    var terms: std.ArrayList(Term) = .empty;

    // A hyphen range (`1.0 - 2.0`) must be spotted before tokenising, since its
    // separator is a space-delimited '-' that would otherwise split badly.
    if (std.mem.indexOf(u8, chunk, " - ")) |at| {
        const low = std.mem.trim(u8, chunk[0..at], " \t");
        const high = std.mem.trim(u8, chunk[at + 3 ..], " \t");
        try terms.append(allocator, .{ .op = .gte, .version = parseVersion(low) orelse return Error.BadConstraint });
        // An upper bound given to less precision is inclusive of that whole
        // range: `- 2.0` means "up to the end of 2.0", not "up to 2.0.0".
        try terms.append(allocator, .{ .op = .lt, .version = try hyphenUpperBound(high) });
        return terms.toOwnedSlice(allocator);
    }

    var it = std.mem.tokenizeAny(u8, chunk, ", \t");
    while (it.next()) |token| {
        try appendTerms(allocator, token, &terms);
    }
    return terms.toOwnedSlice(allocator);
}

fn hyphenUpperBound(raw: []const u8) !Version {
    const spec = try componentsOf(raw);
    // Fewer than three components → bump the last one given and exclude it.
    if (spec.count >= 3) {
        var v = spec.version;
        v.parts[3] += 1;
        return v;
    }
    var v = spec.version;
    const idx = if (spec.count == 0) 0 else spec.count - 1;
    v.parts[idx] += 1;
    var i = idx + 1;
    while (i < 4) : (i += 1) v.parts[i] = 0;
    v.stability = .dev;
    return v;
}

const Components = struct { version: Version, count: usize, has_stability: bool };

/// Split a version literal into its numeric components, remembering HOW MANY
/// were written — the thing every range operator keys off.
fn componentsOf(raw: []const u8) !Components {
    var s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return Error.BadConstraint;
    if (s[0] == 'v' or s[0] == 'V') s = s[1..];

    var numeric = s;
    var has_stability = false;
    if (std.mem.indexOfScalar(u8, s, '-')) |at| {
        numeric = s[0..at];
        has_stability = true;
    }
    if (std.mem.indexOfScalar(u8, s, '@')) |at| {
        numeric = numeric[0..@min(numeric.len, at)];
        has_stability = true;
    }

    var out: Components = .{ .version = .{}, .count = 0, .has_stability = has_stability };
    var it = std.mem.splitScalar(u8, numeric, '.');
    while (it.next()) |part| {
        if (out.count >= 4) break;
        if (part.len == 0) return Error.BadConstraint;
        if (part.len == 1 and (part[0] == 'x' or part[0] == 'X' or part[0] == '*')) break;
        out.version.parts[out.count] = std.fmt.parseInt(u32, part, 10) catch return Error.BadConstraint;
        out.count += 1;
    }
    if (out.count == 0) return Error.BadConstraint;

    const full = parseVersion(s) orelse return Error.BadConstraint;
    out.version.stability = full.stability;
    out.version.stability_num = full.stability_num;
    return out;
}

/// Expand one token into the terms it stands for.
fn appendTerms(allocator: std.mem.Allocator, raw_token: []const u8, out: *std.ArrayList(Term)) !void {
    var token = std.mem.trim(u8, raw_token, " \t");
    if (token.len == 0) return;

    if (std.mem.eql(u8, token, "*") or std.ascii.eqlIgnoreCase(token, "any")) {
        try out.append(allocator, .{ .op = .eq, .version = .{}, .any = true });
        return;
    }

    // A trailing stability flag (`@dev`, `@stable`) selects which stabilities
    // are acceptable rather than which versions; the version half still applies.
    if (std.mem.indexOfScalar(u8, token, '@')) |at| {
        token = std.mem.trim(u8, token[0..at], " \t");
        if (token.len == 0) {
            try out.append(allocator, .{ .op = .eq, .version = .{}, .any = true });
            return;
        }
    }

    if (std.mem.startsWith(u8, token, "dev-")) {
        try out.append(allocator, .{ .op = .eq, .version = parseVersion(token) orelse return Error.BadConstraint });
        return;
    }

    inline for (.{
        .{ ">=", Op.gte },
        .{ "<=", Op.lte },
        .{ "!=", Op.ne },
        .{ "<>", Op.ne },
        .{ ">", Op.gt },
        .{ "<", Op.lt },
        .{ "==", Op.eq },
        .{ "=", Op.eq },
    }) |pair| {
        if (std.mem.startsWith(u8, token, pair[0])) {
            const v = parseVersion(token[pair[0].len..]) orelse return Error.BadConstraint;
            try out.append(allocator, .{ .op = pair[1], .version = v });
            return;
        }
    }

    if (token[0] == '^') return caret(allocator, token[1..], out);
    if (token[0] == '~') return tilde(allocator, token[1..], out);

    // A wildcard is only an X-RANGE when nothing follows it. `1.2.*` is the
    // range `>=1.2 <1.3`, but `13.2.x-dev` is a BRANCH ALIAS — one specific
    // version, `13.2.9999999.9999999-dev` — and matches only itself.
    // Composer's X-range pattern is anchored at the end for exactly this
    // reason. Treating the second as a range makes `13.2.6` satisfy a
    // requirement that asked for the 13.2 development branch, which is how a
    // resolver quietly swaps a branch for a tag.
    const has_suffix = std.mem.indexOfScalar(u8, token, '-') != null;
    if (!has_suffix and std.mem.indexOfAny(u8, token, "xX*") != null) {
        return wildcard(allocator, token, out);
    }

    // A bare version is an EXACT pin at every precision. `1.0` normalises to
    // `1.0.0.0` and matches only that — it is not shorthand for the 1.0 series,
    // however much it reads like one. Composer answers false for `3.0.2` against
    // `3.0`, and a resolver that answers true silently accepts a patch release
    // where an exact version was pinned.
    _ = try componentsOf(token); // rejects malformed tokens
    try out.append(allocator, .{ .op = .eq, .version = parseVersion(token) orelse return Error.BadConstraint });
}

/// `^1.2.3` → `>=1.2.3.0-dev <2.0.0.0-dev`; `^0.2.3` → `<0.3.0`; `^0.0.3` → `<0.0.4`.
///
/// The bound moves at the left-most NON-ZERO component, which is what "does not
/// change the left-most non-zero digit" means in practice.
fn caret(allocator: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Term)) !void {
    const spec = try componentsOf(body);

    var position: usize = 0;
    if (spec.version.parts[0] != 0 or spec.count < 2) {
        position = 0;
    } else if (spec.version.parts[1] != 0 or spec.count < 3) {
        position = 1;
    } else {
        position = 2;
    }

    try out.append(allocator, .{ .op = .gte, .version = lowerBound(spec) });
    try out.append(allocator, .{ .op = .lt, .version = bump(spec.version, position) });
}

/// `~1.2.3` → `>=1.2.3.0-dev <1.3.0.0-dev`; `~1.2` → `<2.0.0.0-dev`.
///
/// The upper bound moves one position LEFT of the last component written —
/// which is why `~1.2` and `~1.2.3` behave differently, and why this is the
/// operator most often mis-remembered.
fn tilde(allocator: std.mem.Allocator, body: []const u8, out: *std.ArrayList(Term)) !void {
    const spec = try componentsOf(body);
    const position = if (spec.count <= 1) 0 else spec.count - 2;

    try out.append(allocator, .{ .op = .gte, .version = lowerBound(spec) });
    try out.append(allocator, .{ .op = .lt, .version = bump(spec.version, position) });
}

fn wildcard(allocator: std.mem.Allocator, token: []const u8, out: *std.ArrayList(Term)) !void {
    return wildcardFrom(allocator, try componentsOf(token), out);
}

/// `1.2.*` → `>=1.2.0.0-dev <1.3.0.0-dev`.
fn wildcardFrom(allocator: std.mem.Allocator, spec: Components, out: *std.ArrayList(Term)) !void {
    var low = spec.version;
    var i = spec.count;
    while (i < 4) : (i += 1) low.parts[i] = 0;
    low.stability = .dev;
    low.stability_num = 0;

    try out.append(allocator, .{ .op = .gte, .version = low });
    try out.append(allocator, .{ .op = .lt, .version = bump(spec.version, spec.count - 1) });
}

/// The `>=` bound: the written version, padded, carrying the implicit `-dev`
/// that lets a dev build of exactly this version satisfy the constraint.
fn lowerBound(spec: Components) Version {
    var v = spec.version;
    var i = spec.count;
    while (i < 4) : (i += 1) v.parts[i] = 0;
    if (!spec.has_stability) {
        v.stability = .dev;
        v.stability_num = 0;
    }
    return v;
}

/// Increment `position`, zero everything after it, and mark it `-dev` so the
/// bound excludes every pre-release of the version it names.
fn bump(version: Version, position: usize) Version {
    var v = version;
    v.parts[position] += 1;
    var i = position + 1;
    while (i < 4) : (i += 1) v.parts[i] = 0;
    v.stability = .dev;
    v.stability_num = 0;
    v.branch = "";
    return v;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn accepts(a: std.mem.Allocator, constraint: []const u8, version: []const u8) !bool {
    const c = try parse(a, constraint);
    return c.accepts(version);
}

test "caret allows the series and stops at the next breaking component" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try accepts(a, "^1.2.3", "1.2.3"));
    try testing.expect(try accepts(a, "^1.2.3", "1.9.9"));
    try testing.expect(!try accepts(a, "^1.2.3", "1.2.2"));
    try testing.expect(!try accepts(a, "^1.2.3", "2.0.0"));

    // Below 1.0 the minor is the breaking component.
    try testing.expect(try accepts(a, "^0.2.3", "0.2.9"));
    try testing.expect(!try accepts(a, "^0.2.3", "0.3.0"));
    // And below 0.1 it is the patch.
    try testing.expect(try accepts(a, "^0.0.3", "0.0.3"));
    try testing.expect(!try accepts(a, "^0.0.3", "0.0.4"));
}

test "tilde bumps one component left of the last one written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The case everyone remembers.
    try testing.expect(try accepts(a, "~1.2.3", "1.2.9"));
    try testing.expect(!try accepts(a, "~1.2.3", "1.3.0"));

    // The case almost everyone gets wrong: ~1.2 is >=1.2 <2.0, NOT <1.3.
    try testing.expect(try accepts(a, "~1.2", "1.9.0"));
    try testing.expect(!try accepts(a, "~1.2", "2.0.0"));
}

test "alternation accepts a version matching any branch of it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A real constraint out of the kernel's lock.
    const c = "^9.6.35 || ^10.5.64 || ^11.5.56 || ^12.5.31 || ^13.0.6";
    try testing.expect(try accepts(a, c, "13.2.6"));
    try testing.expect(try accepts(a, c, "10.5.64"));
    try testing.expect(!try accepts(a, c, "9.6.34"));
    try testing.expect(!try accepts(a, c, "14.0.0"));

    // The legacy single-pipe spelling means the same thing.
    try testing.expect(try accepts(a, "^1.1|^2|^3", "2.5.0"));
}

test "comparators and conjunctions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try accepts(a, ">=1.0 <2.0", "1.5.0"));
    try testing.expect(!try accepts(a, ">=1.0 <2.0", "2.0.0"));
    try testing.expect(try accepts(a, ">=1.0,<2.0", "1.5.0"));
    try testing.expect(try accepts(a, "!=1.5.0", "1.6.0"));
    try testing.expect(!try accepts(a, "!=1.5.0", "1.5.0"));
}

test "wildcards and partial versions denote a series" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try accepts(a, "1.2.*", "1.2.7"));
    try testing.expect(!try accepts(a, "1.2.*", "1.3.0"));
    try testing.expect(try accepts(a, "1.*", "1.9.9"));
    try testing.expect(!try accepts(a, "1.*", "2.0.0"));
    try testing.expect(try accepts(a, "*", "42.0.0"));

    // A BARE partial version is not a wildcard: it is an exact pin on the
    // normalised four-component form, so 1.2 means 1.2.0.0 and nothing else.
    try testing.expect(!try accepts(a, "1.2", "1.2.5"));
    try testing.expect(try accepts(a, "1.2", "1.2.0"));
}

test "stability ordering follows version_compare" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dev = parseVersion("1.0.0-dev").?;
    const alpha = parseVersion("1.0.0-alpha1").?;
    const beta = parseVersion("1.0.0-beta2").?;
    const rc = parseVersion("1.0.0-RC1").?;
    const stable = parseVersion("1.0.0").?;

    try testing.expectEqual(std.math.Order.lt, dev.order(alpha));
    try testing.expectEqual(std.math.Order.lt, alpha.order(beta));
    try testing.expectEqual(std.math.Order.lt, beta.order(rc));
    try testing.expectEqual(std.math.Order.lt, rc.order(stable));

    // A pre-release DOES satisfy a caret on the release it precedes, because
    // every caret bound carries an implicit `-dev`. Verified against
    // Composer\Semver\Semver::satisfies, which answers true here too.
    //
    // What keeps a beta out of a normal install is therefore NOT the constraint
    // — it is `minimum-stability`, applied when the candidate pool is built.
    // Conflating the two produces a resolver that rejects pre-releases even when
    // a project has explicitly asked for them.
    try testing.expect(try accepts(a, "^1.0.0", "1.0.0-beta1"));
    try testing.expect(try accepts(a, "^1.0.0", "1.0.1"));
}

test "an x-dev constraint is a branch alias, not a range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Verified against Composer\Semver\Semver::satisfies, which answers false
    // for the tagged release and true only for the alias itself.
    try testing.expect(!try accepts(a, "13.2.x-dev", "13.2.6"));
    try testing.expect(try accepts(a, "13.2.x-dev", "13.2.x-dev"));
    try testing.expect(!try accepts(a, "2.0.x-dev", "2.0"));
    try testing.expect(!try accepts(a, "2.0.x-dev", "dev-master"));

    // The plain wildcard, with nothing after it, is still a range.
    try testing.expect(try accepts(a, "13.2.*", "13.2.6"));
}

test "a branch alias pads to the maximum, so it satisfies its own series" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = parseVersion("13.2.x-dev").?;
    try testing.expectEqual(@as(u32, 13), v.parts[0]);
    try testing.expectEqual(@as(u32, 2), v.parts[1]);
    try testing.expectEqual(branch_alias_pad, v.parts[2]);
    try testing.expectEqual(Stability.dev, v.stability);

    // The behaviour that matters: phpunit's 13.2.x-dev satisfies ^13.2.6.
    try testing.expect(try accepts(a, "^13.2.6", "13.2.x-dev"));
    try testing.expect(!try accepts(a, "^14.0", "13.2.x-dev"));
}

test "a branch satisfies only an exact match on itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try accepts(a, "dev-master", "dev-master"));
    try testing.expect(!try accepts(a, "dev-master", "dev-main"));
    // The dangerous one: a branch must not silently satisfy a numeric range.
    try testing.expect(!try accepts(a, "^1.0", "dev-master"));
    try testing.expect(!try accepts(a, ">=1.0", "dev-master"));
}

test "a stability flag does not widen the version half" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try accepts(a, "^2.0@dev", "2.1.0"));
    try testing.expect(!try accepts(a, "^2.0@dev", "3.0.0"));
    try testing.expect(try accepts(a, "@dev", "1.0.0"));
}

test "hyphen ranges are inclusive to the precision written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try accepts(a, "1.0 - 2.0", "1.5.0"));
    // `- 2.0` covers the whole 2.0 series.
    try testing.expect(try accepts(a, "1.0 - 2.0", "2.0.9"));
    try testing.expect(!try accepts(a, "1.0 - 2.0", "2.1.0"));
}

test "minimum-stability names map to the ordering, unknown text stays strict" {
    try testing.expectEqual(Stability.dev, stabilityFromName("dev"));
    try testing.expectEqual(Stability.beta, stabilityFromName("BETA"));
    try testing.expectEqual(Stability.rc, stabilityFromName("RC"));
    try testing.expectEqual(Stability.stable, stabilityFromName("stable"));
    // A typo must not widen the pool.
    try testing.expectEqual(Stability.stable, stabilityFromName("devv"));
}

test "an empty constraint constrains nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try accepts(a, "", "1.0.0"));
}

test "agrees with composer's own Semver on every constraint in the kernel's tree" {
    // A differential test, not a hand-written one. The corpus is
    //   testdata/semver_corpus.json — [version, constraint, composer's answer]
    // built from every (require, locked version) pair in the kernel's
    // composer.lock, then crossed with a spread of versions for negative
    // coverage, and evaluated by `Composer\Semver\Semver::satisfies` itself.
    //
    // Regenerate with the two commands in docs/hkm-cli-usage.md; the point is
    // that agreement is MEASURED against the implementation being replaced,
    // rather than asserted from a reading of the rules.
    const corpus = @embedFile("testdata/semver_corpus.json");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, corpus, .{});
    try testing.expect(parsed == .array);

    var checked: usize = 0;
    var disagreements: usize = 0;

    for (parsed.array.items) |row| {
        if (row != .array or row.array.items.len != 3) continue;
        const version = row.array.items[0].string;
        const text = row.array.items[1].string;
        const want = row.array.items[2].bool;

        const c = parse(a, text) catch {
            std.debug.print("could not parse constraint '{s}'\n", .{text});
            disagreements += 1;
            continue;
        };
        const got = c.accepts(version);
        checked += 1;

        if (got != want) {
            disagreements += 1;
            if (disagreements <= 10) {
                std.debug.print(
                    "disagree: version '{s}' vs constraint '{s}' — composer says {}, we say {}\n",
                    .{ version, text, want, got },
                );
            }
        }
    }

    try testing.expect(checked > 5000);
    try testing.expectEqual(@as(usize, 0), disagreements);
}
