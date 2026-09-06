<!--
  Thanks for contributing. See CONTRIBUTING.md — particularly the section on
  checking claims about Composer against Composer.
-->

## Summary

<!-- What does this change, and why? Link the issue it closes. -->

Closes #

## Type of change

- [ ] 🐛 Bug fix (non-breaking)
- [ ] ✨ Feature (non-breaking)
- [ ] 💥 Breaking change
- [ ] 📝 Documentation only
- [ ] 🧹 Refactor / chore (no behaviour change)

## Does this change the vendor tree it produces?

<!--
  The question that matters most. A change can be API-compatible and still make
  a different vendor/ appear on someone's machine — a different autoloader, a
  different resolved version, a package skipped or re-extracted.
-->

- [ ] No — output is byte-identical for the same inputs.
- [ ] Yes, and I have described the difference below and added it to `CHANGELOG.md`.

## Verification

<!--
  "Tests pass" is a weak claim about a package manager. Say what you actually
  ran and what you compared it against.
-->

```bash
zig build test
```

- [ ] `zig build test` passes.
- [ ] `zig fmt --check build.zig src` is clean.
- [ ] **Constraints:** if I changed `constraint.zig`, I added rows to
      `src/testdata/semver_corpus.json` whose answers came from
      `Composer\Semver\Semver`, not from my own reading.
- [ ] **Autoloader:** if I changed `autoload.zig`, I generated all five files for
      a real project and diffed them byte-for-byte against
      `composer dump-autoload`, with and without `-o`.
- [ ] I added a test for the behaviour I changed.

## What I did NOT verify

<!--
  Please fill this in honestly; it is the most useful part of the description.
  "Not tested on Windows", "not tried against a lock with no shasum", "only
  exercised through the hkm launcher" are all worth knowing.
-->

## Notes for reviewers
