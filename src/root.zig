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

// ── deciding what to install ──────────────────────────────────────────────────

/// Composer's constraint algebra — `^`, `~`, ranges, wildcards, stability.
pub const constraint = @import("constraint.zig");
/// The packagist.org v2 metadata client, including the minified diff format.
pub const packagist = @import("packagist.zig");
/// Backtracking dependency resolution over a candidate pool.
pub const solver = @import("solver.zig");
/// Resolving a project on disk: path repositories, git branches, lock diffing.
pub const resolve = @import("resolve.zig");

// ── getting it onto disk ──────────────────────────────────────────────────────

/// HTTP with a content-addressed cache, and parallel prefetch.
pub const fetch = @import("fetch.zig");
/// Unpacking a dist archive, and symlinking a path repository.
pub const archive = @import("archive.zig");
/// Placing packages and writing installed.json / installed.php.
pub const install = @import("install.zig");
/// `vendor/bin/*` launcher proxies.
pub const bin = @import("bin.zig");
/// Composer's own MIT runtime files, copied from a donor tree — never vendored.
pub const runtime = @import("runtime.zig");

// ── generating the autoloader ─────────────────────────────────────────────────

/// A PHP lexer that finds the classes, interfaces, traits and enums in a file.
pub const classmap = @import("classmap.zig");
/// `composer dump-autoload`, byte for byte.
pub const autoload = @import("autoload.zig");

// ── asking questions about a tree ─────────────────────────────────────────────

/// show / why / licenses / validate / outdated.
pub const inspect = @import("inspect.zig");

// ── host integration ──────────────────────────────────────────────────────────

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
    _ = constraint;
    _ = packagist;
    _ = solver;
    _ = resolve;
    _ = fetch;
    _ = archive;
    _ = install;
    _ = bin;
    _ = runtime;
    _ = classmap;
    _ = autoload;
    _ = inspect;
    _ = report;
    _ = util;
}
