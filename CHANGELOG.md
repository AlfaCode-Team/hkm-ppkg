# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Until `1.0.0`, the public surface — `src/root.zig` and the `report` sink — may
change in a minor release. Anything that would silently produce a *different
vendor tree* is called out under **Changed** whether or not the API moved,
because that is the change that matters to a consumer.

## [Unreleased]

### Added

- Initial extraction from the `hkm-kernel` tooling into a standalone package.
- `report.zig`: output is a sink of function pointers, defaulting to no-ops, so
  the library prints nothing until a host installs one.
- Regression test for stamping: a path repository is never stamped.

### Fixed

- `zig build check`: plain `zig build` compiled nothing, because the package
  installs no artifact. The CI compile and cross-compile jobs written against it
  would have been green for every target regardless of whether the code built.
- The version-normalisation test's table of 81 real (version, version_normalized)
  pairs was empty, so the test asserted nothing while reading as the strongest
  one in the file. The pairs are present and a mutation confirms they run.
- `.ppkg-ref` was written into path repositories. Because `vendor/<name>` for a
  path repo is a symlink into the user's own project, the write landed in their
  source checkout — leaving an untracked file in a git repository this tool has
  no business writing to.

### Changed

- The stamp file is `.ppkg-ref` (was `.hkm-pkg-ref`) and the unpack staging
  directory is `<dest>.ppkg-unpack`. Existing trees re-install once; nothing is
  lost, because the stamp only decides whether extraction can be skipped.
