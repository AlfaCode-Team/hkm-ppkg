//! hkm-pkg — a Composer-compatible package manager, in Zig.
//!
//! The public surface of this package. Everything a host needs is re-exported
//! here, so a consumer writes `@import("pkg").autoload` and never reaches into
//! a file path that this repository is free to rearrange.
//!
//! ## What it is
//!
//! An implementation of the parts of Composer that a build tool actually spends
//! its time in — reading manifests, resolving constraints, fetching and placing
//! packages, and generating the autoloader — verified against Composer's own
//! output rather than against a reading of its documentation:
//!
//!   * `autoload` generates all five files BYTE-IDENTICALLY to
//!     `composer dump-autoload`, with and without `-o`, including Composer's
//!     two different package walk orders and its `sortPackages` weighting.
//!   * `constraint` is checked differentially against `Composer\Semver\Semver`
//!     over a recorded corpus of 5881 (version, constraint, answer) rows.
//!
//! ## What it is not
//!
//! `solver` is a backtracking search with a most-constrained-first heuristic and
//! a step budget, not the CDCL SAT solver Composer runs. It reports `exhausted`
//! as an outcome distinct from `unsatisfiable`, because it can give up on a
//! problem that does have a solution — and reporting "impossible" when the
//! honest answer is "I stopped looking" is the one failure mode a resolver must
//! not have.
//!
//! It does not write `composer.lock`. It does not run `scripts`, verify platform
//! requirements, or model `replace` / `conflict` / `provide`.
//!
//! ## Output
//!
//! Nothing here prints unless a host installs a sink — see `report`.

const std = @import("std");

// ── reading what is declared ──────────────────────────────────────────────────

/// composer.json / installed.json: packages, autoload blocks, repositories.
pub const manifest = @import("manifest.zig");
/// composer.lock: the pinned set, and Composer's version normalisation.
pub const lock = @import("lock.zig");
/// Writing composer.lock, in Composer's exact key order and encoding.
pub const lockwrite = @import("lockwrite.zig");
/// composer.lock's `content-hash` — PHP's json_encode, reproduced byte for byte.
pub const contenthash = @import("contenthash.zig");
/// PHP's json_encode itself, in both the configurations Composer uses.
pub const phpjson = @import("phpjson.zig");
/// Editing composer.json in place — `require` / `remove` without reformatting.
pub const jsonedit = @import("jsonedit.zig");
/// Credentials — auth.json, COMPOSER_AUTH, and the config credential blocks.
pub const auth = @import("auth.zig");
/// `config` — the merged block, from the machine, the project and the environment.
pub const settings = @import("settings.zig");
/// `require` / `remove` — edit the manifest, re-lock, install, or undo.
pub const edit = @import("edit.zig");
/// `scripts` — the ROOT package's install-event commands, and nothing else's.
pub const scripts = @import("scripts.zig");
/// `config` and `init` — reading and writing composer.json itself.
pub const config = @import("config.zig");
/// `repository` — reading and editing the `repositories` list.
pub const repository = @import("repository.zig");
/// `audit` and `search` — packagist's advisory and index endpoints.
pub const advisory = @import("advisory.zig");
/// `status`, `bump`, `reinstall`, `exec`, `clear-cache`.
pub const maintain = @import("maintain.zig");
/// Where `vendor/` and `vendor/bin/` are, and the generated PHP that reaches
/// between them — `config.vendor-dir` / `config.bin-dir`.
pub const layout = @import("layout.zig");

// ── deciding what to install ──────────────────────────────────────────────────

/// Composer's constraint algebra — `^`, `~`, ranges, wildcards, stability.
pub const constraint = @import("constraint.zig");
/// The packagist.org v2 metadata client, including the minified diff format.
pub const packagist = @import("packagist.zig");
/// `git` itself — the bare mirror that makes a non-GitHub host readable.
pub const git = @import("git.zig");
/// Composer plugins: what is installed, and what does not run.
pub const plugins = @import("plugins.zig");
/// `extra.installer-paths` — placing a package outside `vendor/`.
pub const installers = @import("installers.zig");
/// `package` and `artifact` repositories — the two that need no server.
pub const repo = @import("repo.zig");
/// Mercurial repositories.
pub const hg = @import("hg.zig");
/// Subversion repositories.
pub const svn = @import("svn.zig");
/// `vcs` repositories, read without touching a rate-limited API.
pub const vcs = @import("vcs.zig");
/// Platform requirements — php, ext-*, lib-*, and config.platform overrides.
pub const platform = @import("platform.zig");
/// `vendor/composer/platform_check.php` — generated from what is installed.
pub const platformcheck = @import("platformcheck.zig");
/// Backtracking dependency resolution over a candidate pool.
pub const solver = @import("solver.zig");
/// Resolving a project on disk: path repositories, git branches, lock diffing.
pub const resolve = @import("resolve.zig");

// ── getting it onto disk ──────────────────────────────────────────────────────

/// HTTP with a content-addressed cache, and parallel prefetch.
pub const fetch = @import("fetch.zig");
/// `archive` — writing a package out as a tar or a zip.
pub const pack = @import("pack.zig");
/// Unpacking a dist archive, and symlinking a path repository.
pub const archive = @import("archive.zig");
/// Placing packages and writing installed.json / installed.php.
pub const install = @import("install.zig");
/// What each installed directory holds — kept in the cache, not in vendor/.
pub const stamps = @import("stamps.zig");
/// `vendor/bin/*` launcher proxies.
pub const bin = @import("bin.zig");
/// Composer's loader — generated, with its MIT source embedded.
pub const runtime = @import("runtime.zig");

// ── generating the autoloader ─────────────────────────────────────────────────

/// A PHP lexer that finds the classes, interfaces, traits and enums in a file.
pub const classmap = @import("classmap.zig");
/// `composer dump-autoload`, byte for byte.
pub const autoload = @import("autoload.zig");

// ── asking questions about a tree ─────────────────────────────────────────────

/// show / why / licenses / validate / outdated.
pub const inspect = @import("inspect.zig");
/// `create-project`, `global`, `browse`, `self-update`.
pub const project = @import("project.zig");
/// `diagnose` — is this machine, and this project, in a workable state.
pub const diagnose = @import("diagnose.zig");
/// What this package cannot do for a given project, said before it does it.
pub const compat = @import("compat.zig");

// ── host integration ──────────────────────────────────────────────────────────

/// The `ppkg` command line itself — what the standalone binary runs, and what
/// a host embedding the package as a subcommand calls.
pub const cli = @import("cli.zig");
/// Where progress output goes. Silent until a host calls `report.use`.
pub const report = @import("report.zig");
/// The small path and file helpers the above are built on.
pub const util = @import("util.zig");

test {
    // Pull every module into the test build. Zig only analyses what is
    // referenced, so without this a compile error in a file no test happens to
    // call is not a failure — it is silence.
    std.testing.refAllDecls(@This());
    _ = manifest;
    _ = lock;
    _ = lockwrite;
    _ = contenthash;
    _ = phpjson;
    _ = jsonedit;
    _ = auth;
    _ = settings;
    _ = edit;
    _ = scripts;
    _ = config;
    _ = repository;
    _ = advisory;
    _ = maintain;
    _ = layout;
    _ = constraint;
    _ = packagist;
    _ = git;
    _ = plugins;
    _ = installers;
    _ = repo;
    _ = hg;
    _ = svn;
    _ = vcs;
    _ = platform;
    _ = platformcheck;
    _ = solver;
    _ = resolve;
    _ = fetch;
    _ = pack;
    _ = archive;
    _ = install;
    _ = stamps;
    _ = bin;
    _ = runtime;
    _ = classmap;
    _ = autoload;
    _ = inspect;
    _ = project;
    _ = diagnose;
    _ = compat;
    _ = cli;
    _ = report;
    _ = util;

    // `refAllDecls` is not enough on its own. It references each public decl,
    // which analyses a function's SIGNATURE but not its body, so a wrong
    // argument count in a private helper three calls down stays invisible —
    // `zig build test` and `zig build check` both passed while `install.run`
    // called a four-parameter function with three arguments, and only linking
    // the host binary found it.
    //
    // Taking the ADDRESS of an entry point forces it to be codegen'd, and
    // codegen walks everything it calls. One line per public entry point that
    // owns a private call tree.
    _ = &install.run;
    _ = &resolve.command;
    _ = &autoload.plan;
    _ = &autoload.write;
    _ = &inspect.show;
    _ = &inspect.why;
    _ = &inspect.licenses;
    _ = &inspect.validate;
    _ = &inspect.outdated;
    _ = &inspect.checkPlatformReqs;
    _ = &inspect.suggests;
    _ = &inspect.fund;
    _ = &inspect.home;
    _ = &inspect.prohibits;
    _ = &git.mirror;
    _ = &hg.mirror;
    _ = &hg.refs;
    _ = &hg.archiveAt;
    _ = &svn.refs;
    _ = &svn.exportTo;
    _ = &svn.fileAt;
    _ = &git.archiveAt;
    _ = &plugins.discover;
    _ = &installers.pathFor;
    _ = &repo.inlinePackages;
    _ = &repo.artifacts;
    _ = &vcs.prime;
    _ = &packagist.versionsOf;
    _ = &packagist.warm;
    _ = &vcs.candidates;
    _ = &bin.install;
    _ = &pack.create;
    _ = &runtime.generate;
    _ = &runtime.autoloadRealFile;
    _ = &settings.load;
    _ = &platformcheck.render;
    _ = &scripts.run;
    _ = &maintain.status;
    _ = &maintain.bump;
    _ = &maintain.reinstall;
    _ = &maintain.exec;
    _ = &maintain.clearCache;
    _ = &advisory.audit;
    _ = &advisory.search;
    _ = &config.get;
    _ = &config.set;
    _ = &config.unset;
    _ = &config.list;
    _ = &config.init;
    _ = &repository.list;
    _ = &repository.add;
    _ = &repository.remove;
    _ = &repository.setEnabled;
    _ = &repository.setUrl;
    _ = &scripts.runNamed;
    _ = &edit.require;
    _ = &edit.remove;
    _ = &diagnose.run;
    _ = &project.createProject;
    _ = &project.globalDir;
    _ = &project.latestRelease;
    _ = &auth.load;
    _ = &cli.run;
}
