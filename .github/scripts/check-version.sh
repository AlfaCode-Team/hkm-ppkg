#!/usr/bin/env sh
# ---------------------------------------------------------------------------
# check-version.sh VERSION — refuse a release the repository does not agree with.
#
#   .github/scripts/check-version.sh 0.2.0
#
# A release version is written in three places, and all three must say the
# same thing before a tag is cut:
#
#   CHANGELOG.md    the "## [X.Y.Z]" heading — what auto-release reads, and
#                   what becomes the release notes
#   build.zig.zon   `.version` — what `ppkg --version` reports (build.zig
#                   stamps it), and what a Zig consumer of the package sees
#   the tag         vX.Y.Z
#
# Run by auto-release.yml BEFORE it pushes the tag, so a mismatch stops the
# release with nothing published and no tag to clean up — and by release.yml
# again, for a tag pushed by hand.
# ---------------------------------------------------------------------------
set -eu

VERSION="${1:?usage: check-version.sh X.Y.Z}"
cd "$(dirname "$0")/../.."

fail() {
  # GitHub renders ::error:: as an annotation on the run; locally it is a line.
  echo "::error::$*" >&2
  exit 1
}

echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || fail "'$VERSION' is not a release version (X.Y.Z or X.Y.Z-pre)."

ZON="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon | head -n 1)"
[ "$ZON" = "$VERSION" ] \
  || fail "build.zig.zon says .version = \"$ZON\" but this release is $VERSION. Bump build.zig.zon in the same change as the CHANGELOG heading."

# index()==1: the heading must START the line, so a version quoted in prose
# ("fixed since ## [0.1.0]") cannot satisfy it.
awk -v v="$VERSION" 'index($0, "## [" v "]") == 1 { found = 1 } END { exit !found }' CHANGELOG.md \
  || fail "CHANGELOG.md has no \"## [$VERSION]\" heading."

echo "version $VERSION: CHANGELOG.md, build.zig.zon and tag agree"
