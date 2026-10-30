#!/bin/sh
# Builds Dealer and wraps it in build/Dealer.app.
# Usage: scripts/bundle.sh [debug|release]
set -eu
CONFIG=${1:-release}
# Program status (OSC 7501, #89): working while it builds, then done or failed on the pane's tab.
# A no-op outside a terminal; DEALER_PROGRAM_STATUS=0 turns it off.
. "$(dirname "$0")/lib/program-status.sh"
program_status_init dealer-bundle bundle
trap 'program_status_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
program_status working "Bundling Dealer: checking GhosttyKit"
# Refuse to bundle against a GhosttyKit that isn't the pinned Ghostty commit (#35).
"$(dirname "$0")/check-ghostty.sh" || [ $? = 2 ]  # 2 = no commit recorded: warned, not fatal
program_status working "Bundling Dealer: swift build" "$CONFIG"
swift build -c "$CONFIG"
program_status working "Bundling Dealer: assembling and signing" "build/Dealer.app"
APP=build/Dealer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Dealer" "$APP/Contents/MacOS/Dealer"
# The CLI is the same binary; invoked as `dealer` it talks to the control socket (docs/cli.md).
# It lives in Resources/bin because MacOS/dealer would collide with MacOS/Dealer on
# case-insensitive volumes. Panes get this directory appended to PATH.
mkdir -p "$APP/Contents/Resources/bin"
ln -s ../../MacOS/Dealer "$APP/Contents/Resources/bin/dealer"
# Claude Code plugin with Dealer's hooks; panes load it through CLAUDE_CODE_PLUGIN_DIRS (#12).
cp -R Resources/claude-plugin "$APP/Contents/Resources/claude-plugin"
# Ghostty's resources from the pinned build (#41): shell integration, themes and terminfo, written
# to vendor/ghostty-resources by scripts/build-ghosttykit.sh. libghostty finds them on its own
# (it looks for Contents/Resources/terminfo/78/xterm-ghostty), and GhosttyResources puts them first.
RES=vendor/ghostty-resources
if [ -d "$RES/ghostty/shell-integration" ] && [ -d "$RES/terminfo" ]; then
  cp -R "$RES/ghostty" "$APP/Contents/Resources/ghostty"
  cp -R "$RES/terminfo" "$APP/Contents/Resources/terminfo"
else
  echo "warning: no $RES (rebuild with scripts/build-ghosttykit.sh); Dealer.app will borrow" \
    "shell integration, themes and terminfo from an installed Ghostty.app instead" >&2
fi
cp Resources/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
# App icon (#22); regenerate with scripts/make-icon.sh.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dealer</string>
  <key>CFBundleIdentifier</key><string>dev.smithers.dealer</string>
  <key>CFBundleExecutable</key><string>Dealer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Fail loudly if signing fails (#70): an unsigned bundle loses its TCC and notification identity.
# Only codesign's expected "replacing existing signature" note (ld already ad-hoc signs arm64) is hidden.
if ! CS_OUT=$(codesign --force --sign - "$APP" 2>&1); then
  printf '%s\n' "$CS_OUT" | grep -v 'replacing existing signature' >&2
  echo "error: codesign failed for $APP" >&2
  exit 1
fi
# Re-register this bundle with Launch Services now, so its icon is on record before the app first
# asks for notification permission (#30). Notification Center caches the icon per bundle ID; a
# bundle first seen without an icon showed a white square. Scoped to this one bundle.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ] && ! "$LSREGISTER" -f "$APP" >/dev/null 2>&1; then
  echo "warning: lsregister -f $APP failed; Notification Center may show a stale icon" >&2
fi
program_status done "Dealer bundled" "$APP ($CONFIG)"
echo "$APP"
