//! `hkm ppkg install` — build `vendor/` from `composer.lock`.
//!
//! Installing from a lock needs no solver: every version is already chosen and
//! every package carries the URL and immutable reference to fetch. The work is
//! download, unpack, record — and the recording half matters as much as the
//! rest, because `vendor/composer/installed.json` and `installed.php` are what
//! `Composer\InstalledVersions` answers from at runtime.
//!
//! What it does NOT do is resolve. `hkm ppkg require` / `update` — choosing
//! versions against Packagist — is the next piece of work, and until it exists
//! the lock has to come from Composer. That is a real boundary, not a temporary
//! omission to gloss over: this command reproduces a decision, it does not make
//! one.

const std = @import("std");
const lockfile = @import("lock.zig");
const manifest = @import("manifest.zig");
const autoload = @import("autoload.zig");
const fetch = @import("fetch.zig");
const archive = @import("archive.zig");
const git = @import("git.zig");
const hg = @import("hg.zig");
const svn = @import("svn.zig");
const runtime = @import("runtime.zig");
const layout = @import("layout.zig");
const platformcheck = @import("platformcheck.zig");
const platform = @import("platform.zig");
const settings = @import("settings.zig");
const stamps = @import("stamps.zig");
const scripts_mod = @import("scripts.zig");
const lockwrite = @import("lockwrite.zig");
const resolve_mod = @import("resolve.zig");
const autoload_mod = @import("autoload.zig");
const phpjson = @import("phpjson.zig");
const binaries = @import("bin.zig");
const installers = @import("installers.zig");
const prompt = @import("report.zig");
const util = @import("util.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EnvMap = std.process.Environ.Map;

pub const Options = struct {
    dev: bool = true,
    optimize: bool = false,
    /// Report what would happen and touch nothing.
    dry_run: bool = false,
    /// Reinstall packages already present at the right reference.
    force: bool = false,
    /// `--classmap-authoritative` — generate a loader that never falls back to
    /// the filesystem. Implies `optimize`.
    classmap_authoritative: bool = false,
    /// `--apcu-autoloader` — memoise class lookups in APCu.
    apcu: bool = false,
    /// `--apcu-autoloader-prefix` — the key prefix, when one was given.
    apcu_prefix: ?[]const u8 = null,
    /// `--prefer-source` / `--prefer-dist` — overrides `config.preferred-install`
    /// for every package in this run.
    prefer: ?settings.Preference = null,
    /// `--no-autoloader` — place packages, generate nothing.
    skip_autoloader: bool = false,
    /// `--download-only` — fill the cache and stop. For a build stage that
    /// warms a layer it will not run from.
    download_only: bool = false,
    /// `--no-progress` — drop the per-package lines, keep the summary.
    quiet_progress: bool = false,
    /// `--ignore-platform-reqs` / `--ignore-platform-req=…`.
    ///
    /// Also suppresses `platform_check.php`: a project that asked to install
    /// against a machine it does not satisfy does not want a generated file
    /// that refuses to boot on it.
    ignore_platform: platform.Ignore = .{},
    /// Proceed despite a blocking compatibility finding.
    ignore_unsupported: bool = false,
    /// How to handle the ROOT package's `scripts` — see `scripts.zig`.
    /// Composer runs them; `--no-scripts` sets `disabled`.
    scripts: scripts_mod.Options = .{},

    /// `config.preferred-install`, resolved for this project.
    ///
    /// Set by `run` from the merged config, not by the caller. It is per
    /// PACKAGE, because the setting's object form is what makes it useful:
    /// a team pins the two libraries it patches to `source` and takes every
    /// other package as an archive.
    config_preference: ?settings.Settings = null,

    /// How this package should be obtained, config only.
    fn preference(self: Options, name: []const u8) settings.Preference {
        const cfg = self.config_preference orelse return .auto;
        return cfg.preferredInstall(name);
    }
};

pub const Summary = struct {
    installed: usize = 0,
    linked: usize = 0,
    reused: usize = 0,
    cached: usize = 0,
    downloaded_bytes: usize = 0,
    failed: usize = 0,
    binaries: usize = 0,
    /// Archives downloaded with no checksum in the lock to check them against.
    ///
    /// Reported rather than refused: GitHub publishes no digest for a generated
    /// zipball, so refusing would refuse every `vcs` package, and Composer does
    /// not refuse either. But it used to be SILENT, and an operator deploying
    /// a tree is entitled to know how much of it arrived unverified.
    unverified: usize = 0,
    runtime: runtime.Status = .generated,
    /// The compatibility audit stopped this run before anything was written.
    refused: bool = false,
    exit_code: u8 = 0,

    /// What to CALL the two directories in a message — project-relative where
    /// possible. A project with `config.vendor-dir` set does not have a
    /// `vendor/` for a summary line to report on.
    vendor_label: []const u8 = "vendor",
    bin_label: []const u8 = "vendor/bin",
};

/// One package's placement outcome.
const Placement = enum { installed, linked, reused, failed };

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    opts_in: Options,
) !Summary {
    // The merged `config` block — the machine's config.json, then this
    // project, then the environment. Read once, before anything is placed:
    // `preferred-install` decides HOW each package is obtained, so it has to
    // be known before the first one is.
    const cfg = settings.load(allocator, io, env, root_dir);
    var opts = opts_in;
    opts.config_preference = cfg;
    cfg.applyTransport();

    const declared = (try manifest.read(allocator, io, root_dir)) orelse manifest.Manifest{};
    // Where this project actually keeps its tree. `config.vendor-dir` and
    // `config.bin-dir` move it, and the environment moves it again.
    const lay = try layout.resolve(allocator, env, root_dir, declared);
    const vendor_dir = lay.vendor;

    // A private dist needs its credential too, not only the resolve that
    // chose it.
    resolve_mod.useCredentials(allocator, io, env, root_dir);

    const lock = try lockfile.read(allocator, io, root_dir);
    // The same audit `resolve` runs. An install from an existing lock cannot
    // pick the wrong package — the lock already chose — but it still will not
    // run a script.
    if (try resolve_mod.reportCompat(allocator, declared, opts.ignore_unsupported)) |code| {
        return Summary{ .refused = true, .exit_code = code };
    }

    const packages = try lock.selected(allocator, opts.dev);

    // `extra.installer-paths` moves individual packages out of `vendor/`. Read
    // once, before anything is placed: the same answer has to be used for the
    // directory, the `install-path` in installed.json and the bin launcher, or
    // the tree disagrees with its own metadata.
    const rules = try installerRules(allocator, io, root_dir);

    const cache_dir = try fetch.cacheRoot(allocator, env, root_dir);

    var summary: Summary = .{
        .vendor_label = lay.label(allocator, lay.vendor),
        .bin_label = lay.label(allocator, lay.bin),
    };

    // `pre-install-cmd` runs BEFORE anything is placed, which is the only thing
    // that makes it useful: a project uses it to check a precondition, and a
    // hook that fires after the work is a hook that cannot stop it.
    if (!opts.dry_run) {
        const code = try scripts_mod.run(allocator, io, env, lay, .pre_install_cmd, opts.scripts);
        if (code != 0) {
            summary.exit_code = code;
            prompt.err("pre-install-cmd failed; nothing was installed.");
            return summary;
        }
    }
    var placed: std.ArrayList(lockfile.Package) = .empty;

    // What the previous install left in each directory. Read from the cache,
    // not from the vendor tree — see stamps.zig for why nothing is written
    // into a package directory to answer this.
    const table = stamps.read(allocator, io, cache_dir, vendor_dir);

    // Warm the cache concurrently before touching the filesystem. Placement
    // below then finds every archive already local and runs at disk speed.
    if (!opts.dry_run) {
        summary.downloaded_bytes = try prefetchAll(allocator, io, env, cache_dir, packages);
        summary.unverified = fetch.last_unverified;
    }

    for (packages, 0..) |pkg, index| {
        const dest = try destinationOf(allocator, lay, rules, pkg);

        // Progress is printed BEFORE the work, not after: the slow step is the
        // download, and a line that appears only once a package is finished
        // leaves the longest package looking like a hang.
        if (!opts.quiet_progress) {
            prompt.muted(try std.fmt.allocPrint(
                allocator,
                "  [{d}/{d}] {s} ({s})",
                .{ index + 1, packages.len, pkg.name, pkg.version },
            ));
        }

        switch (place(allocator, io, env, root_dir, vendor_dir, cache_dir, pkg, dest, opts, table, &summary)) {
            .installed => summary.installed += 1,
            .linked => summary.linked += 1,
            .reused => summary.reused += 1,
            .failed => {
                summary.failed += 1;
                continue;
            },
        }
        try placed.append(allocator, pkg);
    }

    if (opts.dry_run) return summary;

    // `--download-only` stops here, with every archive in the cache and
    // nothing wired up. A build stage that warms a layer it will not run from
    // wants exactly this and nothing after it.
    if (opts.download_only) return summary;

    // Launchers come after placement, so every target script is on disk, and
    // before the autoloader is generated, because a launcher requires it.
    for (placed.items) |pkg| {
        for (pkg.bin) |rel| {
            const package_dir = try destinationOf(allocator, lay, rules, pkg);
            binaries.install(allocator, io, lay, package_dir, rel) catch {
                prompt.warn(std.fmt.allocPrint(
                    allocator,
                    "{s}: could not create {s}/{s}",
                    .{ pkg.name, summary.bin_label, std.fs.path.basename(rel) },
                ) catch pkg.name);
                continue;
            };
            summary.binaries += 1;
        }
    }

    // Record what each directory now holds, so the next run can skip it.
    {
        var recorded: std.ArrayList(stamps.Stamp) = .empty;
        for (placed.items) |pkg| {
            if (!stampable(pkg.dist.kind)) continue;
            const reference = effectiveReference(pkg);
            if (reference.len == 0) continue;
            try recorded.append(allocator, .{ .name = pkg.name, .reference = reference });
        }
        stamps.write(allocator, io, cache_dir, vendor_dir, recorded.items);
    }

    try writeInstalled(allocator, io, lay, rules, placed.items, opts.dev, opts);

    // `--ignore-platform-reqs` suppresses the GENERATED check as well as the
    // one this command runs. Composer does the same, and the reason is that
    // the file is not a report — it is code the application executes on every
    // request. Writing a check the operator has just said does not apply
    // produces a tree that installs and then refuses to boot.
    const check_platform = !opts.ignore_platform.all and
        checksPlatform(allocator, declared, placed.items);
    if (check_platform) {
        try writePlatformCheck(allocator, io, lay, declared, placed.items);
    } else {
        const stale = try std.fs.path.join(allocator, &.{ vendor_dir, "composer", "platform_check.php" });
        Dir.cwd().deleteFile(io, stale) catch {};
    }

    // `--no-autoloader`: the tree is placed and recorded, and nothing is
    // generated. A caller that dumps for itself afterwards asks for this.
    if (opts.skip_autoloader) return summary;

    // The autoloader is regenerated from what was actually placed, using the
    // installed.json this run just wrote — the same path `hkm ppkg autoload`
    // takes, so an install and a later dump produce identical output.
    const installed = try manifest.readInstalled(allocator, io, vendor_dir);
    const plan = try autoload.plan(allocator, io, lay, declared, installed, .{
        .dev = opts.dev,
        .optimize = opts.optimize or cfg.optimizeAutoloader(),
        .suffix = cfg.autoloaderSuffix(),
    });
    _ = try scripts_mod.run(allocator, io, env, lay, .pre_autoload_dump, opts.scripts);
    try autoload.write(allocator, io, vendor_dir, plan);

    // The loader is written LAST, because only now is it known which
    // conditional blocks it needs: whether this project has `autoload.files`,
    // whether a platform check was written, whether any package declared an
    // include path. Copying a donor's loader and editing it afterwards is what
    // this replaces — see runtime.zig.
    summary.runtime = runtime.generate(allocator, io, vendor_dir, .{
        .suffix = plan.hash,
        .check_platform = check_platform,
        .has_files = plan.files.len > 0,
        .has_include_paths = plan.include_paths.len > 0,
        .classmap_authoritative = opts.classmap_authoritative or cfg.classmapAuthoritative(),
        .apcu_prefix = apcuPrefixOf(allocator, opts, cfg, lock.content_hash, root_dir),
        .use_include_path = cfg.useIncludePath(),
        .prepend = cfg.prependAutoloader(),
    });
    if (summary.runtime == .failed) runtime.reportFailure();

    // Both fire after the tree is complete. A non-zero exit is reported through
    // the summary rather than thrown away: a failed `post-install-cmd` means
    // the project is not ready, even though every package is in place.
    const dumped = try scripts_mod.run(allocator, io, env, lay, .post_autoload_dump, opts.scripts);
    const post = try scripts_mod.run(allocator, io, env, lay, .post_install_cmd, opts.scripts);
    if (summary.exit_code == 0) summary.exit_code = if (dumped != 0) dumped else post;

    return summary;
}

/// Put one package where it belongs.
fn place(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    root_dir: []const u8,
    vendor_dir: []const u8,
    cache_dir: []const u8,
    pkg: lockfile.Package,
    dest: []const u8,
    opts: Options,
    table: stamps.Table,
    summary: *Summary,
) Placement {
    // A path repository is a link to a directory in this project, not a
    // download — see archive.linkTo for why it must stay a link.
    if (pkg.dist.kind == .path) {
        if (opts.dry_run) return .linked;
        const target = std.fs.path.join(allocator, &.{ root_dir, pkg.dist.url }) catch return .failed;
        archive.linkTo(allocator, io, dest, target, vendor_dir) catch return .failed;
        return .linked;
    }

    // Which of the two forms to take. A package usually publishes both, and
    // the choice is the operator's: `preferred-install` in config, or
    // `--prefer-source` / `--prefer-dist` for one run.
    //
    // What "source" means here is a tree built from the repository at the
    // locked reference rather than from a published archive. It is NOT a
    // working copy: no `.git` is left behind, because a vendor directory with
    // live VCS metadata in it is a tree that `git status` reports on and that
    // a deployment can silently carry uncommitted changes through. A caller
    // who wants a checkout to hack on wants `git clone`, not an install.
    const want_source = opts.prefer == .source or
        (opts.prefer == null and opts.preference(pkg.name) == .source);

    if (want_source and pkg.source.installable() and pkg.dist.kind != .path) {
        if (!opts.force and alreadyInstalled(io, table, dest, pkg)) return .reused;
        if (opts.dry_run) return .installed;
        return placeFromSource(allocator, io, env, cache_dir, pkg, dest, true);
    }

    // No dist at all, but a git source: the package's repository publishes no
    // downloadable archive, which is what every non-GitHub `vcs` repository and
    // most `package` repositories look like. Composer installs these from a
    // clone; this builds the same tree with `git archive` off a bare mirror, so
    // no `.git` lands in vendor and the bytes go through the same extractor —
    // and the same traversal checks — as a downloaded one.
    if (pkg.dist.kind == .none and pkg.source.installable()) {
        if (!opts.force and alreadyInstalled(io, table, dest, pkg)) return .reused;
        if (opts.dry_run) return .installed;
        return placeFromSource(allocator, io, env, cache_dir, pkg, dest, false);
    }

    if (pkg.dist.kind != .zip and pkg.dist.kind != .tar) {
        prompt.warn(std.fmt.allocPrint(
            allocator,
            "{s}: the lock records neither a zip/tar distribution nor a git source",
            .{pkg.name},
        ) catch pkg.name);
        return .failed;
    }

    if (!opts.force and alreadyInstalled(io, table, dest, pkg)) return .reused;
    if (opts.dry_run) return .installed;

    // A local file — an `artifact` repository's zip, or one a `package`
    // repository points at by path. Nothing to download; unpack it where it is.
    if (localDist(pkg.dist.url)) |local| {
        const path = if (std.fs.path.isAbsolute(local))
            local
        else
            std.fs.path.join(allocator, &.{ root_dir, local }) catch return .failed;
        archive.unpackTo(allocator, io, path, dest) catch {
            prompt.warn(std.fmt.allocPrint(allocator, "{s}: could not be unpacked", .{pkg.name}) catch pkg.name);
            return .failed;
        };
        return .installed;
    }

    const key = if (pkg.dist.reference.len > 0) pkg.dist.reference else pkg.version;
    const got = fetch.intoCache(allocator, io, cache_dir, pkg.dist.url, key, pkg.dist.shasum) catch |e| {
        // Each of these is a different problem with a different fix, and
        // "download failed" for all three sends the reader to check their
        // network when the answer is a policy flag or a corrupted mirror.
        prompt.warn(std.fmt.allocPrint(allocator, "{s}: {s}", .{ pkg.name, switch (e) {
            error.NoChecksum => "the lock records no checksum for this dist, and --require-checksums was given",
            error.ChecksumMismatch => "the downloaded archive does not match the checksum in the lock",
            else => "download failed",
        } }) catch pkg.name);
        return .failed;
    };
    if (got.cached) summary.cached += 1;
    // Counted here as well as in the prefetch, for the packages that reach
    // placement without having gone through it — a single-package `reinstall`,
    // or anything the prefetch skipped.
    if (got.unverified) summary.unverified += 1;

    archive.unpackTo(allocator, io, got.path, dest) catch {
        prompt.warn(std.fmt.allocPrint(allocator, "{s}: could not be unpacked", .{pkg.name}) catch pkg.name);
        return .failed;
    };
    return .installed;
}

/// The Mercurial half of `placeFromSource`.
///
/// Same shape as git's — clone once into the cache, `hg archive` the changeset
/// into the same content-addressed store the downloads use, unpack — so a
/// re-install of the same reference costs no `hg` at all.
fn placeFromHg(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    pkg: lockfile.Package,
    dest: []const u8,
) Placement {
    const clone = hg.mirror(allocator, io, env, cache_dir, pkg.source.url) catch {
        prompt.warn(std.fmt.allocPrint(
            allocator,
            "{s}: could not clone {s}",
            .{ pkg.name, pkg.source.url },
        ) catch pkg.name);
        return .failed;
    };

    const archive_path = cachedArchivePath(allocator, cache_dir, pkg.source.reference) catch return .failed;
    if (!util.fileExists(io, archive_path)) {
        hg.archiveAt(allocator, io, env, clone, pkg.source.reference, archive_path) catch {
            prompt.warn(std.fmt.allocPrint(
                allocator,
                "{s}: {s} is not in the clone of {s}",
                .{ pkg.name, pkg.source.reference, pkg.source.url },
            ) catch pkg.name);
            return .failed;
        };
    }

    archive.unpackTo(allocator, io, archive_path, dest) catch {
        prompt.warn(std.fmt.allocPrint(allocator, "{s}: could not be unpacked", .{pkg.name}) catch pkg.name);
        return .failed;
    };

    // `hg archive` writes a `.hg_archival.txt` describing the archive itself.
    // It is Mercurial's metadata, not the package's — Composer's source install
    // has no such file — and leaving it would put a stray untracked file in
    // every vendor directory that came from a Mercurial repository.
    if (std.fs.path.join(allocator, &.{ dest, ".hg_archival.txt" }) catch null) |stray| {
        Dir.cwd().deleteFile(io, stray) catch {};
    }
    return .installed;
}

/// Where a source-built archive is cached, keyed by the reference.
fn cachedArchivePath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    reference: []const u8,
) ![]const u8 {
    const shard = if (reference.len >= 2) reference[0..2] else "00";
    return std.fs.path.join(allocator, &.{
        cache_dir,
        shard,
        try std.fmt.allocPrint(allocator, "{s}.zip", .{reference}),
    });
}

/// A dist URL that names a file on this machine rather than something to fetch.
fn localDist(url: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, url, "file://")) return url["file://".len..];
    if (std.mem.indexOf(u8, url, "://") != null) return null;
    if (url.len == 0) return null;
    return url;
}

fn placeFromSource(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    pkg: lockfile.Package,
    dest: []const u8,
    /// Leave a working copy with its VCS metadata, rather than an export.
    ///
    /// True when the operator ASKED for a source install — that is what the
    /// request means. False when this is merely the only way to obtain the
    /// package (a `vcs` repository that publishes no archive), where an export
    /// is the smaller, cleaner tree and nothing was promised about `.git`.
    working_copy: bool,
) Placement {
    // Subversion has no archive verb and no local clone to make one from, so
    // it exports straight into place. `export` rather than `checkout` is what
    // keeps a `.svn` directory out of the vendor tree.
    if (pkg.source.isSvn()) {
        svn.exportTo(allocator, io, env, pkg.source.url, pkg.source.reference, dest) catch {
            prompt.warn(std.fmt.allocPrint(
                allocator,
                "{s}: {s} could not be exported from {s}",
                .{ pkg.name, pkg.source.reference, pkg.source.url },
            ) catch pkg.name);
            return .failed;
        };
        return .installed;
    }

    if (pkg.source.isHg()) return placeFromHg(allocator, io, env, cache_dir, pkg, dest);

    const mirror = git.mirror(allocator, io, env, cache_dir, pkg.source.url) catch {
        prompt.warn(std.fmt.allocPrint(
            allocator,
            "{s}: could not mirror {s}",
            .{ pkg.name, pkg.source.url },
        ) catch pkg.name);
        return .failed;
    };

    if (working_copy) {
        git.cloneWorkingCopy(allocator, io, env, mirror, pkg.source.url, pkg.source.reference, dest) catch {
            prompt.warn(std.fmt.allocPrint(
                allocator,
                "{s}: {s} could not be checked out from {s}",
                .{ pkg.name, pkg.source.reference, pkg.source.url },
            ) catch pkg.name);
            return .failed;
        };
        return .installed;
    }

    // Into the same content-addressed cache the downloads use, keyed by the
    // commit, so re-installing the same reference costs no git at all.
    const archive_path = cachedArchivePath(allocator, cache_dir, pkg.source.reference) catch return .failed;

    if (!util.fileExists(io, archive_path)) {
        git.archiveAt(allocator, io, env, mirror, pkg.source.reference, archive_path) catch {
            prompt.warn(std.fmt.allocPrint(
                allocator,
                "{s}: {s} is not in the mirror of {s}",
                .{ pkg.name, pkg.source.reference, pkg.source.url },
            ) catch pkg.name);
            return .failed;
        };
    }

    archive.unpackTo(allocator, io, archive_path, dest) catch {
        prompt.warn(std.fmt.allocPrint(allocator, "{s}: could not be unpacked", .{pkg.name}) catch pkg.name);
        return .failed;
    };
    return .installed;
}

/// Download every archive this install still needs, in parallel.
///
/// Returns the number of bytes actually transferred. Packages already unpacked
/// at the locked reference are excluded, so a re-run of a current tree makes no
/// requests at all.
fn prefetchAll(
    allocator: std.mem.Allocator,
    io: Io,
    env: *EnvMap,
    cache_dir: []const u8,
    packages: []const lockfile.Package,
) !usize {
    var wants: std.ArrayList(fetch.Want) = .empty;
    for (packages) |pkg| {
        if (pkg.dist.kind != .zip and pkg.dist.kind != .tar) continue;
        if (pkg.dist.url.len == 0) continue;
        // A file already on this machine, and a source-only package, are both
        // placed without a request; queueing them would spend a worker slot on
        // a download that cannot happen.
        if (localDist(pkg.dist.url) != null) continue;
        try wants.append(allocator, .{
            .url = pkg.dist.url,
            .key = if (pkg.dist.reference.len > 0) pkg.dist.reference else pkg.version,
            .sha1 = pkg.dist.shasum,
        });
    }
    if (wants.items.len == 0) return 0;

    return fetch.prefetch(allocator, io, cache_dir, wants.items, fetch.workerCount(env), reportFetch);
}

/// Progress from a worker thread.
///
/// Deliberately terse and count-only: several threads call this at once, and a
/// line naming the package would interleave with the others mid-word.
fn reportFetch(done: usize, total: usize, url: []const u8) void {
    _ = url;
    if (done == total or done % 10 == 0) {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  fetched {d}/{d}", .{ done, total }) catch return;
        prompt.muted(line);
    }
}

/// Is the right version already in place?
///
/// Judged on the reference recorded in the PREVIOUS install, not on the
/// directory merely existing: a package left over from a different lock is
/// present and wrong, which is the case a bare `dirExists` check gets backwards.
fn alreadyInstalled(io: Io, table: stamps.Table, dest: []const u8, pkg: lockfile.Package) bool {
    if (!util.dirExists(Dir.cwd(), io, dest)) return false;
    return table.holds(pkg.name, effectiveReference(pkg));
}

/// The commit this package's directory should be holding.
///
/// The reference `installed.php` records, or null when there is none.
///
/// Deliberately NOT `effectiveReference`: that one falls back to the artifact
/// shasum so a replaced file is noticed, and the shasum is this package's own
/// bookkeeping — writing it into `installed.php` would report a checksum where
/// every reader expects a commit.
fn recordedReference(pkg: lockfile.Package) ?[]const u8 {
    if (pkg.dist.reference.len > 0) return pkg.dist.reference;
    if (pkg.source.reference.len > 0) return pkg.source.reference;
    return null;
}

/// Which of the two ways a package reached the disk.
///
/// Reported from what this run actually DID, not from what the lock offers: an
/// install that took the source path and then recorded `dist` describes a tree
/// that is not there, and `installed.json` is the file every other tool reads
/// to find out what is.
fn installationSourceOf(pkg: lockfile.Package, prefer: ?settings.Preference, cfg: ?settings.Settings) []const u8 {
    if (prefer == .source) return "source";
    if (prefer == null) {
        if (cfg) |c| {
            if (c.preferredInstall(pkg.name) == .source and pkg.source.installable()) return "source";
        }
    }
    if (pkg.dist.kind == .none and pkg.source.installable()) return "source";
    return "dist";
}

/// The dist reference when there is a dist, the source reference when there is
/// not. Without the fallback a source-installed package has no stamp, so every
/// run re-runs `git archive` for a tree that is already correct.
fn effectiveReference(pkg: lockfile.Package) []const u8 {
    if (pkg.dist.reference.len > 0) return pkg.dist.reference;
    if (pkg.source.reference.len > 0) return pkg.source.reference;
    // An artifact has neither — Composer records no reference for one — but it
    // does record a sha1, and that is exactly the "has this file changed"
    // question the stamp asks. Without it every install re-extracts every
    // artifact.
    return pkg.dist.shasum;
}

/// Is this package's placement worth recording?
///
/// A path repository is not: its directory is a SYMLINK into the user's own
/// source tree, which they edit — there is no reference for it to hold, and
/// `alreadyInstalled` is never consulted for one.
fn stampable(kind: lockfile.DistType) bool {
    return kind != .path;
}

// ── installed metadata ────────────────────────────────────────────────────────

/// Write `vendor/composer/installed.json` and `installed.php`.
fn writeInstalled(
    allocator: std.mem.Allocator,
    io: Io,
    lay: layout.Layout,
    rules: []const installers.Rule,
    packages: []const lockfile.Package,
    dev: bool,
    opts: Options,
) !void {
    const vendor_dir = lay.vendor;
    const composer_dir = try std.fs.path.join(allocator, &.{ vendor_dir, "composer" });
    try Dir.cwd().createDirPath(io, composer_dir);

    try util.writeFileAtomic(
        io,
        try std.fs.path.join(allocator, &.{ composer_dir, "installed.json" }),
        try renderInstalledJson(allocator, lay, rules, packages, dev, opts),
    );
    try util.writeFileAtomic(
        io,
        try std.fs.path.join(allocator, &.{ composer_dir, "installed.php" }),
        try renderInstalledPhp(allocator, io, lay, rules, packages, dev),
    );
}

/// Write `<vendor>/composer/platform_check.php` from what was actually placed.
///
/// Generated rather than copied — see `platformcheck.zig` and `runtime.zig`.
/// Written even when there is nothing to check, because `autoload_real.php`
/// comes from a donor tree with the `require` line already in it: an absent
/// file would be a fatal error on every request, and a file that checks nothing
/// is exactly what a project with no platform requirements asked for.
fn writePlatformCheck(
    allocator: std.mem.Allocator,
    io: Io,
    lay: layout.Layout,
    declared: manifest.Manifest,
    packages: []const lockfile.Package,
) !void {
    var list: std.ArrayList(platformcheck.Package) = .empty;
    // The ROOT package is part of the check too: its own `"php": "^8.2"` is
    // usually the highest floor in the tree and the one the operator wrote.
    try list.append(allocator, .{
        .name = declared.name,
        .requires = declared.require,
        .provides = declared.provide,
        .replaces = declared.replace,
    });
    for (packages) |pkg| {
        if (pkg.raw != .object) continue;
        const m = manifest.fromObject(allocator, pkg.raw.object) catch continue;
        try list.append(allocator, .{
            .name = pkg.name,
            .requires = m.require,
            .provides = m.provide,
            .replaces = m.replace,
            .dev = pkg.dev,
        });
    }

    const mode = platformcheck.Mode.fromConfig(declared.config_platform_check);
    const path = try std.fs.path.join(allocator, &.{ lay.vendor, "composer", "platform_check.php" });

    // Nothing to check: Composer unlinks the file and drops the `require` from
    // `autoload_real.php`. `runtime.alignAutoloadReal` does the second half —
    // the two have to move together, or the tree fatals on a missing file.
    const body = (try platformcheck.render(allocator, list.items, mode)) orelse {
        Dir.cwd().deleteFile(io, path) catch {};
        return;
    };

    try util.writeFileAtomic(io, path, body);
}

/// Does this project have anything for `platform_check.php` to check?
/// The APCu prefix to bake into `autoload_real.php`, or null for no APCu.
///
/// Composer invents `bin2hex(random_bytes(10))` when APCu is on and no prefix
/// is configured. That is a fresh value on every dump, so `autoload_real.php`
/// changes on every run of a command that changed nothing — which defeats
/// `filePutContentsIfModified`, busts opcache, and shows up as a dirty file in
/// any deployment that diffs the tree.
///
/// The lock's content-hash is used instead: unique per project, stable across
/// runs of the same project, and different for two projects sharing an APCu
/// instance, which is the property the prefix exists for.
fn apcuPrefixOf(
    allocator: std.mem.Allocator,
    opts: Options,
    cfg: settings.Settings,
    content_hash: []const u8,
    root_dir: []const u8,
) ?[]const u8 {
    if (!opts.apcu and !cfg.apcuAutoloader()) return null;
    if (opts.apcu_prefix) |p| return p;
    if (cfg.apcuPrefix()) |p| return p;
    if (content_hash.len > 0) return content_hash;

    // No lock to derive from. The project's own path is the fallback: a fixed
    // string would collide between two projects sharing an APCu instance,
    // which is the one thing the prefix must not do.
    var digest: [16]u8 = undefined;
    var h = std.crypto.hash.Md5.init(.{});
    h.update(root_dir);
    h.final(&digest);
    return std.fmt.allocPrint(allocator, "{x}", .{&digest}) catch null;
}

fn checksPlatform(
    allocator: std.mem.Allocator,
    declared: manifest.Manifest,
    packages: []const lockfile.Package,
) bool {
    var list: std.ArrayList(platformcheck.Package) = .empty;
    list.append(allocator, .{
        .name = declared.name,
        .requires = declared.require,
        .provides = declared.provide,
        .replaces = declared.replace,
    }) catch return true;
    for (packages) |pkg| {
        if (pkg.raw != .object) continue;
        const m = manifest.fromObject(allocator, pkg.raw.object) catch continue;
        list.append(allocator, .{
            .name = pkg.name,
            .requires = m.require,
            .provides = m.provide,
            .replaces = m.replace,
            .dev = pkg.dev,
        }) catch return true;
    }
    const mode = platformcheck.Mode.fromConfig(declared.config_platform_check);
    const rendered = platformcheck.render(allocator, list.items, mode) catch return true;
    return rendered != null;
}

/// `installed.json` is the lock's package objects with three keys added.
///
/// Re-emitted from the ORIGINAL json value rather than from a struct, so every
/// field this tool does not model — authors, funding, support, extra — survives
/// into the installed metadata instead of being quietly dropped.
fn renderInstalledJson(
    allocator: std.mem.Allocator,
    lay: layout.Layout,
    rules: []const installers.Rule,
    packages: []const lockfile.Package,
    dev: bool,
    opts: Options,
) ![]const u8 {
    var pkg_items: std.ArrayList(std.json.Value) = .empty;
    var dev_names: std.ArrayList(std.json.Value) = .empty;

    for (packages) |pkg| {
        // The three keys the INSTALLER knows and the metadata does not. They go
        // through canonicaliseInstalled rather than being appended, because
        // Composer places them in the dumper's own sequence — `install-path`
        // last, but `version_normalized` third and `installation-source` in the
        // middle.
        const extras = [_]lockwrite.Extra{
            .{ .key = "version_normalized", .value = try lockfile.normalizeVersion(allocator, pkg.version) },
            // `source` when the package came from a clone, `dist` otherwise —
            // Composer records which one it actually used, and `installed.json`
            // is read back by tooling that reinstalls from it.
            .{ .key = "installation-source", .value = installationSourceOf(pkg, opts.prefer, opts.config_preference) },
            .{ .key = "install-path", .value = try installPathFor(allocator, lay, rules, pkg) },
        };
        const obj = try lockwrite.canonicaliseInstalled(allocator, pkg.raw, &extras);
        try pkg_items.append(allocator, .{ .object = obj });

        if (pkg.dev) try dev_names.append(allocator, .{ .string = pkg.name });
    }

    var root: std.json.ObjectMap = .empty;
    try root.put(allocator, "packages", .{ .array = .fromOwnedSlice(allocator, try pkg_items.toOwnedSlice(allocator)) });
    try root.put(allocator, "dev", .{ .bool = dev });
    try root.put(allocator, "dev-package-names", .{ .array = .fromOwnedSlice(allocator, try dev_names.toOwnedSlice(allocator)) });

    var out: std.ArrayList(u8) = .empty;
    try phpjson.encode(allocator, &out, .{ .object = root }, .{
        .escape_slashes = false,
        .escape_unicode = false,
        .pretty = true,
    });
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Where a package sits relative to `vendor/composer/`, the way Composer spells
/// it: `../guzzlehttp/guzzle`.
///
/// A PATH repository is no exception, which is easy to get wrong: it is
/// installed as a SYMLINK at `vendor/<name>`, and Composer records the link —
/// not the directory it points at. Recording the real location instead
/// (`../../modules/php-io-cli`) makes every generated autoload path for that
/// package resolve from inside `vendor/`, and its `files` bootstraps then fail
/// to open on the very first require.
/// `extra.installer-paths`, read from the project's own composer.json.
///
/// Read from the RAW json rather than from the parsed manifest because
/// `extra` is an arbitrary object that belongs to whichever tool declared it —
/// there is nothing for the manifest parser to usefully model.
fn installerRules(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) ![]const installers.Rule {
    const path = try std.fs.path.join(allocator, &.{ root_dir, "composer.json" });
    const body = Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch return &.{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return &.{};
    return installers.rulesOf(allocator, parsed);
}

/// Where a package's directory is, absolute.
fn destinationOf(
    allocator: std.mem.Allocator,
    lay: layout.Layout,
    rules: []const installers.Rule,
    pkg: lockfile.Package,
) ![]const u8 {
    if (rules.len > 0) {
        if (try installers.pathFor(allocator, rules, pkg.name, pkg.kind)) |custom| {
            // Relative to the PROJECT root, not to vendor: that is what the
            // declaration means, and it is how a package lands in `web/app/`.
            return std.fs.path.join(allocator, &.{ lay.root, custom });
        }
    }
    return std.fs.path.join(allocator, &.{ lay.vendor, pkg.name });
}

/// The `install-path` recorded in installed.json: relative to `vendor/composer`.
fn installPathFor(
    allocator: std.mem.Allocator,
    lay: layout.Layout,
    rules: []const installers.Rule,
    pkg: lockfile.Package,
) ![]const u8 {
    if (rules.len > 0) {
        if (try installers.pathFor(allocator, rules, pkg.name, pkg.kind)) |custom| {
            const from = try std.fs.path.join(allocator, &.{ lay.vendor, "composer" });
            const to = try std.fs.path.join(allocator, &.{ lay.root, custom });
            return layout.shortestPath(allocator, from, to, true);
        }
    }
    // `findShortestPath`, not a hardcoded `../<name>`. They agree for almost
    // every package and disagree for the ones under `vendor/composer/` —
    // `composer/installers` is recorded by Composer as `./installers`, and
    // `../composer/installers` resolves to the same directory while not being
    // the same string.
    return layout.shortestPath(
        allocator,
        try std.fs.path.join(allocator, &.{ lay.vendor, "composer" }),
        try std.fs.path.join(allocator, &.{ lay.vendor, pkg.name }),
        true,
    );
}

const Extra = struct { key: []const u8, value: []const u8 };

/// Emit a json object, appending `extra` string keys that are not already in it.
fn writeObject(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
    extra: []const Extra,
    depth: usize,
) !void {
    if (value != .object) return writeValue(allocator, out, value, depth);

    try indent(allocator, out, depth);
    try out.appendSlice(allocator, "{\n");

    var it = value.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try out.appendSlice(allocator, ",\n");
        first = false;
        try indent(allocator, out, depth + 1);
        try writeJsonString(allocator, out, entry.key_ptr.*);
        try out.appendSlice(allocator, ": ");
        try writeValueInline(allocator, out, entry.value_ptr.*, depth + 1);
    }

    for (extra) |e| {
        if (value.object.get(e.key) != null) continue;
        if (!first) try out.appendSlice(allocator, ",\n");
        first = false;
        try indent(allocator, out, depth + 1);
        try writeJsonString(allocator, out, e.key);
        try out.appendSlice(allocator, ": ");
        try writeJsonString(allocator, out, e.value);
    }

    try out.appendSlice(allocator, "\n");
    try indent(allocator, out, depth);
    try out.appendSlice(allocator, "}");
}

fn writeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value, depth: usize) !void {
    try indent(allocator, out, depth);
    try writeValueInline(allocator, out, value, depth);
}

fn writeValueInline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
    depth: usize,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try writeJsonString(allocator, out, s),
        .array => |a| {
            if (a.items.len == 0) return out.appendSlice(allocator, "[]");
            try out.appendSlice(allocator, "[\n");
            for (a.items, 0..) |item, i| {
                try indent(allocator, out, depth + 1);
                try writeValueInline(allocator, out, item, depth + 1);
                if (i + 1 < a.items.len) try out.appendSlice(allocator, ",");
                try out.appendSlice(allocator, "\n");
            }
            try indent(allocator, out, depth);
            try out.appendSlice(allocator, "]");
        },
        .object => |o| {
            if (o.count() == 0) return out.appendSlice(allocator, "{}");
            try out.appendSlice(allocator, "{\n");
            var it = o.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ",\n");
                first = false;
                try indent(allocator, out, depth + 1);
                try writeJsonString(allocator, out, entry.key_ptr.*);
                try out.appendSlice(allocator, ": ");
                try writeValueInline(allocator, out, entry.value_ptr.*, depth + 1);
            }
            try out.appendSlice(allocator, "\n");
            try indent(allocator, out, depth);
            try out.appendSlice(allocator, "}");
        },
    }
}

fn indent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "    ");
}

fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => {
            if (c < 0x20) {
                try out.print(allocator, "\\u{x:0>4}", .{c});
            } else {
                try out.append(allocator, c);
            }
        },
    };
    try out.append(allocator, '"');
}

/// `installed.php` — the array `Composer\InstalledVersions` reads.
fn renderInstalledPhp(
    allocator: std.mem.Allocator,
    io: Io,
    lay: layout.Layout,
    rules: []const installers.Rule,
    packages: []const lockfile.Package,
    dev: bool,
) ![]const u8 {
    const root = try rootPackageInfo(allocator, io, lay.root);
    // The root package's `install_path` reaches from `<vendor>/composer` back
    // to the project. `../../` only for the default layout — `lib/vendor` makes
    // it `../../../`, and FilesystemRepository computes it rather than
    // assuming, so this does too.
    const root_install = try layout.shortestPath(
        allocator,
        try std.fs.path.join(allocator, &.{ lay.vendor, "composer" }),
        lay.root,
        true,
    );

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "<?php return array(\n    'root' => array(\n");
    try phpPair(allocator, &out, 2, "name", root.name);
    try phpPair(allocator, &out, 2, "pretty_version", root.pretty_version);
    try phpPair(allocator, &out, 2, "version", root.version);
    try phpNullablePair(allocator, &out, 2, "reference", root.reference);
    try phpPair(allocator, &out, 2, "type", root.kind);
    try out.print(allocator, "        'install_path' => __DIR__ . '/{s}',\n", .{root_install});
    try out.appendSlice(allocator, "        'aliases' => array(),\n");
    try out.print(allocator, "        'dev' => {s},\n", .{if (dev) "true" else "false"});
    try out.appendSlice(allocator, "    ),\n    'versions' => array(\n");

    // Virtual packages — every `provide` and `replace` target that is not itself
    // installed — get an entry of their own, so that
    // `InstalledVersions::isInstalled('psr/log-implementation')` is true when
    // something in the tree implements it. Composer builds these into the same
    // ksorted `versions` map, not a separate list.
    const virtuals = try virtualEntries(allocator, packages);

    // The ROOT package is listed in `versions` as well as in `root`, sorted in
    // among the dependencies by name. Without it `InstalledVersions::getVersion`
    // and `isInstalled` answer "not installed" for the application's own
    // package — which is what a project asking its own version at runtime does.
    var root_written = false;
    var next_virtual: usize = 0;
    for (packages) |pkg| {
        if (!root_written and std.mem.order(u8, root.name, pkg.name) == .lt) {
            try writeRootVersionEntry(allocator, &out, root, root_install);
            root_written = true;
        }
        while (next_virtual < virtuals.len and
            std.mem.order(u8, virtuals[next_virtual].name, pkg.name) == .lt) : (next_virtual += 1)
        {
            try writeVirtualEntry(allocator, &out, virtuals[next_virtual]);
        }
        try out.appendSlice(allocator, "        ");
        try phpString(allocator, &out, pkg.name);
        try out.appendSlice(allocator, " => array(\n");
        try phpPair(allocator, &out, 3, "pretty_version", pkg.version);
        try phpPair(allocator, &out, 3, "version", try lockfile.normalizeVersion(allocator, pkg.version));
        // The dist reference, or the source's when there is no dist, or PHP
        // `null` when the package has neither — an artifact repository records
        // no reference at all, and Composer writes `null` there. `''` is a
        // DIFFERENT value to code that tests `=== null` to mean "not from a
        // VCS", which is what `InstalledVersions::getReference()` is for.
        try phpNullablePair(allocator, &out, 3, "reference", recordedReference(pkg));
        try phpPair(allocator, &out, 3, "type", pkg.kind);
        try out.appendSlice(allocator, "            'install_path' => __DIR__ . '/");
        try out.appendSlice(allocator, try installPathFor(allocator, lay, rules, pkg));
        try out.appendSlice(allocator, "',\n");
        try writeAliases(allocator, &out, pkg);
        try out.print(allocator, "            'dev_requirement' => {s},\n", .{if (pkg.dev) "true" else "false"});
        try out.appendSlice(allocator, "        ),\n");
    }

    if (!root_written) try writeRootVersionEntry(allocator, &out, root, root_install);
    while (next_virtual < virtuals.len) : (next_virtual += 1) {
        try writeVirtualEntry(allocator, &out, virtuals[next_virtual]);
    }
    try out.appendSlice(allocator, "    ),\n);\n");
    return out.toOwnedSlice(allocator);
}

/// A `provide` / `replace` target that no installed package claims as its own.
const Virtual = struct {
    name: []const u8,
    /// Constraints, de-duplicated and naturally sorted.
    constraints: []const []const u8,
    /// The key Composer writes them under.
    key: []const u8,
    /// False as soon as ONE non-dev package provides it.
    dev_requirement: bool,
};

/// Collect the virtual packages an installed set implies.
///
/// Platform targets are skipped: `symfony/polyfill-ctype` provides `ext-ctype`,
/// and Composer does not record extensions in `versions` — the platform
/// repository answers for those.
fn virtualEntries(
    allocator: std.mem.Allocator,
    packages: []const lockfile.Package,
) ![]const Virtual {
    var out: std.ArrayList(Virtual) = .empty;

    for ([_][]const u8{ "replace", "provide" }) |relation| {
        const key = if (std.mem.eql(u8, relation, "replace")) "replaced" else "provided";

        for (packages) |pkg| {
            const section = objectField(pkg.raw, relation) orelse continue;
            var it = section.iterator();
            while (it.next()) |e| {
                const target = e.key_ptr.*;
                if (isPlatformName(target)) continue;
                // A real installed package of that name owns the entry.
                if (installedNamed(packages, target)) continue;

                const raw = switch (e.value_ptr.*) {
                    .string => |v| v,
                    else => continue,
                };
                const value = if (std.mem.eql(u8, raw, "self.version")) pkg.version else raw;

                var found = false;
                for (out.items) |*v| {
                    if (!std.mem.eql(u8, v.name, target)) continue;
                    found = true;
                    if (!pkg.dev) v.dev_requirement = false;
                    if (!util.contains(v.constraints, value)) {
                        const grown = try allocator.alloc([]const u8, v.constraints.len + 1);
                        @memcpy(grown[0..v.constraints.len], v.constraints);
                        grown[v.constraints.len] = value;
                        v.constraints = grown;
                    }
                    break;
                }
                if (!found) {
                    const one = try allocator.alloc([]const u8, 1);
                    one[0] = value;
                    try out.append(allocator, .{
                        .name = target,
                        .constraints = one,
                        .key = key,
                        .dev_requirement = pkg.dev,
                    });
                }
            }
        }
    }

    for (out.items) |*v| {
        const items = @constCast(v.constraints);
        std.mem.sort([]const u8, items, {}, naturalLess);
    }
    const items = try out.toOwnedSlice(allocator);
    std.mem.sort(Virtual, items, {}, virtualByName);
    return items;
}

fn naturalLess(_: void, a: []const u8, b: []const u8) bool {
    return autoload_mod.natCaseLess(a, b);
}

fn virtualByName(_: void, a: Virtual, b: Virtual) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn installedNamed(packages: []const lockfile.Package, name: []const u8) bool {
    for (packages) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

fn isPlatformName(name: []const u8) bool {
    return std.mem.eql(u8, name, "php") or
        std.mem.startsWith(u8, name, "php-") or
        std.mem.startsWith(u8, name, "ext-") or
        std.mem.startsWith(u8, name, "lib-") or
        std.mem.eql(u8, name, "hhvm") or
        std.mem.startsWith(u8, name, "composer");
}

fn objectField(raw: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (raw != .object) return null;
    const v = raw.object.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn writeVirtualEntry(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: Virtual) !void {
    try out.appendSlice(allocator, "        ");
    try phpString(allocator, out, v.name);
    try out.appendSlice(allocator, " => array(\n");
    try out.print(allocator, "            'dev_requirement' => {s},\n", .{if (v.dev_requirement) "true" else "false"});
    try out.appendSlice(allocator, "            '");
    try out.appendSlice(allocator, v.key);
    try out.appendSlice(allocator, "' => array(\n");
    for (v.constraints, 0..) |c, i| {
        try out.print(allocator, "                {d} => ", .{i});
        try phpString(allocator, out, c);
        try out.appendSlice(allocator, ",\n");
    }
    try out.appendSlice(allocator, "            ),\n        ),\n");
}

/// The root package's own entry in the `versions` map.
///
/// Identical in shape to a dependency's, with `dev_requirement => false` and
/// the install path pointing back at the project root. It is not a duplicate of
/// the `root` block: `InstalledVersions::getVersion($name)` reads `versions`
/// and nothing else, so without this the application cannot ask its own
/// version at runtime.
fn writeRootVersionEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    root: RootInfo,
    install_path: []const u8,
) !void {
    try out.appendSlice(allocator, "        ");
    try phpString(allocator, out, root.name);
    try out.appendSlice(allocator, " => array(\n");
    try phpPair(allocator, out, 3, "pretty_version", root.pretty_version);
    try phpPair(allocator, out, 3, "version", root.version);
    try phpNullablePair(allocator, out, 3, "reference", root.reference);
    try phpPair(allocator, out, 3, "type", root.kind);
    try out.print(allocator, "            'install_path' => __DIR__ . '/{s}',\n", .{install_path});
    try out.appendSlice(allocator, "            'aliases' => array(),\n");
    try out.appendSlice(allocator, "            'dev_requirement' => false,\n");
    try out.appendSlice(allocator, "        ),\n");
}

/// A dev branch that `extra.branch-alias` maps to a version gets that alias
/// recorded, so `InstalledVersions::satisfies('^1.0')` is true for `dev-master`
/// when the package says the branch IS 1.0.
fn writeAliases(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pkg: lockfile.Package) !void {
    const alias = branchAlias(pkg) orelse {
        try out.appendSlice(allocator, "            'aliases' => array(),\n");
        return;
    };
    try out.appendSlice(allocator, "            'aliases' => array(\n                0 => ");
    try phpString(allocator, out, alias);
    try out.appendSlice(allocator, ",\n            ),\n");
}

fn branchAlias(pkg: lockfile.Package) ?[]const u8 {
    if (pkg.raw != .object) return null;
    const extra = pkg.raw.object.get("extra") orelse return null;
    if (extra != .object) return null;
    const aliases = extra.object.get("branch-alias") orelse return null;
    if (aliases != .object) return null;
    const hit = aliases.object.get(pkg.version) orelse return null;
    return switch (hit) {
        .string => |s| s,
        else => null,
    };
}

const RootInfo = struct {
    name: []const u8 = "__root__",
    /// `RootPackage::DEFAULT_PRETTY_VERSION`.
    ///
    /// What Composer records when nothing can tell it a version: no `version`
    /// in composer.json and no VCS to guess from. The previous default here was
    /// `dev-main`, which claims a branch that may not exist — and a deployed
    /// tree has no `.git`, so that was the value most installs got.
    pretty_version: []const u8 = "1.0.0+no-version-set",
    version: []const u8 = "1.0.0.0",
    /// Composer writes `null`, not `""`, when there is no commit to record.
    reference: ?[]const u8 = null,
    kind: []const u8 = "library",
};

/// Describe the root package.
///
/// The branch and commit come from `.git`, read directly rather than by running
/// git: this is called during an install that is otherwise entirely offline and
/// process-free, and a missing `.git` is normal in a deployed tree.
fn rootPackageInfo(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) !RootInfo {
    var info: RootInfo = .{};

    if (try manifest.read(allocator, io, root_dir)) |m| {
        if (m.name.len > 0) info.name = m.name;
        if (m.kind.len > 0) info.kind = m.kind;

        // An explicit `version` in composer.json wins over anything the VCS
        // could say — it is the author stating the answer outright.
        if (m.version.len > 0) {
            info.pretty_version = m.version;
            info.version = lockfile.normalizeVersion(allocator, m.version) catch m.version;
            return info;
        }
    }

    const head_path = try std.fs.path.join(allocator, &.{ root_dir, ".git", "HEAD" });
    const head = Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096)) catch return info;
    const trimmed = std.mem.trim(u8, head, " \n\r\t");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref = trimmed[5..];
        const branch = std.fs.path.basename(ref);
        info.pretty_version = try std.fmt.allocPrint(allocator, "dev-{s}", .{branch});
        info.version = info.pretty_version;

        const ref_path = try std.fs.path.join(allocator, &.{ root_dir, ".git", ref });
        if (Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(256)) catch null) |sha| {
            info.reference = try allocator.dupe(u8, std.mem.trim(u8, sha, " \n\r\t"));
        }
    } else {
        // Detached HEAD: the file holds the commit itself.
        info.reference = try allocator.dupe(u8, trimmed);
    }

    return info;
}

/// A pair whose value may be PHP `null` rather than a string.
///
/// `installed.php` records `'reference' => NULL` for a root package with no
/// commit — an empty string there is a different value, and code that checks
/// `=== null` to mean "not from a VCS" reads it as a reference of "".
fn phpNullablePair(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    depth: usize,
    key: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |v| return phpPair(allocator, out, depth, key, v);

    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "    ");
    try phpString(allocator, out, key);
    try out.appendSlice(allocator, " => null,\n");
}

fn phpPair(allocator: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, key: []const u8, value: []const u8) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.appendSlice(allocator, "    ");
    try phpString(allocator, out, key);
    try out.appendSlice(allocator, " => ");
    try phpString(allocator, out, value);
    try out.appendSlice(allocator, ",\n");
}

fn phpString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\\' or c == '\'') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseValue(a: std.mem.Allocator, src: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, src, .{});
}

test "install paths are spelled relative to vendor/composer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zip = lockfile.Package{
        .name = "guzzlehttp/guzzle",
        .version = "7.9.2",
        .dist = .{ .kind = .zip },
        .raw = .null,
    };
    const lay: layout.Layout = .{ .root = "/p", .vendor = "/p/vendor", .bin = "/p/vendor/bin" };
    try testing.expectEqualStrings("../guzzlehttp/guzzle", try installPathFor(a, lay, &.{}, zip));

    // With an `extra.installer-paths` rule the path leaves vendor/ entirely,
    // and is spelled relative to vendor/composer all the same — this is the
    // value the generated autoloader resolves every psr-4 root against.
    const rules = [_]installers.Rule{.{ .path = "web/app/plugins/{$name}/", .criteria = &.{"type:wordpress-plugin"} }};
    const wp = lockfile.Package{
        .name = "wpackagist-plugin/akismet",
        .version = "5.3",
        .kind = "wordpress-plugin",
        .dist = .{ .kind = .zip },
        .raw = .null,
    };
    try testing.expectEqualStrings(
        "../../web/app/plugins/akismet",
        try installPathFor(a, lay, &rules, wp),
    );

    // A path repository is recorded at its SYMLINK inside vendor/, not at the
    // directory the link points to — matching what Composer writes, and what the
    // generated autoload paths must agree with.
    const path_pkg = lockfile.Package{
        .name = "alfacode-team/http",
        .version = "dev-master",
        .dist = .{ .kind = .path, .url = "modules/http" },
        .raw = .null,
    };
    try testing.expectEqualStrings("../alfacode-team/http", try installPathFor(a, lay, &.{}, path_pkg));
}

test "installed.json keeps fields the tool does not model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = try parseValue(a,
        \\{"name":"acme/lib","version":"1.2.3","funding":[{"type":"github","url":"https://x"}],
        \\ "authors":[{"name":"Someone"}]}
    );
    const pkgs = [_]lockfile.Package{.{
        .name = "acme/lib",
        .version = "1.2.3",
        .dist = .{ .kind = .zip },
        .raw = raw,
    }};

    const json = try renderInstalledJson(a, .{ .root = "/p", .vendor = "/p/vendor", .bin = "/p/vendor/bin" }, &.{}, &pkgs, true, .{});

    // Untouched passthrough of what the lock said.
    try testing.expect(std.mem.indexOf(u8, json, "\"funding\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"Someone\"") != null);
    // Added by the installer.
    try testing.expect(std.mem.indexOf(u8, json, "\"version_normalized\": \"1.2.3.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"install-path\": \"../acme/lib\"") != null);

    // And it must still be valid JSON.
    _ = try parseValue(a, json);
}

test "dev packages are listed in dev-package-names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pkgs = [_]lockfile.Package{
        .{ .name = "acme/runtime", .version = "1.0.0", .dist = .{ .kind = .zip }, .raw = .null },
        .{ .name = "acme/tests", .version = "2.0.0", .dev = true, .dist = .{ .kind = .zip }, .raw = .null },
    };
    const json = try renderInstalledJson(a, .{ .root = "/p", .vendor = "/p/vendor", .bin = "/p/vendor/bin" }, &.{}, &pkgs, true, .{});
    const at = std.mem.indexOf(u8, json, "dev-package-names").?;
    const tail = json[at..];

    try testing.expect(std.mem.indexOf(u8, tail, "\"acme/tests\"") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "\"acme/runtime\"") == null);
    _ = try parseValue(a, json);
}

test "a branch alias is recorded so version constraints can match a dev branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = try parseValue(a,
        \\{"name":"acme/lib","extra":{"branch-alias":{"dev-master":"1.0.x-dev"}}}
    );
    const pkg = lockfile.Package{ .name = "acme/lib", .version = "dev-master", .raw = raw };
    try testing.expectEqualStrings("1.0.x-dev", branchAlias(pkg).?);

    var out: std.ArrayList(u8) = .empty;
    try writeAliases(a, &out, pkg);
    try testing.expect(std.mem.indexOf(u8, out.items, "0 => '1.0.x-dev'") != null);
}

test "a package with no branch alias gets an empty alias array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const pkg = lockfile.Package{ .name = "acme/lib", .version = "1.0.0", .raw = .null };
    try testing.expect(branchAlias(pkg) == null);

    var out: std.ArrayList(u8) = .empty;
    try writeAliases(arena.allocator(), &out, pkg);
    try testing.expectEqualStrings("            'aliases' => array(),\n", out.items);
}

test "php string literals escape quotes and backslashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList(u8) = .empty;
    try phpString(arena.allocator(), &out, "it's\\fine");
    try testing.expectEqualStrings("'it\\'s\\\\fine'", out.items);
}

test "a path repository is never stamped" {
    // `vendor/<name>` for a path repo is a SYMLINK into the user's own project,
    // and its contents are the user's to change — there is no reference for it
    // to hold, so recording one would only ever be wrong.
    try testing.expect(!stampable(.path));

    // Everything that was actually downloaded still gets one, or every install
    // re-extracts every package.
    try testing.expect(stampable(.zip));
    try testing.expect(stampable(.tar));
    try testing.expect(stampable(.none));
}
