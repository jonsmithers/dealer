#!/bin/sh
# Builds GhosttyKit.xcframework from a Ghostty checkout and copies it into vendor/.
#
# Usage: scripts/build-ghosttykit.sh [options] [path/to/ghostty]
#   --ghostty PATH   Ghostty checkout (same as the positional argument or $GHOSTTY_SRC)
#   --out DIR        where to put GhosttyKit.xcframework (default: <repo>/vendor)
#   --any-version    build even if the checkout isn't at the commit in scripts/ghostty.version
#   --dry-run        resolve everything and print what would run; don't build or copy
#   --no-patch       build Ghostty's stock way, which needs full Xcode + its Metal Toolchain
#   --compile-metallib  regenerate scripts/ghostty-build/<pin>.metallib first (needs Xcode's metal)
#
# By default this needs only zig and the Command Line Tools: Ghostty is built from a temporary
# clone with Dealer's patch and a precompiled shader library (scripts/ghostty-build/README.md).
#
# The checkout is found in this order: --ghostty / positional / $GHOSTTY_SRC, then a `ghostty`
# directory next to this repo (next to the main checkout too, when run from a git worktree),
# then an interactive prompt if stdin is a terminal.
#
# Environment: GHOSTTY_SRC (checkout), ZIG (zig binary to use).
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
PIN=$(grep -v '^#' "$REPO/scripts/ghostty.version" | tr -d '[:space:]')
CLONE="git clone https://github.com/ghostty-org/ghostty.git \"$(dirname "$REPO")/ghostty\""

GHOSTTY=${GHOSTTY_SRC:-}
OUT="$REPO/vendor"
ANY=0
DRY=0
NOPATCH=0
COMPILE_METALLIB=0
while [ $# -gt 0 ]; do
  case $1 in
    --ghostty) GHOSTTY=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --any-version) ANY=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    --no-patch) NOPATCH=1; shift ;;
    --compile-metallib) COMPILE_METALLIB=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) GHOSTTY=$1; shift ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
is_ghostty() { [ -f "$1/build.zig" ] && [ -f "$1/include/ghostty.h" ]; }

# 1. Explicit path, 2. sibling of this repo (and of the main checkout, for worktrees), 3. prompt.
if [ -z "$GHOSTTY" ]; then
  MAIN=$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd || echo "$REPO")
  for c in "$(dirname "$REPO")/ghostty" "$(dirname "$MAIN")/ghostty"; do
    if is_ghostty "$c"; then GHOSTTY=$c; break; fi
  done
fi
if [ -z "$GHOSTTY" ] && [ -t 0 ]; then
  printf 'Path to your Ghostty checkout (blank to abort): '
  read -r GHOSTTY
  case $GHOSTTY in "~"/*) GHOSTTY="$HOME/${GHOSTTY#\~/}" ;; esac
fi
[ -n "$GHOSTTY" ] || die "no Ghostty checkout found. Clone one next to this repo:
  $CLONE
or pass its path: scripts/build-ghosttykit.sh --ghostty PATH (or set GHOSTTY_SRC)."
GHOSTTY=$(cd "$GHOSTTY" 2>/dev/null && pwd) || die "not a directory: $GHOSTTY"
is_ghostty "$GHOSTTY" || die "$GHOSTTY doesn't look like a Ghostty checkout (no build.zig / include/ghostty.h)"

# Version pin. ghostty.h is an unstable internal API; other commits usually don't compile with
# our Swift code, and newer ones need a newer zig.
HEAD=$(git -C "$GHOSTTY" rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$HEAD" != "$PIN" ]; then
  MSG="$GHOSTTY is at $HEAD, but scripts/ghostty.version pins $PIN."
  if git -C "$GHOSTTY" cat-file -e "$PIN^{commit}" 2>/dev/null; then
    FIX="git -C \"$GHOSTTY\" checkout --detach $PIN"
  else
    FIX="git -C \"$GHOSTTY\" fetch origin && git -C \"$GHOSTTY\" checkout --detach $PIN"
  fi
  if [ $ANY = 1 ]; then
    echo "warning: $MSG Building anyway (--any-version); expect C API drift in the Swift code." >&2
  else
    die "$MSG
Check out the pinned commit (and switch back afterwards if you like):
  $FIX
or rerun with --any-version to build this commit anyway."
  fi
fi

# zig: Ghostty's build.zig.zon says which version it needs (0.17.x for the pinned commit).
NEED=$(sed -n 's/.*minimum_zig_version *= *"\([0-9]*\.[0-9]*\).*/\1/p' "$GHOSTTY/build.zig.zon")
if [ -z "${ZIG:-}" ]; then
  for z in "/opt/homebrew/opt/zig@$NEED/bin/zig" "/usr/local/opt/zig@$NEED/bin/zig" "$(command -v zig || true)"; do
    if [ -x "$z" ]; then ZIG=$z; break; fi
  done
fi
[ -n "${ZIG:-}" ] || die "zig $NEED not found. Install it with: brew install zig@$NEED (or set ZIG)"
HAVE=$("$ZIG" version)
case $HAVE in
  "$NEED".*) ;;
  *) die "$ZIG is zig $HAVE, but this Ghostty commit needs zig $NEED.x. Install it with: brew install zig@$NEED (or set ZIG)" ;;
esac

# Fail early, before a slow build, when a tool this build needs is missing.
need_xcode_tool() {
  xcrun -sdk macosx -f "$1" >/dev/null 2>&1 || die "\`$1\` not found: $2 needs full Xcode with its Metal Toolchain
(xcodebuild -downloadComponent MetalToolchain). Without Xcode, use the default build (no $2)."
}
if [ $NOPATCH = 1 ]; then
  need_xcode_tool metal --no-patch
  xcodebuild -version >/dev/null 2>&1 || die "xcodebuild not found: --no-patch needs full Xcode, not just the Command Line Tools."
fi
if [ $COMPILE_METALLIB = 1 ]; then need_xcode_tool metal --compile-metallib; fi
command -v lipo >/dev/null 2>&1 || die "lipo not found: install the Command Line Tools (xcode-select --install)."

# =================================================================================================
# Building without Xcode (#42). Everything for this lives in scripts/ghostty-build/; its README.md
# explains each file and how to remove the mechanism (this block and the two options above).
# Sets SRC, the tree to build in (a patched temporary clone), and EXTRA, extra zig build flags.
# =================================================================================================
GB="$REPO/scripts/ghostty-build"
SHORT=$(printf %.12s "$HEAD")
SRC=$GHOSTTY
EXTRA=
TREE=
shaders_sha256() { git -C "$GHOSTTY" show "$HEAD:src/renderer/shaders/shaders.metal" | shasum -a 256 | cut -d' ' -f1; }
compile_metallib() {  # regenerate $GB/$SHORT.metallib and its provenance from the checkout
  IR=$(mktemp "${TMPDIR:-/tmp}/ghostty-ir.XXXXXX")
  git -C "$GHOSTTY" show "$HEAD:src/renderer/shaders/shaders.metal" > "$IR.metal"
  xcrun -sdk macosx metal -o "$IR" -c "$IR.metal" -mmacos-version-min=13.0.0
  xcrun -sdk macosx metallib -o "$GB/$SHORT.metallib" "$IR"
  rm -f "$IR" "$IR.metal"
  cat > "$GB/$SHORT.metallib.txt" <<PROVENANCE
# Provenance of $SHORT.metallib, Ghostty's compiled Metal shaders (opaque; see README.md).
pin=$HEAD
# sha256 of src/renderer/shaders/shaders.metal at the pin (the only Metal source); checked before use.
shaders_sha256=$(shaders_sha256)
metallib_sha256=$(shasum -a 256 "$GB/$SHORT.metallib" | cut -d' ' -f1)
compiled_with=$(xcodebuild -version | tr '\n' ' ')/ $(xcrun -sdk macosx metal --version | head -1)
# Regenerate with: scripts/build-ghosttykit.sh --compile-metallib, which runs the same commands as
# Ghostty's own MetallibStep.zig (its output is byte-identical to the stock build's):
#   xcrun -sdk macosx metal -o Ghostty.ir -c src/renderer/shaders/shaders.metal -mmacos-version-min=13.0.0
#   xcrun -sdk macosx metallib -o $SHORT.metallib Ghostty.ir
PROVENANCE
  echo "regenerated $GB/$SHORT.metallib"
}
prepare_patched_tree() {
  for f in patch metallib metallib.txt; do
    [ -f "$GB/$SHORT.$f" ] || die "no $GB/$SHORT.$f for Ghostty $HEAD. After a pin bump, follow
\"Pin bumps\" in scripts/ghostty-build/README.md, or build the stock way with --no-patch (needs Xcode)."
  done
  WANT=$(sed -n 's/^shaders_sha256=//p' "$GB/$SHORT.metallib.txt")
  GOT=$(shaders_sha256)
  [ "$GOT" = "$WANT" ] || die "Ghostty's shaders.metal at $HEAD (sha256 $GOT) isn't the one
$SHORT.metallib was compiled from ($WANT). Regenerate it on a Mac with Xcode: --compile-metallib."
  [ "$(shasum -a 256 "$GB/$SHORT.metallib" | cut -d' ' -f1)" = "$(sed -n 's/^metallib_sha256=//p' "$GB/$SHORT.metallib.txt")" ] \
    || die "$GB/$SHORT.metallib doesn't match the metallib_sha256 in $SHORT.metallib.txt"
  EXTRA="-Dmetallib=\"$GB/$SHORT.metallib\""
  if [ $DRY = 1 ]; then SRC="<temporary clone of $GHOSTTY with $SHORT.patch>"; return; fi
  TREE=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-patched.XXXXXX")
  git clone -q --shared "$GHOSTTY" "$TREE"
  git -C "$TREE" -c advice.detachedHead=false checkout -q --detach "$HEAD"
  git -C "$TREE" apply "$GB/$SHORT.patch" || die "$GB/$SHORT.patch doesn't apply to Ghostty $HEAD"
  SRC=$TREE
}
if [ $COMPILE_METALLIB = 1 ] && [ $DRY = 0 ]; then compile_metallib; fi
if [ $NOPATCH = 0 ]; then prepare_patched_tree; fi
# ===================================== end of the #42 block ======================================

echo "ghostty: $GHOSTTY @ $HEAD"
if [ $NOPATCH = 1 ]; then echo "build:   stock (needs Xcode), in the checkout"
else echo "build:   $SRC + -Dmetallib (no Xcode needed)"; fi
echo "zig:     $ZIG ($HAVE)"
echo "output:  $OUT/GhosttyKit.xcframework"
# The xcframework build also installs Ghostty's resources (shell integration, themes, terminfo)
# under the install prefix. A fresh prefix keeps stale files from older builds out of them and
# leaves the checkout's own zig-out alone; the framework itself always goes to macos/.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ghosttykit-prefix.XXXXXX")
trap 'rm -rf "$STAGE" ${TREE:+"$TREE"}' EXIT
# The pin check (#35) reads the commit from the version string Ghostty embeds. Off a tag that's
# `X.Y.Z-<branch>+<hash>`, but at a release tag (v1.4.0, #85) Ghostty's build records a bare
# `X.Y.Z`, so name the commit ourselves as semver build metadata: `X.Y.Z+<hash>` (no pre-release
# part, so Ghostty still treats it as a stable release).
VERSION_FLAG=
if git -C "$GHOSTTY" describe --exact-match --tags "$HEAD" >/dev/null 2>&1; then
  ZON_VERSION=$(sed -n 's/^ *\.version *= *"\([0-9][0-9.]*\)".*/\1/p' "$GHOSTTY/build.zig.zon" | head -1)
  [ -n "$ZON_VERSION" ] || die "can't read .version from $GHOSTTY/build.zig.zon"
  VERSION_FLAG="-Dversion-string=$ZON_VERSION+$(printf %.12s "$HEAD")"
  echo "version: $ZON_VERSION+$(printf %.12s "$HEAD") (tagged release; the commit is added for the pin check)"
fi
BUILD="\"$ZIG\" build -p \"$STAGE\" -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast $VERSION_FLAG $EXTRA"
if [ $DRY = 1 ]; then
  echo "dry run, would run in $SRC:"
  echo "  $BUILD"
  echo "  then replace $OUT/GhosttyKit.xcframework with <that tree>/macos/GhosttyKit.xcframework"
  echo "  and $OUT/ghostty-resources/{ghostty,terminfo} with <prefix>/share/{ghostty,terminfo}"
  exit 0
fi

(cd "$SRC" && eval "$BUILD")
mkdir -p "$OUT"
# In a git worktree vendor/GhosttyKit.xcframework is usually a symlink to the main checkout's copy.
# rm on the link path (no trailing slash) removes only the link, never the framework it points to.
rm -rf "$OUT/GhosttyKit.xcframework"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT/"
echo "$OUT/GhosttyKit.xcframework updated"

# Ghostty's resources from the same build (#41): bundle.sh ships them in Dealer.app, and the
# self-test reads them from vendor/. ghostty-commit stamps the commit they came from (checked by
# check-ghostty.sh). Same symlink rule as above for worktrees.
RES="$OUT/ghostty-resources"
[ -d "$STAGE/share/ghostty/shell-integration" ] || die "the build installed no share/ghostty/shell-integration under $STAGE"
rm -rf "$RES"
mkdir -p "$RES"
cp -R "$STAGE/share/ghostty" "$RES/ghostty"
cp -R "$STAGE/share/terminfo" "$RES/terminfo"
echo "$HEAD" > "$RES/ghostty-commit"
echo "$RES updated ($(du -sh "$RES" | cut -f1))"
"$REPO/scripts/check-ghostty.sh" "$OUT/GhosttyKit.xcframework" || true
