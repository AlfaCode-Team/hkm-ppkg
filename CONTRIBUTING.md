# Contributing to hkm-ppkg

Thanks for wanting to help.

This is a package manager. The cost of a wrong answer here is not a bad user
experience — it is a `vendor/` tree that loads a different class than the one
the author wrote, on someone else's machine, at a moment nobody is watching.
Almost everything below follows from that.

## The rule that matters most

**A claim about Composer's behaviour must be checked against Composer, not
against Composer's documentation.**

Four bugs in the constraint code were found this way, and none of them were
findable by reading it: `~1.2`'s upper bound, branch-alias padding, `X.Y.x-dev`
being an exact match rather than a range, and a bare `1.0` being an exact pin
rather than a series. Each was a coherent, confident, wrong belief about what a
line of PHP does, and each produced code that compiled and looked correct.

So if you change `constraint.zig`, add rows to the corpus:

```sh
# Print each (version, constraint) pair through Composer's own implementation.
php -r 'require "vendor/autoload.php";
        var_dump(Composer\Semver\Semver::satisfies($v, $c));'
```

`src/testdata/semver_corpus.json` holds 5881 such rows as
`[version, constraint, answer]`, and the test in `constraint.zig` runs every one
of them. **Adding a row whose answer you decided yourself defeats the entire
mechanism.** The answer must come from Composer.

`src/testdata/contenthash_corpus.json` works identically for `contenthash.zig`:
201 real composer.json files paired with what
`Composer\Package\Locker::getContentHash` returns for them. Regenerate it by
running that method over real files — never by writing down what you believe
`json_encode` produces, because the three details that decide it (escaped
slashes, `{}` becoming `[]`, and objects keyed `0..n-1` becoming arrays) are
exactly the ones a careful reading gets wrong.

The same applies to `autoload.zig`. Its test of record is not a unit test — it
is generating all five files for a real project and diffing them byte-for-byte
against `composer dump-autoload`, with and without `-o`. If your change passes
`zig build test` but you have not done that diff, you have not tested it.

## Getting set up

```sh
zig build               # the ppkg binary → zig-out/bin/ppkg
zig build test          # every test, including the differential corpora
zig build check         # compile only; add -Dtarget=… to cross-compile
```

`check` compiles both the library and the `ppkg` binary for a target without
running either, and CI runs it for every target in `.github/targets.txt` — the
same list a release ships.

Zig version is pinned in `.zig-version`. No other dependencies — that is
deliberate, and a PR that adds one needs to argue for it.

## Style

Match the surrounding code. Two things about it are not negotiable:

**Comments explain *why*, and specifically why the obvious thing is wrong.**
This codebase is full of decisions that look arbitrary until you know what
happens without them — Composer's two different package walk orders, the
autoloader suffix that must be recovered rather than regenerated, the
`install-path` for a path repository being the symlink and not the target. A
comment that says *what* the line does is noise. A comment that says which bug
the line prevents is the reason the next person does not reintroduce it.

**Errors say what was actually observed.** `exhausted` and `unsatisfiable` are
different outcomes in `solver.zig` and must never be collapsed: this solver can
give up on a problem that does have a solution, and reporting "impossible" when
the honest answer is "I stopped looking" sends someone off to rewrite a
`composer.json` that was fine.

## Tests

Every behavioural change needs a test. In rough order of preference:

1. A row in the differential corpus (constraints).
2. A byte-for-byte comparison against Composer's output (autoload, installed.json).
3. A unit test over a pure function — extract the predicate if you have to. The
   guard against stamping a path repository is a four-line test over
   `stampable()`, and it exists because the bug it prevents wrote a file into a
   contributor's own git checkout.

Note that Zig only compiles what is referenced. A file not reachable from
`src/root.zig` is a file whose compile errors nobody sees, so add new modules
there.

## Commits and pull requests

- Conventional Commits: `fix:`, `feat:`, `docs:`, `refactor:`, `test:`, `ci:`.
- One logical change per PR. A rename bundled with a behaviour change is two
  PRs, because the diff of the second is unreviewable inside the first.
- Say in the PR description what you did **not** verify. "Tests pass" is a weak
  claim about a package manager and must never be offered as evidence that the
  output is correct.
- CI must be green.

## Releasing

A release is a CHANGELOG change merged to `main`. Nothing else is done by hand.

1. In one pull request, promote `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   **and** set `.version = "X.Y.Z"` in `build.zig.zon`. Always both:
   `.github/scripts/check-version.sh X.Y.Z` refuses a release where they
   differ, and it runs before any tag exists. Run it locally first.
2. Merge it. `auto-release.yml` sees the new heading, pushes `vX.Y.Z` and runs
   `release.yml`: the suite on Linux and macOS; every target in
   `.github/targets.txt` cross-compiled by `.github/scripts/package.sh`; the
   archives installed through `install.sh` / `install.ps1` and run on Linux
   x86_64 and aarch64, macOS and Windows; then the release itself, its notes
   taken from the CHANGELOG section and `SHA256SUMS` attached.

A `-rc.1`-style suffix publishes a pre-release. Treat a published tag as
permanent — if a release is wrong, fix forward with the next patch version.

`main` is protected the way hkm-kernel's is: one code-owner approval, required
checks, linear history, and no bypass for admins. So step 2 is a pull request
someone other than its author approves. `.github/scripts/protect-main.sh`
re-applies that protection, and the check names in it must match the job names
in `ci.yml` — a renamed job leaves every pull request waiting on a check that
never reports.

## Scope

This package deliberately does less than Composer. Before proposing a feature,
check the "What it does not do" section of the README — some of those omissions
are gaps worth filling (`replace`/`conflict`/`provide`, platform requirements,
writing `composer.lock`) and some are deliberate (running `scripts`, cloning
sources). Open an issue before building something large; a resolver rewrite is
not a first PR.

## Reporting bugs

Include the `composer.json`, the relevant part of `composer.lock`, what Composer
does, and what this does. A difference from Composer is the bug report — you do
not need to work out which line is wrong.

Security issues go through [SECURITY.md](SECURITY.md), never a public issue.

## Licence

By contributing you agree that your contributions are licensed under the
[MIT Licence](LICENSE).
