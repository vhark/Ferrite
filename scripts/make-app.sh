#!/bin/bash
# Builds Ferrite.app. Signs with the "Ferrite Dev" self-signed identity when
# present (stable TCC grant across rebuilds); falls back to ad-hoc signing,
# which re-keys TCC per build (re-grant Accessibility after each rebuild).
#
# Release knobs (used by scripts/release.sh; all optional for dev builds):
#   FERRITE_VERSION       CFBundleShortVersionString/CFBundleVersion (default below)
#   FERRITE_ARCHES        space-separated arch list, e.g. "arm64 x86_64" for a
#                         universal binary (products land in .build/apple/)
#   FERRITE_SIGN_IDENTITY explicit codesign identity, overrides the dev fallback
#   FERRITE_HARDENED=1    hardened runtime + secure timestamp (notarization bar)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FERRITE_VERSION:-0.11.0}"
ARCHES="${FERRITE_ARCHES:-}"
IDENTITY="${FERRITE_SIGN_IDENTITY:-}"
HARDENED="${FERRITE_HARDENED:-0}"

if [ -n "$ARCHES" ]; then
  ARCH_FLAGS=()
  for a in $ARCHES; do ARCH_FLAGS+=(--arch "$a"); done
  swift build -c release "${ARCH_FLAGS[@]}"
  PRODUCTS=".build/apple/Products/Release"
else
  swift build -c release
  PRODUCTS=".build/release"
fi

APP="build/Ferrite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Ferrite" "$APP/Contents/MacOS/Ferrite"
# SwiftPM resource bundles ride along (KeyboardShortcuts ships localizations).
for b in "$PRODUCTS"/*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ferrite.Ferrite</string>
  <key>CFBundleName</key><string>Ferrite</string>
  <key>CFBundleExecutable</key><string>Ferrite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

SIGN_FLAGS=(--force)
if [ "$HARDENED" = "1" ]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
if [ -n "$IDENTITY" ]; then
  codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Ferrite Dev"; then
  codesign "${SIGN_FLAGS[@]}" --sign "Ferrite Dev" "$APP"
else
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP"
fi
echo "Built $APP (version $VERSION)"
