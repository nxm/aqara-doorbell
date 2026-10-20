#!/usr/bin/env bash
set -euo pipefail
# Package the SwiftPM binary into a menu-bar .app bundle (needed for notifications).
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/AqaraDoorbell.app"
BIN_NAME="AqaraDoorbell"

VERSION="${VERSION:-0.0.0-dev}"   # CI passes the tag (without the leading v)

# Universal binary so one download runs on Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --package-path "$HERE"
BIN="$(swift build -c release "${ARCHS[@]}" --package-path "$HERE" --show-bin-path)/AqaraMenuBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

# App icon: generate the source PNG once, then build AppIcon.icns from it.
ICON_PNG="$HERE/Icon/icon-1024.png"
[ -f "$ICON_PNG" ] || swift "$HERE/Icon/make-icon.swift" "$ICON_PNG"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
# Also ship the PNG so the app can use it as a notification-attachment fallback.
cp "$ICON_PNG" "$APP/Contents/Resources/icon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Aqara Doorbell</string>
  <key>CFBundleDisplayName</key>     <string>Aqara Doorbell</string>
  <key>CFBundleIdentifier</key>      <string>io.github.nxm.aqara-doorbell</string>
  <key>CFBundleExecutable</key>      <string>$BIN_NAME</string>
  <key>CFBundleVersion</key>         <string>$VERSION</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key> <string>Two-way talk to the doorbell camera.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc codesign skipped"
echo "✅ Built $APP"
echo "   Run: open \"$APP\"   (or move it to /Applications)"
