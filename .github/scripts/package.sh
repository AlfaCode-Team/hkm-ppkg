#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# package.sh VERSION [OUT] — build every release archive, plus SHA256SUMS.
#
#   .github/scripts/package.sh 0.2.0          # → dist/
#
# The single source of truth for what a release contains. release.yml calls
# it; running it locally produces byte-for-byte the same file list, which is
# how a change to packaging is checked before it ships.
#
# Every target is CROSS-COMPILED from one machine — Zig needs no SDK, sysroot or
# runner per platform. Linux builds are static (musl), so one binary runs on
# every distribution regardless of its libc.
#
# Asset names carry NO version (`ppkg-linux-x86_64.tar.gz`) so that
#   https://github.com/<repo>/releases/latest/download/<asset>
# is a stable URL: install.sh / install.ps1 fetch it without asking the API
# which release is newest, and so without its rate limit. The version is on the
# folder inside the archive and in `ppkg --version`.
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="${1:?usage: package.sh VERSION [OUT]}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${2:-$ROOT/dist}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
TARGETS="$ROOT/.github/targets.txt"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"

# Composer's ClassLoader.php and InstalledVersions.php are embedded in the
# binary (src/res/), and their MIT licence requires the notice to travel with
# every copy. It ships beside the binary as LICENSE-composer.
[ -f src/res/LICENSE ] || { echo "src/res/LICENSE is missing — refusing to ship Composer's code without it" >&2; exit 1; }

# ReleaseSafe keeps every bounds and overflow check — this binary unpacks
# archives from the internet. Stripped, because the debug info is most of an
# unstripped ELF (13 MB against 3) and a panic still prints its message.
grep -Ev '^[[:space:]]*(#|$)' "$TARGETS" | while read -r target name cpu; do
  echo "── $name ($target${cpu:+, cpu $cpu})"
  zig build -Dtarget="$target" ${cpu:+-Dcpu="$cpu"} -Doptimize=ReleaseSafe -Dstrip=true \
    -Dversion="$VERSION" -p "$STAGE/$name/out"

  case "$name" in
    windows-*) exe="ppkg.exe" ;;
    *)         exe="ppkg" ;;
  esac

  folder="ppkg-$VERSION-$name"
  dir="$STAGE/$name/$folder"
  mkdir -p "$dir"
  cp "$STAGE/$name/out/bin/$exe" "$dir/"
  cp LICENSE README.md CHANGELOG.md "$dir/"
  cp src/res/LICENSE "$dir/LICENSE-composer"

  # zip for Windows, where Explorer opens it natively; tar.gz everywhere else,
  # because it keeps the executable bit a zip does not reliably carry.
  case "$name" in
    windows-*) (cd "$STAGE/$name" && zip -qr "$OUT/ppkg-$name.zip" "$folder") ;;
    *)         tar -C "$STAGE/$name" -czf "$OUT/ppkg-$name.tar.gz" "$folder" ;;
  esac
done

cp install.sh install.ps1 "$OUT/"

# One checksum file covering every asset, installers included. Both installers
# refuse an archive that does not match it.
(
  cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- * > SHA256SUMS
  else
    shasum -a 256 -- * > SHA256SUMS
  fi
)

echo
echo "dist: $OUT"
ls -l "$OUT"
