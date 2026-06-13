#!/bin/bash
# Builds SnapCopy.app — a menu-bar OCR / QR grabber.
set -euo pipefail

cd "$(dirname "$0")"

APP="SnapCopy.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "› Cleaning previous build…"
rm -rf "$APP" "GrabText.app"
mkdir -p "$MACOS" "$RES"

echo "› Compiling main.swift…"
swiftc -O main.swift \
    -o "$MACOS/SnapCopy" \
    -framework Cocoa \
    -framework Carbon \
    -framework Vision \
    -framework UserNotifications

echo "› Writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SnapCopy</string>
    <key>CFBundleDisplayName</key>     <string>SnapCopy</string>
    <key>CFBundleExecutable</key>      <string>SnapCopy</string>
    <key>CFBundleIdentifier</key>      <string>app.snapcopy</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>SnapCopy</string>
</dict>
</plist>
PLIST

echo "› Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"
echo
echo "Run it with:   open $APP"
echo "First launch will prompt for Screen Recording permission (System Settings ›"
echo "Privacy & Security › Screen Recording). Re-open SnapCopy after granting it."
