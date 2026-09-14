# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Until `1.0.0`, the public surface — `src/root.zig` and the `report` sink — may
change in a minor release. Anything that would silently produce a *different
vendor tree* is called out under **Changed** whether or not the API moved,
because that is the change that matters to a consumer.

## [Unreleased]

## [0.1.0] - 2026-09-14

### Added

- **A standalone `ppkg` binary, released for every platform.** Linux x86_64,
  aarch64, armv7 and riscv64 (static musl — one binary for every
  distribution), macOS on Apple Silicon and Intel, Windows x64 and ARM64, and
  FreeBSD, each built ReleaseSafe and attached to a GitHub release with
  `SHA256SUMS`. `install.sh` (`curl | sh`) and `install.ps1` (`irm | iex`)
  install it for the current user, verify the checksum first, and install
  nothing on a mismatch. Releasing is merging a CHANGELOG heading and a
  matching `build.zig.zon` version to `main` — see CONTRIBUTING.md,
  "Releasing". `ppkg --version` / `-V` report the release.

- **`cli` — the command line is part of the package.** It lived in hkm-kernel
  before, so there was no way to run this package without that host.
  `cli.run(allocator, io, env, args, Options)` is what the standalone binary
  runs and what `hkm ppkg` now calls; `Options` carries what only a host knows
  (its spelling, version, release repository, executable path) and
  `Options.extension` adds a host's own commands, which is how `test-env` stays
  in hkm-kernel. Completion scripts are generated for however the tool is
  invoked — `ppkg <cmd>` or `hkm ppkg <cmd>`.

- **`report.setProgram`**, plus `quiet` and `color` on the sink. Messages spell
  the tool `ppkg`; a host's spelling replaces it where it names a command (the
  start of a line, or after a backtick) and nowhere else, so package names,
  URLs and `raw` output are never rewritten. `-q` and `--ansi` reach a host's
  renderer through the two new sink fields, which default to no-ops.

- **The vendor tree no longer needs Composer to bootstrap it.**
  `vendor/autoload.php` and `vendor/composer/autoload_real.php` are now
  GENERATED, from the same templates `AutoloadGenerator` interpolates — every
  conditional included — and `ClassLoader.php`, `InstalledVersions.php` and
  Composer's licence are embedded in `src/res/`.

  They were copied from a donor vendor tree before, which meant that on a
  machine with no donor an install placed every package correctly and then
  reported that it could not produce an entry point, telling the operator to
  run `composer install` once. `runtime.zig` explains why the earlier reasoning
  did not survive that. `composer_source_version` records the Composer release
  the embedded files came from.

- **`include_paths.php`.** A package declaring `include-path` now gets the file
  Composer writes for it, and `autoload_real.php` gets the block that pushes
  those directories onto PHP's `include_path`. Without it such a package cannot
  find its own classes.

- **Partial updates.** `update vendor/name` moves the named packages and pins
  everything else to what the lock already holds, with `-w` / `-W` for their
  dependencies, plus `--root-reqs` and `--lock`. `require` is a partial update
  too, which is what it has always been in Composer: adding one package no
  longer moves the other forty. Verified against `composer update <pkg>` on the
  same tree.

- **`--ignore-platform-reqs`**, its per-name form `--ignore-platform-req=NAME`,
  and the `NAME+` form that lifts a constraint's ceiling while keeping its
  floor. An ignored requirement reports as `ignored`, never as satisfied, and
  suppresses `platform_check.php` — a project that installed against a machine
  it does not satisfy should not get a generated file that refuses to boot.

- **`--prefer-source` / `--prefer-dist` / `--prefer-install`, and
  `config.preferred-install` in both its shapes.** A source install now
  produces a real git working copy at the locked reference, with `.git` and an
  `origin` pointing at the package's own URL — which is what the flag is for:
  editing a dependency in place and producing a patch. `installation-source` in
  `installed.json` reports what the run actually did.

- **`settings.zig` — `config` read from all four layers**, merged per key:
  defaults, `$COMPOSER_HOME/config.json`, the project, then `COMPOSER_*`
  variables. Newly honoured: `optimize-autoloader`, `classmap-authoritative`,
  `apcu-autoloader`(`-prefix`), `autoloader-suffix`, `prepend-autoloader`,
  `use-include-path`, `preferred-install`, `lock`, `archive-format`,
  `archive-dir`, `cache-dir`, `secure-http`, `disable-tls`, `cafile`, `capath`.

- **`repository`, `policy`, `completion` and `list`.** `repository` reads and
  edits `repositories` — list, add, remove, set-url, get-url, enable, disable,
  with `--append` / `--before` / `--after` — writing the array-of-objects shape
  Composer writes, `},{` bracket placement included. `policy add-source`
  records a source and says, every time, that policies are not ENFORCED here.
  `completion` emits bash, zsh and fish scripts. `list` is now the command
  index, as it is in Composer, rather than an alias for `show`.

- **The global flags every Composer command accepts**: `-q`, `-v`/`-vv`/`-vvv`,
  `-n`, `--profile`, `--no-cache`, `--no-plugins`, `--ansi`/`--no-ansi` and
  `-d`/`--working-dir`, peeled off before dispatch so they work everywhere
  rather than on the commands that happened to parse them.

- **Install flags**: `--no-autoloader`, `--download-only`, `--no-progress`,
  `-a`/`--classmap-authoritative`, `--apcu-autoloader`. **Autoload flags**:
  the same two plus `--strict-psr`, which reports every class a psr-4 rule
  claims but could never load, in Composer's own wording and with Composer's
  exit code. **Update flags**: `--prefer-lowest`, `--prefer-stable`.
  **Require flags**: `--fixed`, `--update-no-dev`, `-w`/`-W`.

- **Mercurial and Subversion.** Both read, and each the way its own tool works.

  `hg` gets a `--noupdate` clone in the cache and answers refs, manifests and
  the archive off it, exactly as the git mirror does. Two lists are read, not
  one: Composer merges `hg branches` with `hg bookmarks`, and a repository that
  uses bookmarks as its branch model — common on Bitbucket-era projects — has
  nothing but `default` in the first, so reading only one makes every version of
  such a package disappear with no error at all.

  `svn` gets NO cache, because it is a server protocol: `svn ls`, `svn cat` and
  `svn export` talk to the remote directly, and a mirror would be a second copy
  of something the server is already authoritative for. Its identifiers are a
  path AND a revision (`/tags/1.2.0/@42`) because a Subversion tag is an
  ordinary directory anyone can commit to — a lock recording only the path would
  pin nothing.

  Verified against real repositories: byte-identical `composer.lock` for both,
  and a `vendor/` identical to Composer's except that its source install leaves
  a `.hg` / `.svn` directory behind and this one does not. A bare
  `"type": "vcs"` pointed at either gives the same answer as the explicit type —
  the tool is probed once, up front, and then used for every question about that
  repository.

- **`lib-*` platform versions.** `src/probe.php` is a port of Composer's whole
  `PlatformRepository` library switch, regex for regex — kept as a PHP FILE
  rather than a string in the Zig source so that `php -l` checks it and its
  output can be diffed against `composer show --platform` directly. It is: the
  same 31 libraries at the same versions on this machine.

  Provided aliases are recorded separately from real libraries. `lib-libxml`
  provides `lib-dom-libxml`, and a constraint on the latter is satisfied — but
  it is not a library this machine HAS, and `composer show --platform` does not
  list it either.

- **`custom-headers` and `client-certificate`.** Every credential scheme
  Composer has is now honoured. Custom headers are sent verbatim; a line that is
  not a header is dropped rather than turned into a malformed request.

  Client certificates cannot go through `std.http.Client` — Zig's TLS client has
  no field for one — so a host configured with a certificate is fetched through
  `curl`, and the key passphrase reaches it on stdin rather than in an argument
  that `ps` shows to every user on the machine.

- **`--require-checksums`**, and a count of what arrived without one. A dist
  with no `shasum` is still installed by default (GitHub publishes no digest for
  a generated zipball, so refusing would refuse every `vcs` package, and
  Composer does not refuse either) — but it is no longer silent, and the flag
  refuses for a build that may not ship a byte nobody vouched for.

- `diagnose` checks for `hg` and `svn`, but only when the project declares a
  repository of that kind. A missing tool is a FAILURE there, not a warning:
  without it the repository is unreadable and its package falls through to
  whatever packagist has under the same name.

- **Every repository type Composer reads.** `vcs` on any host, `package` and
  `artifact` — the three that were previously refused, each of which used to be
  a *blocking* finding because resolving without them silently takes the
  packagist package of the same name.

  - **Non-GitHub `vcs`** goes through a bare mirror kept in the cache
    (`git.zig`): refs from `git ls-remote` against the mirror, a manifest from
    `git cat-file blob <sha>:composer.json`, and the code itself from
    `git archive`. One fetch per repository per TTL; every question after that
    is a local read. GitHub keeps its own path because it can skip the clone
    entirely. Verified against a self-hosted remote: **byte-identical
    `composer.lock` and byte-identical `vendor/`**, the latter except that
    Composer's source install leaves a `.git` directory in the vendor tree and
    this one does not.
  - **`package`** repositories contribute their inline definitions. A definition
    with no `dist` and no `source` is REJECTED with the reason rather than
    accepted: it resolves, it locks, and then it fails to install — on whichever
    machine runs `install` next, not on the one that wrote the lock.
  - **`artifact`** repositories are scanned for `.zip`, `.tar`, `.tar.gz`,
    `.tgz` and `.tar.xz`; the version comes from the manifest INSIDE the
    archive, never from the filename. The extracted manifest is cached against
    the file's size and mtime, so a directory of fifty artifacts is unpacked
    once and then costs one `stat` each.

- **Credentials** — `auth.json` (project and `$COMPOSER_HOME`), `COMPOSER_AUTH`,
  and the `config` credential blocks, merged in Composer's precedence order so
  that CI overrides a checked-in value. `github-oauth`, `gitlab-token`,
  `gitlab-oauth`, `bitbucket-oauth`, `http-basic` and `bearer` are honoured, in
  the exact header spelling each one uses. `GITHUB_TOKEN`/`GH_TOKEN` are read
  too, at the lowest precedence — an addition rather than a compatibility claim,
  and documented as one.

  A credential must not follow a redirect to a host the operator never
  configured — every dist URL in a lock is a redirect to somewhere else. The
  first attempt at that used `std.http.Client`'s `privileged_headers`, which
  turned out never to be sent at all; see **Fixed** for what it does now.

- **`tar`, `tar.gz` and `tar.xz` distributions**, and the format is chosen by
  SNIFFING the leading bytes rather than by trusting the extension or the lock's
  `dist.type` — both are written by hand and both are wrong in the wild.

- **Source installs.** A lock entry with a `source` and no `dist` — which is
  what every non-GitHub `vcs` package and most `package` repositories look like
  — now installs, from `git archive` off the mirror (and `hg archive` or
  `svn export` for the other two). No `.git` lands in
  `vendor/`, and the bytes travel the same extractor, and therefore the same
  traversal checks, as a downloaded archive.

- **`extra.installer-paths`** — `composer/installers`' root-package mechanism,
  implemented natively. This is the one plugin behaviour that could not be
  reported and skipped: skipping it does not leave a tree missing something, it
  leaves the tree WRONG, with a WordPress project's plugins in `vendor/` while
  the application looks in `web/app/plugins/`. Verified against Composer running
  the real plugin: same tree, same `install-path` in `installed.json`, same
  `$baseDir`-anchored rules in all five autoload files.

- **`archive`, `diagnose`, `create-project`, `global`, `browse` and
  `self-update`.** `archive` writes tar / tar.gz / zip honouring `.gitignore`
  and `archive.exclude`, and extracts to a tree identical to
  `composer archive`'s. `create-project` produces a project identical to
  `composer create-project`'s. `diagnose` checks the things whose failures
  present as something else — no `git` on PATH reads as a network problem, an
  unwritable cache makes every install re-download silently — and exits non-zero
  only on a genuine FAILURE, never on a warning, because it is a thing CI runs.

- **A composer-plugin report worth reading.** `compat`, run against an installed
  tree, now names each plugin, says whether the project allowed it, and says
  what that specific plugin would have done —
  `phpstan/extension-installer` generates a `GeneratedConfig.php`;
  `cweagans/composer-patches` leaves packages unpatched. A generic "plugins are
  not loaded" is not something a reader can act on.

  `composer/installers` **blocks** when it is installed and the root declares no
  `installer-paths`, because then every location would come from its built-in
  per-framework table, which is not implemented — and the result would be a tree
  in the wrong place rather than a tree with something missing.

- **`require` and `remove`.** The two commands that make this a package manager
  rather than a fast installer: everything before them could only act on
  requirements someone else had written down.

  They are built on a new `jsonedit.zig`, which edits `composer.json` by
  splicing bytes between two offsets rather than decoding and re-encoding.
  Re-encoding is the obvious approach and the wrong one — it rewrites key order,
  indentation, the blank line the author left between sections, and turns `1.0`
  into `1` — so a one-line change arrives as a diff nobody can review.

  Agreement is measured: **1920 operations that `Composer\Json\JsonManipulator`
  itself applied to 109 real manifests** are recorded in
  `src/testdata/jsonedit_corpus.json` as the minimal splice between input and
  output, and the test requires this package to produce the same bytes. It found
  a defect on its first run (a byte-offset bug in the corpus generator, not the
  code) and catches a single extra space when mutated.

  End to end, `require`, `require --dev`, `remove`, `remove --dev`,
  `remove 'symfony/*'` and a constraint-less `require` all produce a
  **byte-identical composer.json and composer.lock** to Composer's, including
  under `config.sort-packages`.

  On failure the manifest is **restored**. A `require` that leaves a package in
  composer.json but not the lock has moved the project into a state neither
  `install` nor `update` can explain, and the person who ran it has no reason to
  suspect the manifest was touched.

- **`config`, `init`, `audit`, `search`, `run-script`, `status`, `bump`,
  `reinstall`, `exec`, `clear-cache`, `suggests`, `fund`, `prohibits`, `home`,
  `about`.** `init` writes a file byte-identical to `composer init -n` given the
  same options — including Composer's key order, which is neither documented nor
  alphabetical. `bump` matches `composer bump`. `audit` reports the same 9 CVEs,
  severities and order as `composer audit --locked` on a vulnerable tree, and
  exits non-zero so a CI step FAILS rather than logging.

- **`scripts` run.** The install-lifecycle events (`pre`/`post-install-cmd`,
  `pre`/`post-update-cmd`, `pre`/`post-autoload-dump`) fire, with every entry
  form Composer supports: a shell command, `@another-script`, `@php`,
  `@composer`, `@putenv`, and a `Vendor\Class::method` callable run against the
  project's own autoloader. `--no-scripts` and `HKM_PPKG_NO_SCRIPTS=1` disable
  them.

  **Only the ROOT package's scripts are ever run.** A dependency's are read for
  reporting and never executed — Composer's rule too, and the reason running
  them by default is defensible: the commands executed are the ones in the
  manifest in front of the person who typed the command, not something that
  arrived in a tarball.

- **`config.vendor-dir` and `config.bin-dir`**, including `{$vendor-dir}`
  interpolation and the `COMPOSER_VENDOR_DIR` / `COMPOSER_BIN_DIR` overrides.
  Both were previously REFUSED by the compatibility audit, which was the right
  call while the installer wrote to a hardcoded `vendor/`.

  The work is in a new `layout.zig`, whose second half is a port of
  `Filesystem::findShortestPathCode` and `findShortestPath` — the functions that
  decide what `$baseDir` is in a generated autoload file and what a
  `vendor/bin` launcher includes. **832 rows generated by calling Composer's own
  implementations** hold it to them, and the corpus caught two real bugs in the
  port on its first run. With `vendor-dir: lib/vendor` all five autoload files
  are byte-identical to Composer's, as are `installed.php`'s `install_path`
  entries and the bin launchers.

- **`vcs` repositories (GitHub), without touching a rate-limited API.** This was
  the one blocking gap: in the workspace this was written for, 33 of 64 projects
  declared one and 32 of those named the same repository. The audit now reports
  **0 blocked**.

  Composer's `GitHubDriver` uses `api.github.com` — one call to list refs, then
  one per ref for that ref's composer.json — against 60 calls an hour
  unauthenticated. A plugin here declares **34 vcs repositories**, so one
  `composer update` exhausts the hour partway through and falls back to cloning
  every repository. Nothing here touches the API: refs come from
  `git ls-remote` (the git protocol, no quota), a ref's composer.json from
  `raw.githubusercontent.com` (static, no quota), and the archive from the
  zipball URL that redirects to codeload.

  Measured on that plugin: **composer 6m15s → 1.67s**. The two resolutions
  AGREE — same 71 packages, same versions, same commit references, same
  content-hash — and the plugin's own suite passes against the result:
  `OK (60 tests, 257 assertions)`.

  One defect surfaced by that comparison, and it was silent: `git ls-remote
  --refs` strips peeled entries, so an ANNOTATED tag was recorded at its
  tag-object sha rather than the commit's. A tag object has no tree, so
  `raw/<sha>/composer.json` returned 404 and the version vanished from the pool
  without a word. It cost one package out of 71; dropping `--refs` took the
  version count found across those repositories from 86 to **300**.

- **Closure discovery in parallel waves.** The solver used to meet each new
  package one at a time, each a serial round trip — 167 seconds of wall clock
  against 9 seconds of CPU, asleep on the network for 95% of it. The closure is
  now discovered a level at a time with every name in a level fetched at once:
  **167s → 0.83s**.

- **Two caches that were missing.** Ref listings get a 5-minute TTL
  (`--refresh` overrides), taking a repeat resolve's vcs phase from 10.5s to
  12ms. And an ABSENT `~dev.json` is now recorded: most packages have none, so a
  dev-stability project asked for a document that was not there once per package
  on every run — ten seconds of pure 404s against an otherwise fully cached
  closure.

- **Platform requirements.** `php`, `php-64bit`/`-zts`/`-debug`/`-ipv6`, `ext-*`
  and `composer-runtime-api`/`composer-plugin-api` are now determined from the
  interpreter (one `php -r` probe) and checked, with `config.platform`
  overriding any of it. `lib-*` is reported as `unmodelled` rather than passed
  silently — a requirement nobody checked must not read as a requirement that
  was met.
- **`check-platform-reqs`.** Checks the root's requirements and every installed
  package's. Verified against `composer check-platform-reqs` on a 107-package
  tree: same 18 distinct requirements, same two satisfied by a polyfill's
  `provide`, same verdict.
- **`replace`, `provide` and `conflict` in the solver.** A demand can now be
  answered by a package that provides the name rather than by fetching it —
  without which nothing requiring `ext-ctype` resolves on a machine that relies
  on `symfony/polyfill-ctype`. `replace` additionally forbids the replaced
  package; `conflict` is honoured in both declaration directions, since which of
  two packages is chosen first is an accident of search order.
- **`content-hash`**, with `hkm ppkg content-hash` to compute and compare it.
  Reproduces PHP's `json_encode($data, 0)` byte for byte, including escaped
  slashes, `\uXXXX` escapes with surrogate pairs, empty objects encoding as
  `[]`, and objects keyed `0..n-1` encoding as arrays. Checked differentially
  against `Locker::getContentHash` over **201 real composer.json files** —
  recorded in `src/testdata/contenthash_corpus.json` and run as a test.
- **Writing `composer.lock`, and `update`.** `hkm ppkg update` resolves
  composer.json and writes the lock; `--dry-run` reports what would change and
  touches nothing. Verified three ways: 76 real locks re-render byte-identically
  through `hkm ppkg lock --check`; `update` produces a **byte-identical** file to
  `composer update` on five differently-shaped projects; and Composer itself
  installs from a lock this wrote without reporting it out of date.
- **`hkm ppkg lock --check`** — is a lock in canonical form, and if not, which
  line differs.
- `phpjson.zig`: PHP's `json_encode` in both the configurations Composer uses,
  shared by the content hash and the lock writer. They disagree about every `/`
  and every non-ASCII character, three lines apart in Composer's own source.
- Initial extraction from the `hkm-kernel` tooling into a standalone package.
- `report.zig`: output is a sink of function pointers, defaulting to no-ops, so
  the library prints nothing until a host installs one.
- Regression test for stamping: a path repository is never stamped.

- **`hkm ppkg compat`, and a gate on `install` / `update`.** Three features were
  being ignored SILENTLY: a `vcs` repository (resolution fell through to the
  packagist package of the same name), `config.vendor-dir` (the tree landed in
  `vendor/` while the project looks in `lib/`), and `scripts` (never run, never
  mentioned). Each produced a finding — and all three are IMPLEMENTED by the
  entries above, so what `compat` refuses today is a much shorter list than the
  one it was written for. What remains is the rule: a finding BLOCKS when
  proceeding would give a wrong answer that looks right, and WARNS when the
  result is merely incomplete; `--ignore-unsupported` downgrades a block for an
  operator who knows better.

### Fixed

- **It builds with Zig 0.17 as well as 0.16.** hkm-kernel compiles this
  package into its launcher with a pinned Zig 0.17 development build, where
  array repetition with `**` no longer parses and `std.meta.fields` is a
  compile error. The one use of each now takes a form both versions accept
  (`@splat`, `std.enums.values`).

- **The global flags work on every command.** `-q`, `-n`, `-d`/`--working-dir`,
  `--no-cache`, `--ansi`/`--no-ansi` and `--no-plugins` were read only by the
  eight commands that change the tree; `show`, `validate`, `config`, `init` and
  the rest refused them as an unknown option, although the README and `--help`
  both said every command took them. They now apply to every command, and are
  accepted before the command word as well as after it (`ppkg -d app show`), as
  Composer accepts them. `exec` takes them only before the binary's name.

- **`vendor/bin` launchers are byte-identical now.** `BinaryInstaller` emits
  four different shapes and this emitted one: a shell proxy for a target that
  is not PHP, a PHP proxy, the same plus the PHP<8 stream wrapper, and
  PHPUnit's two extra workarounds. The wrapper had been left out on the
  reasoning that this platform requires PHP 8.4 — which does not survive being
  a general Composer replacement, because the tree is deployed to whatever PHP
  the PROJECT supports. On PHP 7 the omission printed a shebang into program
  output and resolved `__DIR__` inside the target to `vendor/bin`.

- **A path repository now produces an installable lock entry.** Its `dist`
  (`type`, `url`, and the `sha1(composer.json . serialize(options))` reference)
  and its defaulted `type: library` were missing, so `install` refused the
  package with "the lock records neither a zip/tar distribution nor a git
  source". The lock is byte-identical to Composer's now.

- **Nothing is written into a package directory any more.** The record of which
  reference each directory holds moved out of `.ppkg-ref` files and into one
  file in the cache (`stamps.zig`). Those files were a divergence from
  Composer's tree in every installed package — visible in `git status`, in a
  `diff -r`, in an `archive`, and to any deployment that verifies a tree by
  checksum.

- `--strict-psr` reported nothing for the case it exists for. A class whose
  namespace does not match the rule that claims it was treated as another
  rule's business; it is a violation, and Composer reports it as one.

- `config.platform-check` and the generated `platform_check.php` are now
  suppressed together when platform requirements are ignored.

- **A credential was never actually sent.** It was passed as a
  `privileged_header`, whose documentation says it is stripped on a cross-domain
  redirect and kept otherwise — but in Zig 0.16 `std.http.Client` writes
  `extra_headers` to the wire and nothing else, so a privileged header is
  validated, stored, cleared on redirect, and never transmitted. Every
  authenticated request went out anonymous. Found by a local server that refused
  a request the tool believed it had authenticated.

  Redirects are followed by hand now, with the credential looked up fresh for
  each hop's URL. That is stricter than the field it replaces: std's rule keeps
  a header across a *parent-domain* redirect, which would send a `github.com`
  token to any `*.github.com`; this sends a credential only to a host the
  operator configured, and re-derives it if the hop lands somewhere that has one
  of its own.

- **A `lib-*` requirement was never checked.** It came back as `unmodelled` and
  was reported as unchecked, which was the safe direction and meant a project
  declaring `lib-openssl: ^3.0` got no answer at all. `unmodelled` now means the
  one thing that is genuinely unknowable — no interpreter answered — and applies
  to every requirement in that case rather than to `lib-*` alone, because
  "this machine does not have ext-json" is a claim about a machine nobody
  managed to inspect.

- `installation-source` and the source-install path only recognised `git`, so a
  Mercurial or Subversion package was recorded as `dist`.

- `hg archive` writes a `.hg_archival.txt` describing the archive itself. It is
  Mercurial's metadata, not the package's, and it was landing in every vendor
  directory that came from a Mercurial repository.

- **`notification-url` was written for every non-path package**, including ones
  read from a git remote or declared inline. It belongs to the REPOSITORY, and
  Composer writes it only for a package packagist actually served — so every
  `vcs` package in a lock this wrote carried a claim that packagist had served
  something it has never seen.

- **`platform_check.php` was written even when there was nothing to check.**
  Composer deletes the file AND drops the `require` from `autoload_real.php`;
  this wrote a check-nothing file and kept the line. The two now move together —
  they have to, or a tree fatals on a missing include.

- **The autoloader suffix ignored the lock.** Composer's fallback, when no
  `vendor/autoload.php` exists to recover it from, is the lock's `content-hash`;
  this invented one from the package name. Every generated class name in a
  freshly installed tree differed from Composer's for no reason.

- **`install-path` was hardcoded as `../<name>`.** Composer computes it with
  `findShortestPath`, and the two disagree for any package under
  `vendor/composer/` — `composer/installers` is recorded by Composer as
  `./installers`.

- **A package installed outside `vendor/` was anchored at `$vendorDir`** in the
  generated autoloader, producing rules that point at a directory which does not
  exist. It is anchored at `$baseDir` now, which is what Composer emits.

- **A `license` string was written through unchanged.** `ArrayLoader` normalises
  it to an array, so `"license": "MIT"` in a manifest read off a disk or a git
  remote must become `["MIT"]` in the lock.

- **`installation-source` was always `dist`,** and `installed.php` recorded an
  empty `reference` for a source-installed package — the one thing
  `InstalledVersions::getReference()` exists to answer. A package with neither
  reference now records PHP `null`, not `''`, because those are different values
  to code that tests `=== null`.

- **A shallow `EnvMap` copy corrupted the caller's environment.**
  `var quiet = env.*` shares the backing store while carrying its own stale
  capacity; the first `put` wrote past the end of the original's key array. It
  panicked on the first non-GitHub repository this was pointed at.

- **`platform_check.php` carried the DONOR's PHP floor.** It was copied from a
  donor vendor tree alongside Composer's four genuine runtime files, and it is
  not one of them: Composer derives it from the installed packages' `php` and
  `ext-*` requirements. Installing a project requiring `^8.1` from a kernel
  checkout requiring `^8.4` produced a vendor tree that refused to boot on 8.1,
  8.2 and 8.3 — the versions the project declared support for. It is now
  generated (`platformcheck.zig`), and is byte-identical to Composer's in all
  three `config.platform-check` modes.

- **`autoload_real.php` referenced `…::$files` in projects that have none.**
  Composer emits that block only when the project has `autoload.files`, and
  emits the matching `public static $files` only then too — so the copied loader
  produced `Access to undeclared static property` at the top of every request in
  a tree where every package was correctly in place. The copied file is now
  adapted to the project it landed in, and `autoload_files.php` is deleted
  rather than written empty, which is what Composer does.

- **`>= 8.1` did not parse.** A constraint with a space between the operator and
  the version — accepted by Composer, and written that way in the wild — was
  rejected outright, and a constraint that will not parse is a requirement the
  resolver cannot evaluate at all. 165 rows covering every spaced form were
  added to the differential corpus, which now stands at 6046.

- **`zig build test` and `zig build check` were not analysing private call
  trees.** `refAllDecls` references a public function, which analyses its
  SIGNATURE and not its body, so a wrong argument count three calls down stayed
  invisible — both steps passed while `install.run` called a four-parameter
  function with three arguments, and only linking the host binary found it. The
  test block now takes the ADDRESS of each public entry point, which forces
  codegen and walks everything it calls.

- **`hkm ppkg require --dev` put the package in `require`.** The host launcher
  consumes `--dev` anywhere in its arguments to select the development kernel,
  and stripped it before the subcommand saw it — silently, with a success
  message. The flag is now left alone when it follows a subcommand that defines
  it; `hkm --dev ppkg require x` still selects the kernel.

- **`vendor/` now matches `composer install` file for file**, bar two `bin/`
  proxies. Six differences were found by diffing a real 37-package tree:
  the autoloader suffix (Composer derives it from the lock's content-hash; this
  inherited the donor's), the root package missing from `installed.php`
  `versions` (so `InstalledVersions::getVersion` could not answer for the
  application itself), virtual `provide`/`replace` entries missing entirely,
  `installed.json` needing its OWN key order distinct from the lock's,
  `installed.json` needing the runtime and dev sets merged and sorted by name
  rather than concatenated, and `NULL` where Composer writes `null`.
- **The root package version.** With no `.git` and no `version` in
  composer.json, this recorded `dev-main` — a branch that may not exist. It now
  records `1.0.0+no-version-set` / `1.0.0.0` / `reference => null`, as Composer
  does, and an explicit `version` in composer.json wins outright.

- `zig build check`: plain `zig build` compiled nothing, because the package
  installs no artifact. The CI compile and cross-compile jobs written against it
  would have been green for every target regardless of whether the code built.
- The version-normalisation test's table of 81 real (version, version_normalized)
  pairs was empty, so the test asserted nothing while reading as the strongest
  one in the file. The pairs are present and a mutation confirms they run.
- A stamp file was written into path repositories. Because `vendor/<name>` for
  a path repo is a symlink into the user's own project, the write landed in
  their source checkout — leaving an untracked file in a git repository this
  tool has no business writing to. Stamps have since moved out of the vendor
  tree entirely (see `stamps.zig`), which removes the case rather than guarding
  it.

### Changed

- **The build module is named `ppkg`, not `pkg`**, matching the package name
  and what this README always told consumers to import:
  `b.dependency("hkm_ppkg", .{}).module("ppkg")`. `zig build` now builds the
  `ppkg` binary; it used to build nothing.

- `project.Installation.upgradeCommand` takes an allocator and the
  executable's path, so the Homebrew advice names the formula actually
  installed (`brew upgrade ppkg`, not always `brew upgrade hkm`). A binary under
  `~/.local/bin` — where both installers put one — is recognised as an
  installer install.

- `list` no longer means `show`. `hkm ppkg list` prints the command index,
  which is what a newcomer types it for and what Composer does with it; `hkm
  ppkg show` still lists installed packages.

- `install --prefer-source` leaves a git working copy where it previously left
  an export. A `vcs` package with no dist at all still gets the export: nothing
  was promised about `.git` there, and the smaller tree is the better default.

- The unpack staging directory is `<dest>.ppkg-unpack`. Existing trees
  re-install once; nothing is lost, because the stamp only decides whether
  extraction can be skipped.
