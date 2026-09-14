//! Running `git`, and the local mirror that makes a non-GitHub repository
//! readable without cloning it once per question.
//!
//! ## Why a mirror at all
//!
//! GitHub is a special case in `vcs.zig` because it serves a file at a commit
//! over a static host: `raw.githubusercontent.com/<o>/<r>/<sha>/composer.json`
//! costs no API quota and needs no checkout. Nothing else does. GitLab and
//! Bitbucket have the endpoint but only behind their API, self-hosted Gitea and
//! Forgejo vary by version and by instance configuration, and `ssh://` has no
//! HTTP surface at all.
//!
//! The git protocol, though, is the same everywhere. So for every non-GitHub
//! host this keeps a bare mirror under the cache and answers from it:
//!
//!   * refs        — `git ls-remote <mirror>`, a local read
//!   * a manifest  — `git cat-file blob <sha>:composer.json`, a local read
//!   * the code    — `git archive <sha>`, piped straight into the unpacker
//!
//! One fetch per repository per TTL, then every subsequent question is answered
//! off the disk. Composer's generic driver clones too, so this is not slower
//! than the tool it replaces; what it avoids is Composer's habit of cloning
//! AGAIN for each ref it wants to read.
//!
//! ## `git archive` rather than a working tree
//!
//! An install could `git clone` into `vendor/<name>` and check out the ref.
//! That leaves a `.git` directory in the vendor tree, which is what Composer's
//! source install does and what makes `composer install --prefer-source` weigh
//! hundreds of megabytes. `git archive` writes the tree at a commit and nothing
//! else, so a source-installed package looks exactly like a dist-installed one
//! — same bytes, no repository, no accidental `git status` noise from vendor.
//!
//! ## What is not done
//!
//! No credential is ever PROMPTED for. Every git invocation runs with
//! `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS` pointed at nothing, because a
//! resolver that blocks on an invisible password prompt inside a thread pool
//! looks exactly like a hang. A repository needing a credential that `auth.zig`
//! does not have fails, and is reported as failing.

const std = @import("std");
const util = @import("util.zig");
const auth = @import("auth.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Error = error{
    GitFailed,
    NoMirror,
};

/// How long a mirror is trusted before it is re-fetched, in seconds.
///
/// The same five minutes `vcs.refs_ttl_seconds` gives a ref listing, and for
/// the same reason: it is the span over which someone re-runs a resolve while
/// working. `--refresh` bypasses it.
pub const mirror_ttl_seconds: i64 = 300;

/// Ignore mirror freshness for this process.
pub var refresh: bool = false;

/// Credentials for https remotes. Set once by the host, read by every worker —
/// the same shape and the same reasoning as `fetch.credentials`.
pub var credentials: auth.Store = .{};

/// Run `git` with the prompt-free environment and return its stdout.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    argv: []const []const u8,
) ![]const u8 {
    return runTool(allocator, io, env, argv);
}

/// The same, for any version-control tool.
///
/// `hg` and `svn` need exactly the same treatment — a prompt-free environment,
/// stdout captured, stderr discarded — and the reason is the same one: a
/// credential prompt inside a worker thread is indistinguishable from a hang.
pub fn runTool(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    argv: []const []const u8,
) ![]const u8 {
    // A COPY, built entry by entry. `var quiet = env.*` looks equivalent and is
    // not: `Environ.Map` is a handle onto an array hash map, so the copy shares
    // the caller's backing store while carrying its own stale capacity, and the
    // first `put` writes past the end of the original's key array. It panicked
    // on the first non-GitHub repository this was pointed at.
    var quiet: EnvMap = .init(allocator);
    var it = env.iterator();
    while (it.next()) |e| quiet.put(e.key_ptr.*, e.value_ptr.*) catch {};

    // A missing credential must fail, not block. All of these are needed:
    // GIT_TERMINAL_PROMPT stops git's own tty prompt, GIT_ASKPASS and
    // SSH_ASKPASS stop the helper an interactive desktop session would
    // otherwise pop up, and GCM_INTERACTIVE stops Git Credential Manager's.
    //
    // Set on the CHILD only. Putting them in the caller's environment would
    // leak `GIT_ASKPASS=echo` into every `scripts` command the project runs.
    quiet.put("GIT_TERMINAL_PROMPT", "0") catch {};
    quiet.put("GIT_ASKPASS", "echo") catch {};
    quiet.put("SSH_ASKPASS", "echo") catch {};
    quiet.put("GCM_INTERACTIVE", "never") catch {};

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &quiet,
        .stdin = .ignore,
        .stdout = .pipe,
        // Progress chatter and "Cloning into" are not ours to relay, and a
        // credential prompt on stderr would be noise around a failure the
        // caller reports properly.
        .stderr = .ignore,
    }) catch return Error.GitFailed;

    var out: std.ArrayList(u8) = .empty;
    if (child.stdout) |f| {
        var buf: [64 * 1024]u8 = undefined;
        var reader = f.reader(io, &buf);
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch break;
            out.appendSlice(allocator, chunk) catch break;
            reader.interface.toss(chunk.len);
        }
    }

    const term = child.wait(io) catch return Error.GitFailed;
    switch (term) {
        .exited => |c| if (c != 0) return Error.GitFailed,
        else => return Error.GitFailed,
    }
    return out.toOwnedSlice(allocator);
}

/// Is `git` on this machine at all?
pub fn available(allocator: std.mem.Allocator, io: Io, env: *EnvMap) bool {
    const out = run(allocator, io, env, &.{ "git", "--version" }) catch return false;
    return std.mem.startsWith(u8, out, "git version");
}

// ── the mirror ────────────────────────────────────────────────────────────────

/// Where a repository's bare mirror lives.
///
/// Named by a hash of the URL rather than by owner/name, because a generic host
/// has neither: `ssh://git@build.internal:2222/~ci/pkg.git` has no shape this
/// can rely on, and two different hosts may serve the same project path.
pub fn mirrorPath(allocator: std.mem.Allocator, cache_dir: []const u8, url: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});

    // Enough of the hash to be collision-free in practice, short enough that
    // the path stays readable in an error message.
    const name = try std.fmt.allocPrint(allocator, "{x}", .{digest[0..10]});
    return std.fs.path.join(allocator, &.{ cache_dir, "git", name });
}

/// A bare mirror of `url`, cloned or updated as needed.
///
/// Returns the mirror path. A repository that is already mirrored and fresh
/// costs one `stat`.
pub fn mirror(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    url: []const u8,
) ![]const u8 {
    const path = try mirrorPath(allocator, cache_dir, url);
    const remote = credentials.gitUrl(allocator, url) orelse url;

    const head = try std.fs.path.join(allocator, &.{ path, "HEAD" });
    if (util.fileExists(io, head)) {
        if (!refresh and fresh(io, head)) return path;

        // `remote update` rather than `fetch`, so that deleted upstream refs
        // disappear here too. A tag that was force-moved is the case that
        // matters: without --prune the old sha survives and a resolve pins a
        // commit the upstream no longer has.
        _ = run(allocator, io, env, &.{
            "git", "--git-dir", path, "remote", "update", "--prune",
        }) catch {
            // A fetch failure with a usable mirror already on disk is not
            // fatal: an offline machine should resolve from what it has rather
            // than fail, exactly as a cached ref listing does.
            return path;
        };
        touch(io, head);
        return path;
    }

    if (util.parentOf(path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
    Dir.cwd().deleteTree(io, path) catch {};

    _ = run(allocator, io, env, &.{ "git", "clone", "--mirror", "--quiet", remote, path }) catch
        return Error.GitFailed;

    if (!util.fileExists(io, head)) return Error.NoMirror;
    return path;
}

/// One file's contents at one commit, read out of a mirror.
pub fn blobAt(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    sha: []const u8,
    path: []const u8,
) ?[]const u8 {
    const spec = std.fmt.allocPrint(allocator, "{s}:{s}", .{ sha, path }) catch return null;
    return run(allocator, io, env, &.{ "git", "--git-dir", mirror_dir, "cat-file", "blob", spec }) catch null;
}

/// Every ref in a mirror, in `git ls-remote` format.
pub fn refLines(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
) ![]const u8 {
    // Against the mirror path, so this is a local read with no network at all.
    // `--heads --tags` and NOT `--refs`, for the same annotated-tag reason
    // documented in `vcs.parseRefs`: the peeled entry carries the commit.
    return run(allocator, io, env, &.{ "git", "ls-remote", "--heads", "--tags", mirror_dir });
}

/// Clone a WORKING COPY at `sha` into `dest`, `.git` and all.
///
/// What `--prefer-source` actually asks for. The difference from `archiveAt` is
/// the whole point of the flag: a source install exists so that someone can
/// edit a dependency in place, see what they changed, and produce a patch —
/// none of which a detached export supports. `composer status` reporting a
/// locally modified package likewise depends on there being a repository to
/// ask.
///
/// Cloned from the local mirror rather than from the network, so this costs a
/// local copy rather than a second fetch. `--no-checkout` then an explicit
/// checkout, because the reference is usually a commit that no branch points
/// at, and a plain clone would leave the default branch checked out instead.
pub fn cloneWorkingCopy(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    origin_url: []const u8,
    sha: []const u8,
    dest: []const u8,
) !void {
    if (util.parentOf(dest)) |parent| Dir.cwd().createDirPath(io, parent) catch {};
    Dir.cwd().deleteTree(io, dest) catch {};

    _ = run(allocator, io, env, &.{
        "git", "clone", "--no-checkout", mirror_dir, dest,
    }) catch return Error.GitFailed;

    // The clone's `origin` points at the local mirror, which is this tool's
    // cache and not somewhere the user can push. Repointing it at the real URL
    // is what makes the working copy usable — and what Composer leaves behind.
    _ = run(allocator, io, env, &.{
        "git", "-C", dest, "remote", "set-url", "origin", origin_url,
    }) catch {};

    _ = run(allocator, io, env, &.{
        "git", "-C", dest, "checkout", "--force", sha,
    }) catch return Error.GitFailed;
}

/// Write the tree at `sha` into `out_path` as a zip archive.
///
/// The archive is what `install` then unpacks, so a source-installed package
/// travels the same code path as a dist-installed one — including the traversal
/// checks in the extractor.
pub fn archiveAt(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    sha: []const u8,
    out_path: []const u8,
) !void {
    if (util.parentOf(out_path)) |parent| Dir.cwd().createDirPath(io, parent) catch {};

    // `--prefix` gives the archive the single wrapping directory the unpacker
    // already knows how to strip, matching what a GitHub zipball looks like.
    _ = run(allocator, io, env, &.{
        "git",      "--git-dir",    mirror_dir,
        "archive",  "--format=zip", "--prefix=package/",
        "--output", out_path,       sha,
    }) catch return Error.GitFailed;

    if (!util.fileExists(io, out_path)) return Error.GitFailed;
}

/// The commit a ref resolves to, in a mirror.
pub fn resolveRef(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    mirror_dir: []const u8,
    ref: []const u8,
) ?[]const u8 {
    const out = run(allocator, io, env, &.{
        "git", "--git-dir", mirror_dir, "rev-parse", ref,
    }) catch return null;
    const sha = std.mem.trim(u8, out, " \t\r\n");
    return if (sha.len == 40) sha else null;
}

pub fn fresh(io: Io, path: []const u8) bool {
    if (mirror_ttl_seconds <= 0) return false;
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const age_ns = now - @as(i96, st.mtime.nanoseconds);
    // A clock that reads backwards should not turn every resolve into a full
    // re-fetch, the same allowance the metadata cache makes.
    if (age_ns < 0) return true;
    return age_ns < @as(i96, mirror_ttl_seconds) * std.time.ns_per_s;
}

pub fn touch(io: Io, path: []const u8) void {
    const existing = Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(4096)) catch return;
    defer std.heap.page_allocator.free(existing);
    util.writeFileAtomic(io, path, existing) catch {};
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a mirror is named by the hash of its url, not by a path shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The point of hashing: these have no owner/name to key on, and two of them
    // share a project path on different hosts.
    const urls = [_][]const u8{
        "https://gitlab.com/acme/thing.git",
        "ssh://git@build.internal:2222/~ci/thing.git",
        "https://git.example.org/acme/thing.git",
    };
    var seen: [3][]const u8 = undefined;
    for (urls, 0..) |u, i| {
        seen[i] = try mirrorPath(a, "/cache", u);
        try testing.expect(std.mem.startsWith(u8, seen[i], "/cache/git/"));
    }
    try testing.expect(!std.mem.eql(u8, seen[0], seen[1]));
    try testing.expect(!std.mem.eql(u8, seen[0], seen[2]));
    try testing.expect(!std.mem.eql(u8, seen[1], seen[2]));

    // And it is stable, so a second run reuses the same mirror.
    try testing.expectEqualStrings(seen[0], try mirrorPath(a, "/cache", urls[0]));
}
