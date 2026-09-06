# hkm-pkg

A Composer-compatible package manager, written in Zig.

It does the work a build tool actually spends its time on — reading manifests,
resolving constraints, fetching and placing packages, and generating the
autoloader — without starting a PHP process to do it.

```
Plugin verify (one plugin, cold)   composer  250.06s     hkm-pkg   0.45s
composer dump-autoload             composer    0.70s     hkm-pkg   0.05s
install, warm cache                composer    6.56s     hkm-pkg   2.18s
install, cold cache                                      hkm-pkg  24.10s
resolve 107 packages                                     hkm-pkg   3.40s
```

The first row is why this exists. It is not a faster autoloader; it is the
difference between a tool that asks Composer to re-derive a dependency graph
from 34 VCS repositories in order to reach a phpunit that was already on disk,
and one that does not.

## Verified against Composer, not against its documentation

Two claims here are checked mechanically, because "looks right" is not a
property a package manager can be shipped with:

- **The autoloader is byte-identical.** All five generated files match
  `composer dump-autoload` exactly, with and without `-o`, across 107 packages
  and 6176 classmap entries. That required reproducing Composer's *two*
  different package walk orders (`files` sorted with the root last; PSR-4/0 and
  classmap reversed with the root first), its `sortPackages` weighting, and
  `strnatcasecmp` ordering — none of which are documented, and each of which
  produces a file that looks fine and loads a different class.
- **The constraint algebra is checked differentially.** 5881 recorded
  `(version, constraint, answer)` rows, evaluated by `Composer\Semver\Semver`
  itself, live in `src/testdata/semver_corpus.json` and run as a unit test. It
  found four bugs that reviewing the code did not: `~1.2`'s upper bound,
  branch-alias padding, `X.Y.x-dev` being an exact match rather than a range,
  and a bare `1.0` being an exact pin rather than a series.

## What it does not do

Stated plainly, because a package manager that overstates its coverage is worse
than one that does less:

- **It does not write `composer.lock`.** `install` places a locked set;
  `resolve` chooses versions and prints them. Creating a lock is still
  `composer update`.
- **The solver is not Composer's.** Composer runs a CDCL SAT solver. This is a
  backtracking search with a most-constrained-first heuristic and a step budget,
  and it reports `exhausted` as an outcome *distinct* from `unsatisfiable` —
  because it can give up on a problem that does have a solution, and answering
  "impossible" when the honest answer is "I stopped looking" is the one failure
  mode a resolver must not have.
- `replace`, `conflict`, `provide` and `suggest` are unmodelled; platform
  requirements are not verified; `scripts` never run; `auth.json` is not read;
  `tar` dists are unsupported (zip only).

## Layout

| File | What it is |
|---|---|
| `manifest.zig` | composer.json / installed.json — packages, autoload blocks, repositories |
| `lock.zig` | composer.lock, and Composer's version normalisation |
| `constraint.zig` | the constraint algebra — `^`, `~`, ranges, wildcards, stability |
| `packagist.zig` | the packagist.org v2 client, including the minified diff format |
| `solver.zig` | backtracking resolution over a candidate pool |
| `resolve.zig` | resolving a project on disk — path repos, git branches, lock diffing |
| `fetch.zig` | HTTP with a content-addressed cache, and parallel prefetch |
| `archive.zig` | unpacking a dist, and symlinking a path repository |
| `install.zig` | placement, `installed.json`, `installed.php` |
| `bin.zig` | `vendor/bin/*` launcher proxies |
| `runtime.zig` | Composer's own MIT runtime files, copied from a donor tree |
| `classmap.zig` | a PHP lexer that finds classes, interfaces, traits and enums |
| `autoload.zig` | `composer dump-autoload`, byte for byte |
| `inspect.zig` | show / why / licenses / validate / outdated |
| `report.zig` | where output goes — silent until a host installs a sink |
| `util.zig` | the few path and file helpers the above are built on |

`runtime.zig` is worth one line of explanation: Composer's `ClassLoader.php` and
`InstalledVersions.php` are its own MIT-licensed source, and they are **copied
from a donor vendor tree, never vendored into this repository**. Carrying
someone else's code and its licence inside a build tool is a decision for a
maintainer to take deliberately, not one for a build tool to take on their
behalf. The host says which trees may be read from; this package does not go
looking.

## Using it

```zig
// build.zig
const pkg = b.dependency("hkm_pkg", .{}).module("pkg");
exe.root_module.addImport("pkg", pkg);
```

or, for a sibling checkout with no package manager involved:

```zig
const pkg = b.createModule(.{
    .root_source_file = b.path("../modules/hkm-pkg/src/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

Nothing prints until a host asks it to. Install an output sink once at startup:

```zig
pkg.report.use(.{ .intro = myIntro, .item = myKeyValue, .warn = myWarn, ... });
```

Every field defaults to a no-op, so a partial installation is fine — and a host
that installs nothing gets a silent library rather than a library that has
decided what its stdout looks like.

```sh
zig build test     # 77 tests, including the 5881-row differential corpus
```

## Where it is used

`hkm pkg` in [hkm-kernel](https://github.com/AlfaCode-Team/hkm-kernel) —
`install`, `autoload`, `resolve`, `outdated`, `show`, `why`, `licenses`,
`validate`. The argument parsing, the kernel-specific paths and the output style
live there; nothing in this repository knows what an hkm plugin is.

## Licence

MIT — see [LICENSE](LICENSE).
