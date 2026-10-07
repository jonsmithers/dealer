#!/bin/sh
# Builds GhosttyKit.xcframework from a Ghostty checkout and copies it into vendor/.
#
# Usage: scripts/build-ghosttykit.sh [options] [path/to/ghostty]
#   --ghostty PATH   Ghostty checkout (same as the positional argument or $GHOSTTY_SRC)
#   --out DIR        where to put GhosttyKit.xcframework (default: <repo>/vendor)
#   --any-version    build even if the checkout isn't at the commit in scripts/ghostty.version
#   --dry-run        resolve everything and print what would run; don't build or copy
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
while [ $# -gt 0 ]; do
  case $1 in
    --ghostty) GHOSTTY=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --any-version) ANY=1; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# zig: Ghostty's build.zig.zon says which version it needs (0.15.x for the pinned commit).
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

echo "ghostty: $GHOSTTY @ $HEAD"
echo "zig:     $ZIG ($HAVE)"
echo "output:  $OUT/GhosttyKit.xcframework"
# The xcframework build also installs Ghostty's resources (shell integration, themes, terminfo)
# under the install prefix. A fresh prefix keeps stale files from older builds out of them and
# leaves the checkout's own zig-out alone; the framework itself always goes to macos/.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ghosttykit-prefix.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
BUILD="\"$ZIG\" build -p \"$STAGE\" -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast"
if [ $DRY = 1 ]; then
  echo "dry run, would run in $GHOSTTY:"
  echo "  $BUILD"
  echo "  then replace $OUT/GhosttyKit.xcframework with $GHOSTTY/macos/GhosttyKit.xcframework"
  echo "  and $OUT/ghostty-resources/{ghostty,terminfo} with <prefix>/share/{ghostty,terminfo}"
  exit 0
fi

(cd "$GHOSTTY" && eval "$BUILD")
mkdir -p "$OUT"
# In a git worktree vendor/GhosttyKit.xcframework is usually a symlink to the main checkout's copy.
# rm on the link path (no trailing slash) removes only the link, never the framework it points to.
rm -rf "$OUT/GhosttyKit.xcframework"
cp -R "$GHOSTTY/macos/GhosttyKit.xcframework" "$OUT/"
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
