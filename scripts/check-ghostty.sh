#!/bin/sh
# Checks that a GhosttyKit.xcframework was built from the Ghostty commit pinned in
# scripts/ghostty.version (#35). Reads the version string Ghostty's build embeds in the library
# (e.g. `1.3.2-main-+243f7df7c`), so no separate stamp file can go stale. When the framework
# matches, it also checks the ghostty-resources directory next to it (#41) by its ghostty-commit
# stamp, which build-ghosttykit.sh writes in the same run.
#
# Usage: scripts/check-ghostty.sh [path/to/GhosttyKit.xcframework]   (default: vendor/)
# Exit status: 0 match, 1 mismatch or missing, 2 the library records no commit (warning only).
# GHOSTTY_ANY_VERSION=1 turns a mismatch into a warning (exit 0).
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
FW=${1:-$REPO/vendor/GhosttyKit.xcframework}
PIN=$(grep -v '^#' "$REPO/scripts/ghostty.version" | tr -d '[:space:]')

LIB=$(ls "$FW"/*/libghostty*.a 2>/dev/null | head -1 || true)
if [ -z "$LIB" ]; then
  echo "error: no GhosttyKit library under $FW. Build it with scripts/build-ghosttykit.sh." >&2
  exit 1
fi
VERSION=$(LC_ALL=C grep -a -o -m1 -E '[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9.-]*\+[0-9a-f]{7,40}' "$LIB" | head -1 || true)
COMMIT=${VERSION##*+}
if [ -z "$VERSION" ]; then
  echo "warning: $FW records no Ghostty commit (built without git?); can't check it against the pin $PIN." >&2
  exit 2
fi
case $PIN in
  "$COMMIT"*)
    echo "GhosttyKit OK: $VERSION matches the pin"
    # Ghostty's resources next to it (#41), stamped by build-ghosttykit.sh with their commit.
    RES=$(dirname "$FW")/ghostty-resources
    if [ ! -d "$RES" ]; then
      echo "note: no $RES; bundles will borrow Ghostty's resources from an installed Ghostty.app" >&2
      exit 0
    fi
    STAMP=$(cat "$RES/ghostty-commit" 2>/dev/null || true)
    [ "$STAMP" = "$PIN" ] && { echo "ghostty-resources OK: built from the pin"; exit 0; }
    MSG="$RES was built from Ghostty ${STAMP:-<no stamp>}, but scripts/ghostty.version pins $PIN.
Rebuild with scripts/build-ghosttykit.sh."
    [ "${GHOSTTY_ANY_VERSION:-}" = 1 ] && { echo "WARNING: $MSG" >&2; exit 0; }
    echo "error: $MSG
Set GHOSTTY_ANY_VERSION=1 to proceed anyway." >&2
    exit 1 ;;
esac
MSG="GhosttyKit at $FW was built from Ghostty $COMMIT ($VERSION), but scripts/ghostty.version pins $PIN.
Rebuild it from the pinned commit: scripts/build-ghosttykit.sh (it tells you how to check out the pin)."
if [ "${GHOSTTY_ANY_VERSION:-}" = 1 ]; then
  echo "WARNING: $MSG" >&2
  exit 0
fi
echo "error: $MSG
Set GHOSTTY_ANY_VERSION=1 to proceed anyway." >&2
exit 1
