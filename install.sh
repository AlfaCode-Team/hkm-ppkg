#!/bin/sh
# ---------------------------------------------------------------------------
# install.sh — install ppkg for the CURRENT USER, on Linux, macOS or FreeBSD.
#
# No root. Nothing is written outside the install directory.
#
#   curl -fsSL https://raw.githubusercontent.com/AlfaCode-Team/hkm-ppkg/main/install.sh | sh
#
#   sh install.sh                          # the latest release
#   sh install.sh --version v0.2.0         # a specific release
#   sh install.sh --archive ./ppkg-linux-x86_64.tar.gz   # a file already here
#   PPKG_INSTALL_DIR=/usr/local/bin sh install.sh        # somewhere else
#
# Installs one file: $PPKG_INSTALL_DIR/ppkg  (default: ~/.local/bin/ppkg).
# Re-running it upgrades in place.
#
# Every download is checked against the release's SHA256SUMS before anything
# is installed, and a mismatch stops the install. Windows: use install.ps1.
# ---------------------------------------------------------------------------
set -eu

REPO="${PPKG_REPO:-AlfaCode-Team/hkm-ppkg}"
BINDIR="${PPKG_INSTALL_DIR:-$HOME/.local/bin}"
VERSION=""
ARCHIVE=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B='\033[36m'; C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_0='\033[0m'
else
  C_B=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi
say()  { printf "${C_B}▶${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}✓${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}!${C_0} %s\n" "$*" >&2; }
die()  { printf "${C_R}✗${C_0} %s\n" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   [ $# -ge 2 ] || die "--version needs a tag, e.g. v0.2.0"; VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --archive)   [ $# -ge 2 ] || die "--archive needs a path"; ARCHIVE="$2"; shift 2 ;;
    --archive=*) ARCHIVE="${1#*=}"; shift ;;
    -h|--help)   sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# A bare "0.2.0" is what people type; the tag is "v0.2.0".
case "$VERSION" in
  ''|v*) ;;
  *) VERSION="v$VERSION" ;;
esac

# ── which build ─────────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux)   OS=linux ;;
  Darwin)  OS=macos ;;
  FreeBSD) OS=freebsd ;;
  MINGW*|MSYS*|CYGWIN*) die "on Windows, use install.ps1 (PowerShell)" ;;
  *) die "no ppkg build for $(uname -s) — build from source: zig build -Doptimize=ReleaseSafe" ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  armv7*|armv8l) ARCH=armv7 ;;
  riscv64)       ARCH=riscv64 ;;
  *) die "no ppkg build for $(uname -m) — build from source: zig build -Doptimize=ReleaseSafe" ;;
esac

# A shell running under Rosetta reports x86_64 on Apple Silicon. The native
# build is the right one to install either way.
if [ "$OS" = macos ] && [ "$ARCH" = x86_64 ] \
   && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  ARCH=aarch64
fi

ASSET="ppkg-$OS-$ARCH.tar.gz"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t ppkg)"
trap 'rm -rf "$TMP"' EXIT INT TERM

fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256 >/dev/null 2>&1; then   # FreeBSD
    sha256 -q "$1"
  else
    return 1
  fi
}

# verify FILE NAME SUMS — NAME is the asset's name in SHA256SUMS.
verify() {
  want="$(awk -v n="$2" '$2 == n || $2 == "*" n { print $1 }' "$3")"
  [ -n "$want" ] || die "$2 is not listed in SHA256SUMS"
  have="$(sha256_of "$1")" || die "no sha256 tool found (sha256sum, shasum or sha256) — cannot verify the download"
  [ "$have" = "$want" ] || die "checksum mismatch for $2 — expected $want, got $have. Nothing was installed."
  ok "checksum verified"
}

# ── get the archive ─────────────────────────────────────────────────────────
if [ -n "$ARCHIVE" ]; then
  [ -f "$ARCHIVE" ] || die "no such file: $ARCHIVE"
  say "installing from $ARCHIVE"
  cp "$ARCHIVE" "$TMP/$ASSET"
  sums="$(dirname "$ARCHIVE")/SHA256SUMS"
  if [ -f "$sums" ]; then
    verify "$TMP/$ASSET" "$(basename "$ARCHIVE")" "$sums"
  else
    warn "no SHA256SUMS beside $ARCHIVE — the archive is NOT verified"
  fi
else
  if [ -n "$VERSION" ]; then
    BASE="https://github.com/$REPO/releases/download/$VERSION"
  else
    BASE="https://github.com/$REPO/releases/latest/download"
  fi
  say "downloading $ASSET (${VERSION:-latest})"
  fetch "$BASE/$ASSET" "$TMP/$ASSET" || die "download failed: $BASE/$ASSET"
  fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" || die "download failed: $BASE/SHA256SUMS"
  verify "$TMP/$ASSET" "$ASSET" "$TMP/SHA256SUMS"
fi

# ── install ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/x"
tar -xzf "$TMP/$ASSET" -C "$TMP/x" || die "could not unpack $ASSET"
BIN="$(find "$TMP/x" -type f -name ppkg | head -n 1)"
[ -n "$BIN" ] || die "$ASSET holds no ppkg binary"

mkdir -p "$BINDIR" || die "cannot create $BINDIR"
# Staged beside the target and renamed over it, so a running `ppkg` — or an
# interrupted install — never sees a half-written file.
cp "$BIN" "$BINDIR/.ppkg.new"
chmod 755 "$BINDIR/.ppkg.new"
mv -f "$BINDIR/.ppkg.new" "$BINDIR/ppkg"

ok "installed $("$BINDIR/ppkg" --version) → $BINDIR/ppkg"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *)
    warn "$BINDIR is not on your PATH. Add it — for example:"
    # $PATH is literal on purpose: this prints a line for the user to paste, and
    # it must expand in THEIR shell when ~/.profile runs, not in this one now.
    # shellcheck disable=SC2016
    printf '    echo '\''export PATH="%s:$PATH"'\'' >> ~/.profile\n' "$BINDIR" >&2
    ;;
esac
