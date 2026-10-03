#!/bin/sh
# Builds Dealer and wraps it in build/Dealer.app.
# Usage: scripts/bundle.sh [debug|release]
set -eu
CONFIG=${1:-release}
swift build -c "$CONFIG"
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
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
