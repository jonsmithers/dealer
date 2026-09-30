#!/bin/sh
# Builds MyTerm and wraps it in build/MyTerm.app.
# Usage: scripts/bundle.sh [debug|release]
set -eu
CONFIG=${1:-release}
swift build -c "$CONFIG"
APP=build/MyTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/MyTerm" "$APP/Contents/MacOS/MyTerm"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyTerm</string>
  <key>CFBundleIdentifier</key><string>dev.smithers.myterm</string>
  <key>CFBundleExecutable</key><string>MyTerm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
