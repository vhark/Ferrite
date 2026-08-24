#!/bin/bash
# Builds Ferrite.app. Signs with the "Ferrite Dev" self-signed identity when
# present (stable TCC grant across rebuilds); falls back to ad-hoc signing,
# which re-keys TCC per build (re-grant Accessibility after each rebuild).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Ferrite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Ferrite "$APP/Contents/MacOS/Ferrite"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ferrite.Ferrite</string>
  <key>CFBundleName</key><string>Ferrite</string>
  <key>CFBundleExecutable</key><string>Ferrite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.11.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Ferrite Dev"; then
  codesign --force --sign "Ferrite Dev" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
