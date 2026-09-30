#!/bin/sh
# Builds GhosttyKit.xcframework from a ghostty checkout and copies it into vendor/.
# Usage: scripts/build-ghosttykit.sh [path/to/ghostty]   (default: ~/git/ghostty)
set -eu
GHOSTTY=${1:-$HOME/git/ghostty}
ZIG=${ZIG:-$(command -v /opt/homebrew/opt/zig@0.15/bin/zig || command -v zig)}
cd "$GHOSTTY"
"$ZIG" build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast
cd - >/dev/null
rm -rf vendor/GhosttyKit.xcframework
mkdir -p vendor
cp -R "$GHOSTTY/macos/GhosttyKit.xcframework" vendor/
echo "vendor/GhosttyKit.xcframework updated"
