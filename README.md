# hkm-ppkg

A Composer-compatible package manager, written in Zig.

[![CI](https://github.com/AlfaCode-Team/hkm-ppkg/actions/workflows/ci.yml/badge.svg)](https://github.com/AlfaCode-Team/hkm-ppkg/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org)

A drop-in replacement for the Composer commands a project actually uses:
`install`, `update`, `require`, `remove`, `init`, `config`, `audit`,
`dump-autoload` and the rest — reading and writing the same files, byte for
byte, without starting a PHP process to do it.

```
Resolve a 34-vcs-repo, 71-pkg tree composer   375.6s     ppkg   1.67s
Plugin verify (one plugin, cold)   composer  250.06s     ppkg   0.45s
composer dump-autoload             composer    0.70s     ppkg   0.05s
install, warm cache                composer    6.56s     ppkg   2.18s
install, cold cache                                      ppkg  24.10s
resolve 107 packages                                     ppkg   3.40s
```

The first row is the one to look at, and the two resolutions **agree exactly** —
same 71 packages, same versions, same commit references, same content-hash.
Composer is slow there because it reads `vcs` repositories through
`api.github.com`, reaches the unauthenticated limit of 60 calls an hour partway
through the 34 of them, and falls back to cloning each one. `git ls-remote` and
`raw.githubusercontent.com` answer the same questions with no quota at all.

The second row is why this exists. It is not a faster autoloader; it is the
difference between a tool that asks Composer to re-derive a dependency graph
from 34 VCS repositories in order to reach a phpunit that was already on disk,
and one that does not.

## Install

Prebuilt binaries are attached to every
[release](https://github.com/AlfaCode-Team/hkm-ppkg/releases): Linux (x86_64,
aarch64, armv7, riscv64 — static, so one binary runs on any distribution),
macOS (Apple Silicon and Intel), Windows (x64 and ARM64) and FreeBSD.

```sh
# Linux, macOS, FreeBSD — installs ~/.local/bin/ppkg, no root
curl -fsSL https://raw.githubusercontent.com/AlfaCode-Team/hkm-ppkg/main/install.sh | sh
```

```powershell
# Windows — installs into %LOCALAPPDATA%\Programs\ppkg and adds it to your Path
irm https://raw.githubusercontent.com/AlfaCode-Team/hkm-ppkg/main/install.ps1 | iex
```

Both installers check the download against the release's `SHA256SUMS` and
install nothing on a mismatch. Pin a release with `--version v0.2.0`
(`-Version v0.2.0` in PowerShell) and choose the directory with
`PPKG_INSTALL_DIR`. Re-running either one upgrades in place, which is also what
`ppkg self-update` tells you to do.

Or build it: `zig build -Doptimize=ReleaseSafe` puts the binary in
`zig-out/bin/ppkg`.

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
- **`content-hash` is checked the same way.** 201 real composer.json files
  paired with the answer from `Locker::getContentHash`. That field is an md5
  over PHP's `json_encode($data, 0)`, so a defensible encoder is still a wrong
  one: escaped slashes, `\uXXXX` with surrogate pairs, `{}` encoding as `[]`,
  and objects keyed `0..n-1` encoding as arrays all have to be exactly right.
- **Platform checking agrees with `composer check-platform-reqs`** on a
  107-package tree — the same 18 distinct requirements, and the same two
  satisfied by a polyfill rather than by the runtime.
- **The lock it writes is byte-identical to Composer's.** `hkm ppkg update`
  matched `composer update` exactly on five differently-shaped projects, 76 real
  locks re-render unchanged, and Composer installs from a lock this wrote
  without reporting it out of date. Getting there meant matching things no
  documentation mentions: `ArrayDumper`'s key order, `source`/`dist` field
  order, `notification-url` coming from the REPOSITORY rather than the package,
  `published-time` being dropped because `ArrayLoader` has no property for it,
  and `homepage: ""` vanishing because that loader guards it with PHP's
  `empty()`.
- **`composer.json` edits are byte-identical.** 1920 operations that
  `Composer\Json\JsonManipulator` itself applied to 109 real manifests, stored
  as the minimal splice between input and output, live in
  `src/testdata/jsonedit_corpus.json`. That is the property `require` and
  `remove` depend on: an edit changes one line of a file a human wrote, rather
  than reformatting it into a diff nobody can review.
- **Composer's generated path expressions are reproduced.** 832 rows from
  `Filesystem::findShortestPathCode` and `findShortestPath`, in both their
  modes. They decide what `$baseDir` is in every generated autoload file and
  what a `vendor/bin` launcher includes — and once `config.vendor-dir` moves the
  tree, the answer stops being the constant it looks like.
- **`require`, `remove`, `bump` and `init` produce the same file Composer
  does.** Checked operation by operation against `composer require`,
  `composer remove`, `composer bump` and `composer init -n` on the same inputs,
  manifest and lock both.
- **`audit` finds the same advisories.** Same 9 CVEs, same severities, same
  order as `composer audit --locked` on a deliberately vulnerable tree.
- **A non-GitHub `vcs` repository produces the same lock AND the same tree.**
  Checked against a self-hosted git remote: `composer.lock` byte-identical
  (including the commit `time`, which is the author timestamp in UTC), and
  `vendor/` file-for-file identical.
- **`artifact` and `package` repositories are byte-identical too.** A directory
  of a zip and a tarball plus an inline definition: same lock, same `vendor/`,
  same `installed.json` — including that an artifact records a sha1 and no
  `reference`, and that a `package` entry records neither.
- **`extra.installer-paths` places packages exactly where Composer's
  `composer/installers` places them.** Same tree under `web/app/`, same
  `install-path` in `installed.json`, and the same `$baseDir`-anchored rules in
  all five autoload files — that last one is what breaks if the anchor is
  wrong, silently, for every package that lives outside `vendor/`.
- **`archive` produces the same CONTENTS as `composer archive`**, in zip and
  tar.gz, over the same `.gitignore` and `archive.exclude` filtering. Not the
  same bytes — a zip stores a timestamp per entry — so the check is that both
  archives extract to identical trees.
- **`create-project` produces the same project.** Compared against
  `composer create-project` on the same package: identical after each has run
  its own `install`.
- **Mercurial and Subversion produce the same lock and the same tree.** Checked
  against real `hg` and `svn` repositories with tags and a trunk:
  byte-identical `composer.lock` — including each tool's own `time` quirk, which
  is NOT the same quirk — and a `vendor/` identical except that Composer's
  source install leaves a `.hg` / `.svn` directory behind and this one does not
  — git is the one that DOES leave a working copy, because `--prefer-source`
  exists so that a dependency can be edited and diffed in place. A bare
  `"type": "vcs"` pointed at either produces the same answer as the explicit
  type.
- **`lib-*` versions match `composer show --platform` exactly** — the same 31
  libraries with the same versions on this machine, from a port of Composer's
  whole `PlatformRepository` switch. The verdicts agree too, including a
  provided alias (`lib-dom-libxml` "provided by lib-libxml") and the decisive
  rejection of `lib-icu ^70` against an ICU of 78.3.
- **The whole vendor tree is byte-identical, `vendor/bin` included.** `diff -r`
  against a Composer-built tree reports nothing, on projects with binaries, with
  path repositories, and with `include-path`. Reaching that meant reproducing
  the four different shapes `BinaryInstaller` emits — a shell proxy for a
  non-PHP target, a PHP proxy, the same plus the PHP<8 stream wrapper, and
  PHPUnit's two extra workarounds — and it meant this tool keeping no bookkeeping
  file of its own anywhere under `vendor/`.
- **The loader is generated, not borrowed.** `vendor/autoload.php` and
  `autoload_real.php` come from the same templates `AutoloadGenerator`
  interpolates, every conditional included: the `$files` block, the
  `include_paths.php` block, `platform_check.php`, `setClassMapAuthoritative`,
  `setApcuPrefix`, `setUseIncludePath` and the prepend flag. `ClassLoader.php`
  and `InstalledVersions.php` are Composer's own MIT source, embedded with its
  licence — so an install on a machine that has never had Composer produces a
  working tree.
- **A partial update moves what was named and nothing else.** `update psr/log`
  on a tree holding an older `monolog/monolog` leaves monolog exactly where it
  was — the same answer `composer update psr/log` gives, checked side by side.

## Will it handle YOUR project?

Ask it:

```sh
ppkg compat        # or: hkm ppkg compat
```

It reads composer.json and reports anything it cannot honour, before touching
a file. `install` and `update` run the same audit and refuse rather than
proceed when the answer would be wrong-but-plausible — a `vcs` repository
resolved by silently taking the packagist package of the same name is the case
that motivated it.

A finding **blocks** when proceeding produces a wrong answer that looks right
and **warns** when the result is merely incomplete.
`--ignore-unsupported` downgrades a block, for an operator who knows their
`vcs` entry is a mirror.

Across the 48 composer.json files in the workspace this was developed against —
the kernel, its bundled packages, every plugin and every project — the audit
reports **46 fully compatible, 2 with a caveat, 0 blocked**. Both caveats are
`config.allow-plugins` on a tree with no `vendor/` yet; run `compat` against an
installed tree and it names each plugin and says what that specific plugin
would have done.

## Does an existing Composer project still work?

Yes, in both directions, and it is checked rather than asserted:

- `vendor/` built by this package is **file-for-file identical** to
  `composer install`'s. That includes every generated autoload file, the
  `vendor/bin` launchers, `installed.json` and `installed.php`.
- `composer install` on a tree this built reports **"Nothing to install, update
  or remove"** and rewrites none of it.
- The kernel's own 389-test suite passes through a `vendor/` this produced, as
  does a 60-test plugin suite whose tree came from 34 `vcs` repositories.
- `composer.json` survives a `config` set-then-unset **byte-identically**.

## What it does not do

Stated plainly, because a package manager that overstates its coverage is worse
than one that does less:

- **The solver is not Composer's.** Composer runs a CDCL SAT solver. This is a
  backtracking search with a most-constrained-first heuristic and a step budget,
  and it reports `exhausted` as an outcome *distinct* from `unsatisfiable` —
  because it can give up on a problem that does have a solution, and answering
  "impossible" when the honest answer is "I stopped looking" is the one failure
  mode a resolver must not have.
- **Composer PLUGINS are not loaded**, and this is the only gap left that is not
  going to close by adding code. A plugin is a PHP class handed Composer's own
  object graph — `Composer\Composer`, `InstallationManager`,
  `RepositoryManager`, `IOInterface` and the package model under all of them —
  and it may call anything on it. Running one means either depending on
  `composer/composer` (which makes a Composer replacement require Composer) or
  shipping a shim of that graph, which works until a plugin reaches a method the
  shim lacks and then fails PART WAY THROUGH, having already written some of its
  output. Measured on three real plugins, the surface a shim would need includes
  `Composer\Semver\Intervals` and the whole constraint object model.

  So plugins do not run, and `compat` says so **by name**: which plugins are
  installed, which the project allowed, and what each specific one would have
  done — `phpstan/extension-installer` generates a `GeneratedConfig.php`,
  `cweagans/composer-patches` leaves packages unpatched — rather than a generic
  "plugins are not loaded" that no reader can act on.

  The one exception is `composer/installers`, because a wrong LOCATION is a
  broken tree rather than a tree with something missing. Its root-package
  mechanism, `extra.installer-paths`, is pure data and is implemented natively
  and verified byte-for-byte. Its built-in per-framework table (a hundred PHP
  classes, several with their own name inflection) is not, and a project relying
  on it is BLOCKED rather than silently misplaced.
- `auth.json` credentials cover every scheme Composer has: `github-oauth`,
  `gitlab-token`, `gitlab-oauth`, `bitbucket-oauth`, `http-basic`, `bearer`,
  `custom-headers` and `client-certificate`, from the four sources Composer
  reads in Composer's precedence order. What is not covered is any INTERACTIVE
  prompt — a missing credential fails and says which host it was for, rather
  than asking.

  Two of those are worth a note. `custom-headers` are sent verbatim, and a line
  that is not a header is dropped rather than turned into a malformed request.
  `client-certificate` cannot go through `std.http.Client` at all — Zig's TLS
  client has no field for one — so a host configured with a certificate is
  fetched through `curl`, and the key passphrase goes to it on stdin rather than
  in an argument that `ps` would show to every user on the machine.
- **A non-GitHub `vcs` host costs a mirror clone, once.** GitHub is read over
  static endpoints with no clone at all; every other host — GitLab, Bitbucket,
  Gitea, self-hosted, `ssh://` — goes through a bare mirror in the cache, and
  every question after the first is answered from disk. That is not slower than
  Composer, whose generic driver clones too, but it is slower than the GitHub
  path and it is worth knowing which one a repository is on.
- **`config` is read from all four layers Composer reads it from** — defaults,
  `$COMPOSER_HOME/config.json`, the project, then `COMPOSER_*` variables —
  merged per key. Every setting with an effect is honoured: the autoloader ones
  (`optimize-autoloader`, `classmap-authoritative`, `apcu-autoloader`,
  `autoloader-suffix`, `prepend-autoloader`, `use-include-path`),
  `preferred-install` in both its shapes, `vendor-dir`, `bin-dir`,
  `platform`, `platform-check`, `sort-packages`, `lock`, `archive-format`,
  `archive-dir`, `cache-dir`, `secure-http`, `disable-tls`, `cafile` and
  `capath`.

  Two are honoured only in part, and `compat` says so rather than leaving it to
  be discovered. **`process-timeout`** bounds the network fetch and nothing
  else: a script or a `git clone` that overruns it is not killed. **`policy`**
  is written and read back but never ENFORCED — no policy document is fetched
  and no package is refused on account of one.

  `cafile`, `capath`, `disable-tls` and a client certificate all route the
  request through `curl`, because Zig's TLS client accepts none of them.
- `lib-*` requirements ARE determined now — `src/probe.php` is a port of
  Composer's whole `PlatformRepository` library switch, kept as PHP so that
  `php -l` checks it and its output can be diffed against
  `composer show --platform` directly. What is still reported as `unmodelled`
  rather than `missing` is every requirement on a machine with no interpreter
  to ask: "this machine does not have ext-json" and "nothing here could be
  asked" are different claims, and only one of them is honest.
- **`svn` and `hg` are read, and each in the way its own tool works.** Mercurial
  gets a `--noupdate` clone in the cache, like git's mirror. Subversion gets no
  cache at all: it is a server protocol, so `svn ls`, `svn cat` and `svn export`
  talk to the remote directly and there is nothing local that could disagree
  with it. `fossil` and `perforce` are not read.
- A dist with no `shasum` in the lock is still installed — GitHub publishes no
  digest for a generated zipball, so refusing would refuse every `vcs` package,
  and Composer does not refuse either. It is no longer SILENT: the install
  reports how many archives arrived with nothing to check them against, and
  `--require-checksums` refuses instead, for a build that may not ship a byte
  nobody vouched for.

## The commands

```
install      build vendor/ from composer.lock          require    add a dependency
update       resolve composer.json and write the lock  remove     drop one
autoload     regenerate the autoloader                 init       write a composer.json
run-script   run one entry from `scripts`              config     read/write one manifest key
exec         run a binary from the project's bin dir   bump       raise constraints to the lock

audit        security advisories against the lock      show       what is installed
search       look a package up on packagist            why        what requires it
outdated     what has moved on since the lock          prohibits  what blocks a version
status       what differs from the lock                licenses   what you are shipping
suggests     optional companions not installed         validate   is composer.json sound
fund         who to support                            home       a package's url

archive      write the project out as a tar or zip     browse     open a package's url
create-project  start a new project from a package     global     operate on $COMPOSER_HOME
diagnose     can this machine do the work at all       self-update  is a newer release out
repository   list/add/remove a repositories entry      completion   a shell completion script
policy       record a dependency-policy source         list         the command index

check-platform-reqs   does this machine satisfy every php/ext-* requirement
compat                can this tool handle this project, or is Composer required
content-hash          what composer.lock's content-hash should be, and whether it agrees
lock --check          is composer.lock in canonical form
reinstall             delete a package so the next install replaces it
clear-cache           empty the download and metadata cache
```

Every command takes the flags Composer puts on all of them — `-q`, `-n`,
`-d/--working-dir`, `--no-cache`, `--ansi`/`--no-ansi`, `--no-plugins` —
before the command word or after it (`ppkg -d app install`, `ppkg install -d
app`). `-d` changes directory the way Composer's does, so a relative path given
to the command resolves inside it. `exec` takes them only before the binary's
name, because what follows belongs to the program it runs. The ones that
install take `--ignore-platform-reqs` (and its `=name` and
`=php+` forms), `--prefer-source` / `--prefer-dist`, `--no-autoloader`,
`--download-only`, `--no-progress`, `-a`, `--apcu-autoloader`. `update` and
`require` take package names for a PARTIAL update, with `-w` / `-W`,
`--prefer-lowest`, `--prefer-stable`, `--lock` and `--root-reqs`.

Three commands do less than Composer's of the same name, deliberately:

- **`policy`** records a source in `config.policy`, byte-identically, and
  enforces nothing: no policy document is fetched and no package is refused on
  account of one. The command says so every time it runs, rather than leaving a
  project to believe a policy is in force.
- **`archive`** archives the project, not a named dependency. Archiving a
  dependency means resolving and downloading it, which is a different command
  wearing the same name; it is refused rather than quietly archiving the wrong
  thing.
- **`self-update`** reports the newest release and the command that installs it
  for however this binary was installed — it does not overwrite the file. The
  binary was put there by Homebrew, an installer or a build tree, each of which
  owns it, and a package manager overwriting a file Homebrew believes it manages
  leaves the machine in a state neither tool can reason about.

## Layout

| File | What it is |
|---|---|
| `manifest.zig` | composer.json / installed.json — packages, autoload blocks, repositories |
| `lock.zig` | composer.lock, and Composer's version normalisation |
| `settings.zig` | the merged `config` block — machine, project, environment |
| `repository.zig` | reading and editing the `repositories` list |
| `stamps.zig` | which reference each installed directory holds, kept in the cache |
| `constraint.zig` | the constraint algebra — `^`, `~`, ranges, wildcards, stability |
| `contenthash.zig` | composer.lock's `content-hash` |
| `lockwrite.zig` | writing composer.lock, in Composer's exact key order |
| `phpjson.zig` | PHP's `json_encode`, in both configurations Composer uses |
| `platform.zig` | `php` / `ext-*` / `config.platform`, from one interpreter probe |
| `packagist.zig` | the packagist.org v2 client, including the minified diff format |
| `solver.zig` | backtracking resolution over a candidate pool |
| `resolve.zig` | resolving a project on disk — path repos, git branches, lock diffing |
| `fetch.zig` | HTTP with a content-addressed cache, and parallel prefetch |
| `archive.zig` | unpacking a dist, and symlinking a path repository |
| `install.zig` | placement, `installed.json`, `installed.php` |
| `bin.zig` | `vendor/bin/*` launcher proxies |
| `layout.zig` | `config.vendor-dir` / `bin-dir`, and Composer's generated path expressions |
| `platformcheck.zig` | `vendor/composer/platform_check.php`, generated from what is installed |
| `jsonedit.zig` | editing composer.json in place, without reformatting it |
| `edit.zig` | `require` / `remove` — edit, re-lock, install, or undo |
| `config.zig` | `config` and `init` |
| `scripts.zig` | the ROOT package's install-event commands, and nothing else's |
| `advisory.zig` | `audit` and `search` |
| `maintain.zig` | `status`, `bump`, `reinstall`, `exec`, `clear-cache` |
| `vcs.zig` | `vcs` repositories, read without touching a rate-limited API |
| `git.zig` | the bare mirror that makes a non-GitHub host readable |
| `hg.zig` | Mercurial, over a `--noupdate` clone in the cache |
| `svn.zig` | Subversion, straight over its own protocol — no cache |
| `probe.php` | one PHP process reporting php, ext-* and lib-* — Composer's switch, ported |
| `repo.zig` | `package` and `artifact` repositories — the two that need no server |
| `auth.zig` | `auth.json`, `COMPOSER_AUTH`, and the config credential blocks |
| `installers.zig` | `extra.installer-paths` — placing a package outside `vendor/` |
| `plugins.zig` | composer plugins: what is installed, and what does not run |
| `pack.zig` | `archive` — writing a package out as a tar or a zip |
| `diagnose.zig` | `diagnose` — can this machine and this project do the work |
| `project.zig` | `create-project`, `global`, `browse`, `self-update` |
| `runtime.zig` | the loader — generated, with Composer's MIT source in `res/` |
| `classmap.zig` | a PHP lexer that finds classes, interfaces, traits and enums |
| `autoload.zig` | `composer dump-autoload`, byte for byte |
| `inspect.zig` | show / why / licenses / validate / outdated |
| `compat.zig` | what it cannot do for a given project, said first |
| `cli.zig` | the command line itself — parsing, dispatch, `--version`, completion; one front-end for every host |
| `report.zig` | where output goes — silent until a host installs a sink |
| `util.zig` | the few path and file helpers the above are built on |

Path traversal during extraction (`../`, absolute paths, backslashes) is
rejected by the STANDARD LIBRARY, not by code in this repository — `std.zip`
for a zip and `std.tar` for a tarball, both of which fail the archive rather
than write outside the destination. That is a guarantee that moves with the
standard library, and one that anything replacing either extractor inherits.

Credentials get one line of their own: they are sent as `privileged_headers`,
which `std.http.Client` STRIPS when a redirect crosses to a different parent
domain. Every dist URL in a lock is a redirect to somewhere else, so a token in
the ordinary header list would follow a 302 wherever the server pointed it.

`runtime.zig` is worth a paragraph. `vendor/autoload.php` and
`autoload_real.php` are GENERATED, from the same templates `AutoloadGenerator`
interpolates; `ClassLoader.php` and `InstalledVersions.php` are Composer's own
MIT-licensed source, **embedded in `src/res/` with its licence text**, and
written out beside the files that use them.

They used to be copied from a donor vendor tree instead, on the reasoning that
carrying someone else's code inside a build tool is a maintainer's decision.
The reasoning was sound and the consequence was not: on a machine with no
donor — a fresh checkout, a CI container, anyone who does not already have
Composer — an install placed every package correctly and then reported that it
could not produce an entry point, and told the operator to run `composer
install` once. A package manager whose failure mode is "install the tool I
replace" is bootstrapped by that tool, not a substitute for it.

`composer_source_version` records which Composer release the two embedded files
came from, and `diagnose` reports it, so the drift is visible rather than
silent.

## Using it

### As a command

`ppkg <command>` — every command is listed [above](#the-commands). `ppkg
--version` prints the release; `ppkg completion bash|zsh|fish` prints a
completion script. Results go to stdout and diagnostics to stderr, so `ppkg
show > deps.txt` captures the answer and not the commentary; colour follows
`NO_COLOR`, `TERM=dumb` and whether the stream is a terminal.

`HKM_PHP` names the PHP binary used to run a project's `scripts` and to probe
`php` / `ext-*` for platform checks. `HKM_PKG_CACHE` moves the download cache
and `HKM_PKG_JOBS` sets how many downloads run in parallel.

### As a library

```zig
// build.zig
const ppkg = b.dependency("hkm_ppkg", .{}).module("ppkg");
exe.root_module.addImport("ppkg", ppkg);
```

or, for a sibling checkout with no package manager involved:

```zig
const ppkg = b.createModule(.{
    .root_source_file = b.path("../modules/hkm-ppkg/src/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

Nothing prints until a host asks it to. Install an output sink once at startup:

```zig
ppkg.report.use(.{ .intro = myIntro, .item = myKeyValue, .warn = myWarn, ... });
```

Every field defaults to a no-op, so a partial installation is fine — and a host
that installs nothing gets a silent library rather than a library that has
decided what its stdout looks like.

### Embedding the command line

A host that wants the whole command line rather than its pieces runs the same
front-end the standalone binary does, with what only the host knows:

```zig
return ppkg.cli.run(allocator, io, env, args_after_the_subcommand, .{
    .program = "hkm ppkg",               // how the user invokes it
    .version = build_info.version,
    .release_repo = "owner/repo",        // what `self-update` compares against
    .executable = exe_path,              // how `self-update` guesses the install
    .self_command = "/path/to/hkm ppkg", // what `@composer` in a script runs
    .extension = .{ .dispatch = myCommands, .usage = &.{...}, .words = "my-cmd" },
});
```

`program` is applied by `report`. Every message spells the tool `ppkg`, and a
host's spelling replaces it only where it names a command — at the start of a
line, or straight after a backtick — so a package called `acme/ppkg` or a URL
ending in `hkm-ppkg` passes through untouched, and so does everything written
with `report.raw`. Install the sink's `quiet` and `color` too, or `-q` and
`--ansi` will parse and then do nothing.

### Building

```sh
zig build                  # the binary → zig-out/bin/ppkg
zig build run -- about     # build and run it
zig build test             # every test, including the differential corpora
zig build check            # compile library and binary for -Dtarget=… without running
```

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) — the short version is that a claim about
Composer's behaviour must be checked against Composer, and the corpus exists so
that it can be. Security reports go through [SECURITY.md](SECURITY.md), never a
public issue.

## Where it is used

- **`ppkg`**, the standalone binary built from `app/` and published for every
  platform on each release.
- **`hkm ppkg`** in [hkm-kernel](https://github.com/AlfaCode-Team/hkm-kernel),
  which embeds the same command line through `cli.run` and adds `test-env` —
  the one command that knows what an hkm plugin is — through
  `Options.extension`. The hkm side is a page of code; nothing in this
  repository knows what an hkm plugin is.

## Licence

MIT — see [LICENSE](LICENSE).
