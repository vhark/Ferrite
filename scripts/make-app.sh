#!/bin/bash
# Builds MacTLM.app. Note: ad-hoc signing re-keys TCC per build; after a
# rebuild you may need to toggle the Accessibility grant off/on in System
# Settings. A stable signing identity fixes this permanently.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/MacTLM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacTLM "$APP/Contents/MacOS/MacTLM"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.mactlm.MacTLM</string>
  <key>CFBundleName</key><string>MacTLM</string>
  <key>CFBundleExecutable</key><string>MacTLM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
