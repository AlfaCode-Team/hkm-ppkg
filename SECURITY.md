# Security Policy

Thank you for helping keep `hkm-ppkg` and the projects that depend on it safe.

## Why this file is not boilerplate

A package manager is a supply-chain component. It downloads archives from the
network, verifies (or fails to verify) their integrity, unpacks them onto a
developer's filesystem, and generates the PHP file that decides which class
every subsequent `require` resolves to. A defect here is not a bug in an
application — it is a bug in every application built with it, arriving through a
tool people run without reading its output.

Classes of report that are always in scope, even without a working exploit:

- **Archive extraction.** Any path in a zip that escapes the destination
  directory — `../`, an absolute path, a symlink entry pointing outside the
  tree, a name that normalises differently on macOS than on Linux.
- **Integrity.** A dist installed when its `shasum` did not match, or when the
  lock recorded no shasum at all and nothing said so.
- **Cache poisoning.** Any way one package's download can be served for another,
  or a cache key that is not bound to the immutable reference it claims.
- **Transport.** A plaintext fetch, a redirect followed to a different host, or
  a certificate check that can be skipped.
- **Generated output.** Anything that gets a package's own strings into
  generated PHP as code rather than as data — `autoload_static.php` is written
  from names that came off the network.
- **Writes outside the project.** This tool writes into `vendor/` and its cache.
  A path under which it writes anywhere else is a bug regardless of impact; one
  such defect once left a file in a contributor's own git checkout.

Out of scope: vulnerabilities in packages this tool installs (report those to
their maintainers), and Composer's own behaviour when this tool reproduces it
faithfully — though tell us, because we may be reproducing it in a context where
it matters more.

## Reporting a vulnerability

**Please do NOT report security vulnerabilities through public GitHub issues,
pull requests, or discussions.**

Use one of these private channels instead:

1. **GitHub Security Advisories (preferred).** Use the repository's
   **Security → Advisories → Report a vulnerability** page
   ([Private vulnerability reporting](../../security/advisories/new)). This keeps
   the report confidential and lets us work on a fix with you.
2. **Email.** Send details to **shamavurasheed@gmail.com** with the subject line
   `SECURITY: hkm-ppkg`.

### What to include

- What the vulnerability is and what it lets an attacker do.
- The affected commit or tag.
- A `composer.json` / `composer.lock` or crafted archive that reproduces it, if
  you have one. A failing test case is the most useful thing you can send.
- Anything you know about exploitability in practice.

### What to expect

- **Acknowledgement within 72 hours.**
- An initial assessment, and our view of severity, within 7 days.
- Regular updates while a fix is prepared.
- Credit in the advisory and the release notes, unless you would rather not be
  named.

Please give us reasonable time to release a fix before disclosing publicly. We
will tell you when a fix ships, and we would rather coordinate the announcement
with you than surprise you with it.

## Supported versions

This package is pre-1.0. Fixes are provided for the latest tag only; there is no
backport branch, and pinning an old tag means pinning its bugs. Once a `v1.0.0`
is cut, this section will say something more useful than that.

| Version | Supported |
|---|---|
| Latest tag | :white_check_mark: |
| Anything older | :x: — upgrade |

## A standing caveat

Several protections a mature package manager has are **not implemented yet**,
and their absence is documented rather than hidden. See "What it does not do" in
the [README](README.md): platform requirements are not verified, `auth.json` is
not read, and `scripts` never run. The last of those is a security property by
accident rather than by design — do not rely on it as a sandbox.
