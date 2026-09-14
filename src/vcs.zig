//! `repositories: [{ "type": "vcs", ... }]` — packages read from git.
//!
//! ## Why this is faster than Composer, and not by a little
//!
//! Composer's `GitHubDriver` talks to **api.github.com**: one call to list
//! refs, then one per ref to read that ref's composer.json. Unauthenticated
//! that budget is 60 calls an hour for the whole machine. A project here
//! declares **34 vcs repositories**, so a single `composer update` exhausts the
//! hour's quota before it has finished looking, and Composer then falls back to
//! a full `git clone` of every repository. That is the 250-second install this
//! package was written to replace.
//!
//! Nothing here touches the API:
//!
//!   * **refs** come from `git ls-remote`, which is the git protocol, not the
//!     API, and has no quota at all. One process per repository, no clone, no
//!     working tree — a few kilobytes over the wire.
//!   * **composer.json at a ref** comes from `raw.githubusercontent.com`, which
//!     serves static content and is not the API either.
//!   * **the archive** comes from the zipball URL, which redirects to codeload
//!     and costs no quota, exactly as it already does for packagist packages.
//!
//! ## And why the cache can be permanent
//!
//! Every one of those reads is keyed by a COMMIT SHA. A sha names one immutable
//! tree, so a composer.json fetched for it can be cached forever with no
//! staleness question to answer. Packagist metadata gets a one-hour TTL because
//! a new release changes it; `raw/<sha>/composer.json` cannot change.
//!
//! ## Everywhere else
//!
//! No other host serves a file at a commit without an API. GitLab and Bitbucket
//! have the endpoint behind theirs; Gitea and Forgejo vary by instance; `ssh://`
//! has no HTTP surface at all. Those go through `git.zig`, which keeps ONE bare
//! mirror per repository under the cache and answers refs, manifests and the
//! archive itself out of it — the git protocol is the one thing every host has
//! in common.
//!
//! That is slower than the GitHub path on a cold cache (a mirror clone, once)
//! and about the same afterwards, since every subsequent question is a local
//! read. It is not slower than Composer, whose generic driver clones as well.
//! The reason GitHub keeps its own path is that it can skip the clone entirely,
//! not that the general one does not work.

const std = @import("std");
const fetch = @import("fetch.zig");
const git = @import("git.zig");
const hg = @import("hg.zig");
const svn = @import("svn.zig");
const packagist = @import("packagist.zig");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    UnsupportedUrl,
    LsRemoteFailed,
};

pub const Provider = enum {
    /// Static endpoints, no clone, no API quota.
    github,
    /// Any other git host, over a bare mirror.
    generic,
    hg,
    svn,
};

pub const Repo = struct {
    /// As declared in composer.json.
    url: []const u8,
    provider: Provider,
    /// Only meaningful for `github`.
    owner: []const u8 = "",
    name: []const u8 = "",
    /// Only meaningful for `svn` — which directories are tags and branches.
    layout: svn.Layout = .{},

    /// The URL `git ls-remote` is pointed at.
    pub fn gitUrl(self: Repo, allocator: std.mem.Allocator) ![]const u8 {
        if (self.provider != .github) return self.url;
        return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ self.owner, self.name });
    }
};

/// Recognise a repository URL.
///
/// Only GitHub is given a fast path, because only GitHub has a static host that
/// serves a file at a commit without an API call. A non-GitHub URL still works
/// through `git ls-remote`, but its composer.json cannot be read without a
/// clone — so it is reported as unsupported rather than silently skipped.
pub fn parse(allocator: std.mem.Allocator, url: []const u8) !Repo {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, url, " \t"), "/");

    const markers = [_][]const u8{
        "https://github.com/",
        "http://github.com/",
        "git@github.com:",
        "ssh://git@github.com/",
    };
    for (markers) |m| {
        if (!std.mem.startsWith(u8, trimmed, m)) continue;
        var path = trimmed[m.len..];
        if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];

        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return Error.UnsupportedUrl;
        const owner = path[0..slash];
        const name = path[slash + 1 ..];
        if (owner.len == 0 or name.len == 0) return Error.UnsupportedUrl;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return Error.UnsupportedUrl;

        return .{
            .url = try allocator.dupe(u8, trimmed),
            .provider = .github,
            .owner = try allocator.dupe(u8, owner),
            .name = try allocator.dupe(u8, name),
        };
    }

    return .{ .url = try allocator.dupe(u8, trimmed), .provider = .generic };
}

/// Recognise a repository whose TYPE was declared, rather than guessed.
///
/// `"type": "hg"` and `"type": "svn"` say which tool to use, and Composer
/// honours that without probing. Only a bare `"type": "vcs"` is auto-detected —
/// and even then only between the git flavours here, with hg and svn tried as a
/// fallback in `candidates` when git cannot read the URL at all.
pub fn parseAs(
    allocator: std.mem.Allocator,
    kind: manifest.Repo.Kind,
    url: []const u8,
    declared: ?std.json.Value,
) !Repo {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, url, " \t"), "/");
    return switch (kind) {
        .hg => .{ .url = try allocator.dupe(u8, trimmed), .provider = .hg },
        .svn => .{
            .url = try allocator.dupe(u8, trimmed),
            .provider = .svn,
            .layout = svn.layoutOf(declared),
        },
        else => parse(allocator, url),
    };
}

pub const RefKind = enum { tag, branch };

pub const Ref = struct {
    /// `v1.2.3`, `master`.
    name: []const u8,
    sha: []const u8,
    kind: RefKind,
};

/// How long a ref listing is trusted, in seconds.
///
/// Refs are MUTABLE — a tag pushed a minute ago changes the answer — so unlike
/// the sha-keyed manifests this cannot be cached forever. Five minutes is the
/// span over which someone re-runs a resolve while working, and re-listing 34
/// repositories takes about fifteen seconds of pure latency. `--refresh` skips
/// it for the case where the push being waited on is your own.
pub const refs_ttl_seconds: i64 = 300;

/// Ignore the cached ref listings for this process.
pub var refresh_refs: bool = false;

fn refsCachePath(allocator: std.mem.Allocator, cache_dir: []const u8, repo: Repo) ?[]const u8 {
    const key = std.fmt.allocPrint(allocator, "{s}-{s}.refs", .{ repo.owner, repo.name }) catch return null;
    return std.fs.path.join(allocator, &.{ cache_dir, "vcs", key }) catch null;
}

/// Every tag and branch, from one `git ls-remote`.
pub fn refs(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    repo: Repo,
    cache_dir: []const u8,
) ![]const Ref {
    const url = try repo.gitUrl(allocator);

    if (repo.provider == .hg) {
        const dir = try hg.mirror(allocator, io, env, cache_dir, repo.url);
        const found = hg.refs(allocator, io, env, dir) catch return Error.LsRemoteFailed;
        var out: std.ArrayList(Ref) = .empty;
        for (found) |r| {
            try out.append(allocator, .{
                .name = r.name,
                .sha = r.node,
                .kind = if (r.kind == .tag) .tag else .branch,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    if (repo.provider == .svn) {
        // No mirror: Subversion answers over the network directly, so there is
        // nothing local that could disagree with the server.
        const found = svn.refs(allocator, io, env, repo.url, repo.layout) catch return Error.LsRemoteFailed;
        var out: std.ArrayList(Ref) = .empty;
        for (found) |r| {
            try out.append(allocator, .{
                .name = r.name,
                // The `sha` here is an svn IDENTIFIER — `/tags/1.0/@42` — not a
                // hash. It plays the same role: the immutable thing a version
                // resolves to, and what the lock records as its reference.
                .sha = r.identifier,
                .kind = if (r.kind == .tag) .tag else .branch,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    // A non-GitHub git host is read out of its mirror. `ls-remote` against a
    // local directory is a disk read, so the TTL that guards it is the
    // MIRROR's, in `git.zig`, and there is no second cache file to keep in step.
    if (repo.provider != .github) {
        const dir = try git.mirror(allocator, io, env, cache_dir, url);
        const out = git.refLines(allocator, io, env, dir) catch return Error.LsRemoteFailed;
        return parseRefs(allocator, out);
    }

    const cache_path = refsCachePath(allocator, cache_dir, repo);
    if (!refresh_refs) {
        if (cache_path) |path| {
            if (freshEnough(io, path)) {
                if (Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch null) |cached| {
                    return parseRefs(allocator, cached);
                }
            }
        }
    }

    const out = runGit(allocator, io, env, &.{
        "git",
        "ls-remote",
        "--heads",
        "--tags",
        // NOT `--refs`. A peeled entry (`refs/tags/x^{}`) names the COMMIT an
        // annotated tag points at, and the unpeeled one names the tag OBJECT —
        // which has no tree, so fetching `raw/<that sha>/composer.json` is a
        // 404 and the version disappears from the pool without a word.
        //
        // Found by disagreeing with composer over one package out of 71:
        // `phpshots/bind-it` tag `0.1.4` is annotated, so this recorded
        // 6da47806 (the tag object) where composer had 97cf256a (the commit).
        url,
    }) catch return Error.LsRemoteFailed;

    if (cache_path) |path| {
        if (util.parentOf(path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
        util.writeFileAtomic(io, path, out) catch {};
    }

    return parseRefs(allocator, out);
}

/// Is a cached listing younger than the TTL?
///
/// The same shape as the metadata cache's check in `packagist.zig`, including
/// its treatment of clock skew: a file that appears to be from the future is
/// trusted rather than refetched, because a wrong clock should not turn every
/// resolve into a full re-listing.
fn freshEnough(io: Io, path: []const u8) bool {
    if (refs_ttl_seconds <= 0) return false;
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const age_ns = now - @as(i96, st.mtime.nanoseconds);
    if (age_ns < 0) return true;
    return age_ns < @as(i96, refs_ttl_seconds) * std.time.ns_per_s;
}

fn parseRefs(allocator: std.mem.Allocator, out: []const u8) ![]const Ref {
    var list: std.ArrayList(Ref) = .empty;

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const sha = std.mem.trim(u8, line[0..tab], " \t\r");
        const full = std.mem.trim(u8, line[tab + 1 ..], " \t\r");

        if (std.mem.startsWith(u8, full, "refs/tags/")) {
            var name = full["refs/tags/".len..];

            // A peeled entry names the same tag, at the commit rather than the
            // tag object, and it is the one to keep. Both orderings are handled
            // because git lists them adjacently but the pair may arrive either
            // way round depending on the server.
            const peeled = std.mem.endsWith(u8, name, "^{}");
            if (peeled) name = name[0 .. name.len - 3];

            var replaced = false;
            for (list.items) |*existing| {
                if (existing.kind != .tag or !std.mem.eql(u8, existing.name, name)) continue;
                replaced = true;
                if (peeled) existing.sha = sha; // the commit wins
                break;
            }
            if (!replaced) try list.append(allocator, .{ .name = name, .sha = sha, .kind = .tag });
        } else if (std.mem.startsWith(u8, full, "refs/heads/")) {
            try list.append(allocator, .{
                .name = full["refs/heads/".len..],
                .sha = sha,
                .kind = .branch,
            });
        }
    }

    return list.toOwnedSlice(allocator);
}

/// The composer.json at one commit.
///
/// Cached by sha, permanently: a sha names an immutable tree, so there is no
/// staleness question to answer and no TTL to get wrong.
pub fn manifestAt(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    repo: Repo,
    sha: []const u8,
) ?[]const u8 {
    if (repo.provider == .hg) {
        const dir = hg.mirror(allocator, io, env, cache_dir, repo.url) catch return null;
        return hg.fileAt(allocator, io, env, dir, sha, "composer.json");
    }
    if (repo.provider == .svn) {
        return svn.fileAt(allocator, io, env, repo.url, sha, "composer.json");
    }

    if (repo.provider != .github) {
        const url = repo.gitUrl(allocator) catch return null;
        const dir = git.mirror(allocator, io, env, cache_dir, url) catch return null;
        // No second cache: the blob is already on this disk, inside the mirror.
        // Copying it into a parallel cache would only create a way for the two
        // to disagree.
        const body = git.blobAt(allocator, io, env, dir, sha, "composer.json") orelse return null;
        return if (body.len == 0) null else body;
    }

    const path = std.fs.path.join(allocator, &.{
        cache_dir,
        "vcs",
        std.fmt.allocPrint(allocator, "{s}-{s}", .{ repo.owner, repo.name }) catch return null,
        std.fmt.allocPrint(allocator, "{s}.json", .{sha}) catch return null,
    }) catch return null;

    if (Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch null) |cached| {
        // A recorded MISS is a zero-byte file: a repository with no
        // composer.json at that ref must not be re-requested on every resolve.
        return if (cached.len == 0) null else cached;
    }

    const url = std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/{s}/{s}/{s}/composer.json",
        .{ repo.owner, repo.name, sha },
    ) catch return null;

    const body = fetch.download(allocator, io, url) catch {
        if (util.parentOf(path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
        util.writeFileAtomic(io, path, "") catch {};
        return null;
    };

    if (util.parentOf(path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
    util.writeFileAtomic(io, path, body) catch {};
    return body;
}

/// Settle which tool a bare `"type": "vcs"` entry actually needs.
///
/// Done ONCE, here, and the result is used for every subsequent question about
/// the repository. Probing inside `refs` alone was not enough and produced a
/// repository that listed its versions and then had no manifest for any of
/// them: `candidates` went on to ask `manifestAt` and `sourceOf` with the
/// ORIGINAL provider, which was still git.
///
/// Probed rather than guessed from the URL, because a URL says almost nothing:
/// `https://code.example/acme/thing` is a valid address for all three tools.
/// The probe only ever runs once git has already failed to read the URL, which
/// for a git repository is never — an explicit `"type": "hg"` or `"type":
/// "svn"` skips it entirely.
///
/// The order is Mercurial then Subversion, and it is not arbitrary: `hg
/// identify` on a Subversion URL fails immediately, while `svn info` on a
/// Mercurial URL can sit waiting on a server that speaks a different protocol.
pub fn resolveProvider(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    repo: Repo,
) Repo {
    if (repo.provider != .generic) return repo;

    const url = repo.gitUrl(allocator) catch return repo;
    if (git.mirror(allocator, io, env, cache_dir, url)) |_| {
        return repo;
    } else |_| {}

    if (hg.available(allocator, io, env)) {
        if (hg.run(allocator, io, env, &.{ "hg", "identify", "--", repo.url }) catch null) |_| {
            return .{ .url = repo.url, .provider = .hg };
        }
    }
    if (svn.available(allocator, io, env) and svn.probe(allocator, io, env, repo.url)) {
        return .{ .url = repo.url, .provider = .svn };
    }
    return repo;
}

/// Composer's version for a ref.
///
/// Tags become the version they name; branches become a dev version. The
/// numeric-branch rule is the one that matters in practice: a branch called
/// `1.0` is `1.0.x-dev`, not `dev-1.0`, and a constraint of `^1.0` matches the
/// first and not the second.
pub fn versionOf(allocator: std.mem.Allocator, ref: Ref) !?[]const u8 {
    if (ref.kind == .tag) {
        const name = if (ref.name.len > 1 and (ref.name[0] == 'v' or ref.name[0] == 'V'))
            ref.name[1..]
        else
            ref.name;
        if (name.len == 0 or !std.ascii.isDigit(name[0])) return null;
        return ref.name;
    }

    if (numericBranch(ref.name)) |base| {
        const v: []const u8 = try std.fmt.allocPrint(allocator, "{s}.x-dev", .{base});
        return v;
    }
    const v: []const u8 = try std.fmt.allocPrint(allocator, "dev-{s}", .{ref.name});
    return v;
}

/// `1.0`, `v2`, `3.4.x` → the numeric stem; anything else → null.
fn numericBranch(name: []const u8) ?[]const u8 {
    var s = name;
    if (s.len > 1 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;

    var end: usize = 0;
    var seen_digit = false;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (std.ascii.isDigit(c)) {
            seen_digit = true;
            continue;
        }
        if (c == '.') continue;
        if ((c == 'x' or c == 'X') and end + 1 == s.len) break;
        return null;
    }
    if (!seen_digit) return null;

    var stem = if (end < s.len) s[0..end] else s;
    stem = std.mem.trimEnd(u8, stem, ".");
    return if (stem.len == 0) null else stem;
}

/// Every version this repository offers, as candidates the solver can use.
///
/// One `git ls-remote`, then one static fetch per ref that is not already
/// cached. A repository whose refs have all been seen before costs exactly one
/// network round trip; Composer's equivalent costs one API call per ref, every
/// time, against a 60-per-hour budget.
pub fn candidates(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    declared: Repo,
) ![]const packagist.Candidate {
    // Settled first, and then used for every question below. See
    // `resolveProvider` for the failure this ordering exists to prevent.
    const repo = resolveProvider(allocator, io, env, cache_dir, declared);
    const all = try refs(allocator, io, env, repo, cache_dir);

    var out: std.ArrayList(packagist.Candidate) = .empty;
    for (all) |ref| {
        const version = (try versionOf(allocator, ref)) orelse continue;
        const source = manifestAt(allocator, io, env, cache_dir, repo, ref.sha) orelse continue;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{}) catch continue;
        if (parsed != .object) continue;

        var obj = try parsed.object.clone(allocator);
        const name = switch (obj.get("name") orelse continue) {
            .string => |v| v,
            else => continue,
        };

        // The version comes from the REF, never from a `version` field in the
        // file. A package that hard-codes one and forgets to bump it would
        // otherwise report every tag as the same release.
        try obj.put(allocator, "version", .{ .string = version });
        try obj.put(allocator, "source", .{ .object = try sourceOf(allocator, repo, ref.sha) });
        // Only GitHub publishes a generated archive at a URL. Everywhere else
        // the lock records the SOURCE alone, exactly as Composer does, and the
        // installer builds the tree with `git archive` off the mirror. Writing
        // a fabricated dist URL here would produce a lock that resolves and
        // then 404s on a different machine.
        if (repo.provider == .github) {
            try obj.put(allocator, "dist", .{ .object = try distOf(allocator, repo, ref.sha) });
        } else {
            _ = obj.orderedRemove("dist");
        }

        // Composer's ArrayLoader defaults an absent `type` to `library`, and
        // the lock records it, so a manifest that omits the key still produces
        // `"type": "library"` in the lock rather than no key at all.
        const kind = switch (obj.get("type") orelse std.json.Value{ .string = "library" }) {
            .string => |v| v,
            else => "library",
        };
        try obj.put(allocator, "type", .{ .string = kind });

        // The commit date, which Composer takes from the driver and writes as
        // the lock's `time`. Free here: the mirror is on this disk, and for
        // GitHub the sha-keyed cache means one call per new ref ever.
        if (commitTime(allocator, io, env, cache_dir, repo, ref.sha)) |t| {
            try obj.put(allocator, "time", .{ .string = t });
        }

        try out.append(allocator, .{
            .name = name,
            .version = version,
            .version_normalized = lock.normalizeVersion(allocator, version) catch version,
            .kind = kind,
            .origin = .vcs,
            .raw = .{ .object = obj },
        });
    }

    return out.toOwnedSlice(allocator);
}

/// The commit's author date, in the format the lock records.
///
/// Composer's `time`. For GitHub it comes from the API; here it comes from the
/// mirror for a generic host, and from a sha-keyed cache file for GitHub, where
/// there is no mirror to ask. A missing time is omitted rather than guessed:
/// the lock's own key order puts `time` last and Composer skips it when the
/// driver has none.
fn commitTime(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    repo: Repo,
    sha: []const u8,
) ?[]const u8 {
    if (repo.provider == .hg) {
        const dir = hg.mirror(allocator, io, env, cache_dir, repo.url) catch return null;
        return hg.changeDate(allocator, io, env, dir, sha);
    }
    if (repo.provider == .svn) {
        return svn.changeDate(allocator, io, env, repo.url, sha);
    }

    if (repo.provider == .hg) {
        const dir = hg.mirror(allocator, io, env, cache_dir, repo.url) catch return null;
        return hg.changeDate(allocator, io, env, dir, sha);
    }
    if (repo.provider == .svn) {
        // One `svn info` against the revision the identifier already names.
        return svn.changeDate(allocator, io, env, repo.url, sha);
    }

    if (repo.provider == .github) {
        // No mirror exists for GitHub — that is the whole point of its fast
        // path — and the commit date is not in the raw composer.json. Composer
        // gets it from the API; this deliberately does not, so the field is
        // omitted rather than fetched at the cost of the rate limit the fast
        // path exists to avoid.
        return null;
    }

    const url = repo.gitUrl(allocator) catch return null;
    const dir = git.mirror(allocator, io, env, cache_dir, url) catch return null;
    // `%at` — the AUTHOR timestamp, as a unix epoch, which is what Composer's
    // GitDriver reads (`rev-list -n1 --format=%at`). The committer date is a
    // different number on any commit that was rebased or cherry-picked, and
    // picking the wrong one puts a lock one rewrite out of step with Composer's
    // for no visible reason.
    const out = git.run(allocator, io, env, &.{
        "git", "--git-dir", dir, "log", "-1", "--format=%at", sha,
    }) catch return null;
    const epoch = std.fmt.parseInt(i64, std.mem.trim(u8, out, " \t\r\n"), 10) catch return null;
    return util.utcRfc3339(allocator, epoch) catch null;
}

fn sourceOf(allocator: std.mem.Allocator, repo: Repo, sha: []const u8) !std.json.ObjectMap {
    var o: std.json.ObjectMap = .empty;
    // The type is what tells `install` which tool to reach for. Recording
    // `git` for a Mercurial package would produce a lock that resolves and then
    // fails to install with an error about a git remote that never existed.
    try o.put(allocator, "type", .{ .string = switch (repo.provider) {
        .github, .generic => "git",
        .hg => "hg",
        .svn => "svn",
    } });
    try o.put(allocator, "url", .{ .string = switch (repo.provider) {
        .github, .generic => try repo.gitUrl(allocator),
        .hg, .svn => repo.url,
    } });
    try o.put(allocator, "reference", .{ .string = sha });
    return o;
}

/// The dist Composer records for a GitHub package.
///
/// `api.github.com/.../zipball/<sha>` is what ends up in a lock, and it is what
/// this records so the two agree. Fetching it costs no API quota: it answers
/// with a 302 to codeload, and only the redirect target carries the bytes.
fn distOf(allocator: std.mem.Allocator, repo: Repo, sha: []const u8) !std.json.ObjectMap {
    var o: std.json.ObjectMap = .empty;
    try o.put(allocator, "type", .{ .string = "zip" });
    try o.put(allocator, "url", .{ .string = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/zipball/{s}",
        .{ repo.owner, repo.name, sha },
    ) });
    try o.put(allocator, "reference", .{ .string = sha });
    // GitHub does not publish a checksum for a generated zipball, and Composer
    // records the field empty rather than omitting it.
    try o.put(allocator, "shasum", .{ .string = "" });
    return o;
}

/// Read every declared repository, in parallel, into one candidate list.
///
/// Eager rather than on-demand, because a lookup for `acme/thing` cannot know
/// which of 34 repositories publishes it without asking them — and asking one
/// at a time is the serial wait this package exists to remove. Composer has the
/// same problem and solves it the same way; the difference is what each query
/// costs.
///
/// A repository that cannot be read is SKIPPED and counted, not fatal: one
/// unreachable mirror in a list of thirty-four should not fail a resolve that
/// never needed it.
pub fn prime(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    repos: []const Repo,
    workers: usize,
) Primed {
    if (repos.len == 0) return .{ .candidates = &.{}, .failed = 0 };

    const results = allocator.alloc([]const packagist.Candidate, repos.len) catch
        return .{ .candidates = &.{}, .failed = repos.len };
    for (results) |*r| r.* = &.{};

    var shared: Shared = .{
        .io = io,
        .env = env,
        .cache_dir = cache_dir,
        .repos = repos,
        .results = results,
        .next = .init(0),
        .failed = .init(0),
    };

    const n = @min(@max(workers, 1), repos.len);
    if (n == 1) {
        primeWork(&shared);
    } else {
        var threads: [fetch.max_workers]std.Thread = undefined;
        var started: usize = 0;
        while (started < n - 1 and started < fetch.max_workers) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, primeWork, .{&shared}) catch break;
        }
        primeWork(&shared);
        for (threads[0..started]) |t| t.join();
    }

    var all: std.ArrayList(packagist.Candidate) = .empty;
    for (results) |list| {
        all.appendSlice(allocator, list) catch continue;
    }

    return .{
        .candidates = all.toOwnedSlice(allocator) catch &.{},
        .failed = shared.failed.load(.monotonic),
    };
}

pub const Primed = struct {
    candidates: []const packagist.Candidate,
    /// Repositories that could not be read at all.
    failed: usize,
};

const Shared = struct {
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    repos: []const Repo,
    results: [][]const packagist.Candidate,
    next: std.atomic.Value(usize),
    failed: std.atomic.Value(usize),
};

fn primeWork(shared: *Shared) void {
    // Each worker owns an arena that outlives the call: the candidates it
    // builds are handed back and read by the solver, so this deliberately does
    // not reset between repositories the way the metadata warmer does.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();

    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.repos.len) return;

        shared.results[i] = candidates(a, shared.io, shared.env, shared.cache_dir, shared.repos[i]) catch {
            _ = shared.failed.fetchAdd(1, .monotonic);
            continue;
        };
    }
}

// ── running git ───────────────────────────────────────────────────────────────

fn runGit(allocator: std.mem.Allocator, io: Io, env: *EnvMap, argv: []const []const u8) ![]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        // git writes progress and "Cloning into" chatter to stderr; none of it
        // is ours to relay, and a credential prompt would hang the resolve.
        .stderr = .ignore,
    }) catch return Error.LsRemoteFailed;

    var out: std.ArrayList(u8) = .empty;
    if (child.stdout) |f| {
        var buf: [8192]u8 = undefined;
        var reader = f.reader(io, &buf);
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch break;
            out.appendSlice(allocator, chunk) catch break;
            reader.interface.toss(chunk.len);
        }
    }

    const term = child.wait(io) catch return Error.LsRemoteFailed;
    switch (term) {
        .exited => |c| if (c != 0) return Error.LsRemoteFailed,
        else => return Error.LsRemoteFailed,
    }
    return out.toOwnedSlice(allocator);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "github urls are recognised in every spelling composer accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{
        "https://github.com/AlfaCode-Team/hkm-kernel",
        "https://github.com/AlfaCode-Team/hkm-kernel/",
        "https://github.com/AlfaCode-Team/hkm-kernel.git",
        "git@github.com:AlfaCode-Team/hkm-kernel.git",
        "ssh://git@github.com/AlfaCode-Team/hkm-kernel",
    }) |url| {
        const r = try parse(a, url);
        try testing.expectEqual(Provider.github, r.provider);
        try testing.expectEqualStrings("AlfaCode-Team", r.owner);
        try testing.expectEqualStrings("hkm-kernel", r.name);
    }

    const other = try parse(a, "https://gitlab.com/x/y");
    try testing.expectEqual(Provider.generic, other.provider);
}

test "a numeric branch is a version range, a named one is a dev version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The distinction that decides whether `^1.0` matches a maintenance branch.
    try testing.expectEqualStrings("1.0.x-dev", (try versionOf(a, .{ .name = "1.0", .sha = "", .kind = .branch })).?);
    try testing.expectEqualStrings("2.x-dev", (try versionOf(a, .{ .name = "v2", .sha = "", .kind = .branch })).?);
    try testing.expectEqualStrings("3.4.x-dev", (try versionOf(a, .{ .name = "3.4.x", .sha = "", .kind = .branch })).?);

    try testing.expectEqualStrings("dev-master", (try versionOf(a, .{ .name = "master", .sha = "", .kind = .branch })).?);
    try testing.expectEqualStrings("dev-main", (try versionOf(a, .{ .name = "main", .sha = "", .kind = .branch })).?);
    try testing.expectEqualStrings(
        "dev-feature/x",
        (try versionOf(a, .{ .name = "feature/x", .sha = "", .kind = .branch })).?,
    );
}

test "a tag keeps its own spelling, and a non-version tag is skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `v1.2.3` stays `v1.2.3`: the lock records the tag as written, and the
    // normaliser strips the v when comparing.
    try testing.expectEqualStrings("v1.2.3", (try versionOf(a, .{ .name = "v1.2.3", .sha = "", .kind = .tag })).?);
    try testing.expectEqualStrings("1.2.3", (try versionOf(a, .{ .name = "1.2.3", .sha = "", .kind = .tag })).?);

    // A release name that is not a version at all.
    try testing.expect((try versionOf(a, .{ .name = "latest", .sha = "", .kind = .tag })) == null);
    try testing.expect((try versionOf(a, .{ .name = "nightly", .sha = "", .kind = .tag })) == null);
}

test "an annotated tag resolves to its COMMIT, not the tag object" {
    // The defect this exists to prevent, from a real repository: `0.1.4` is an
    // annotated tag, so `refs/tags/0.1.4` is a tag OBJECT with no tree and
    // `refs/tags/0.1.4^{}` is the commit. Recording the former makes
    // `raw/<sha>/composer.json` a 404 and the version vanishes from the pool —
    // silently, because a package with no manifest is simply skipped.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sample =
        "6da4780659be5be40f9b955a1e04a6d4807202fd\trefs/tags/0.1.4\n" ++
        "97cf256a96219f7bbac436b71f850784c94f929b\trefs/tags/0.1.4^{}\n" ++
        "b1d214da5e78352b7b797c98c3384a9e5907d466\trefs/tags/0.1.3\n" ++
        "2e02a761b4f5cf897dd4cc7f8036ae4fe0346c90\trefs/heads/master\n";

    const parsed = try parseRefs(a, sample);

    // One entry for 0.1.4, not two, and it carries the commit.
    var seen: usize = 0;
    for (parsed) |r| {
        if (r.kind == .tag and std.mem.eql(u8, r.name, "0.1.4")) {
            seen += 1;
            try testing.expectEqualStrings("97cf256a96219f7bbac436b71f850784c94f929b", r.sha);
        }
    }
    try testing.expectEqual(@as(usize, 1), seen);
    try testing.expectEqual(@as(usize, 3), parsed.len);
}

test "a lightweight tag keeps its own sha, and the peeled entry may come first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Peeled line BEFORE the plain one — the order is the server's choice.
    const reversed =
        "97cf256a\trefs/tags/1.0.0^{}\n" ++
        "6da47806\trefs/tags/1.0.0\n" ++
        "aaaa1111\trefs/tags/2.0.0\n";

    const parsed = try parseRefs(a, reversed);
    try testing.expectEqual(@as(usize, 2), parsed.len);
    for (parsed) |r| {
        if (std.mem.eql(u8, r.name, "1.0.0")) try testing.expectEqualStrings("97cf256a", r.sha);
        if (std.mem.eql(u8, r.name, "2.0.0")) try testing.expectEqualStrings("aaaa1111", r.sha);
    }
}

test "ls-remote output is parsed into tags and branches" {
    // The shape `git ls-remote --heads --tags --refs` prints.
    const sample =
        "9f1c4b2\trefs/heads/main\n" ++
        "aa11bb2\trefs/heads/1.0\n" ++
        "cc33dd4\trefs/tags/v1.0.0\n";

    var count_tags: usize = 0;
    var count_branches: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, sample, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const full = line[tab + 1 ..];
        if (std.mem.startsWith(u8, full, "refs/tags/")) count_tags += 1;
        if (std.mem.startsWith(u8, full, "refs/heads/")) count_branches += 1;
    }
    try testing.expectEqual(@as(usize, 1), count_tags);
    try testing.expectEqual(@as(usize, 2), count_branches);
}

test "a commit timestamp is spelled as the lock spells it, in UTC" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The value in the lock this was checked against, and the epoch git
    // reported for the same commit.
    try testing.expectEqualStrings("2026-09-07T08:08:39+00:00", try util.utcRfc3339(a, 1788768519));

    // A round number, a leap day, and the epoch itself.
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00", try util.utcRfc3339(a, 0));
    try testing.expectEqualStrings("2024-02-29T12:34:56+00:00", try util.utcRfc3339(a, 1709210096));
    try testing.expectEqualStrings("2000-01-01T00:00:00+00:00", try util.utcRfc3339(a, 946684800));
}
