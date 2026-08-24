#!/bin/bash
# Cuts a public release artifact: universal binary (arm64 + x86_64), Developer
# ID signature with hardened runtime, notarization + stapling, a zip for
# GitHub Releases, and the Homebrew cask bump. Operator runbook (one-time
# credential setup, per-release steps): docs/RELEASING.md.
#
#   scripts/release.sh <version> [--no-notarize]
#
# --no-notarize is a local dry run: builds and zips the same artifact shape
# (signed with the "Ferrite Dev" fallback if no Developer ID identity exists)
# but skips notarization and does NOT touch the cask or version defaults.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release.sh <version> [--no-notarize]" >&2; exit 2; }

VERSION="${1:-}"
[ -n "$VERSION" ] || usage
shift
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    *) usage ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be x.y.z, got '$VERSION'" >&2; exit 2; }

if [ "$NOTARIZE" = "1" ] && [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree not clean; commit or stash first" >&2
  exit 1
fi

# --- Signing identity -------------------------------------------------------
# Notarization requires a "Developer ID Application" certificate (paid Apple
# Developer account). FERRITE_RELEASE_IDENTITY overrides auto-detection.
IDENTITY="${FERRITE_RELEASE_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ]; then
  if [ "$NOTARIZE" = "1" ]; then
    cat >&2 <<'EOF'
error: no "Developer ID Application" identity in the keychain.

One-time setup (docs/RELEASING.md has the full runbook):
  1. Enroll at developer.apple.com, create a "Developer ID Application"
     certificate, download and double-click it into the login keychain.
  2. Store notarization credentials:
       xcrun notarytool store-credentials ferrite-notary \
         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>

For a local dry run without credentials: scripts/release.sh <version> --no-notarize
EOF
    exit 1
  fi
  echo "note: no Developer ID identity; dry run signs with the dev fallback." >&2
fi

echo "==> Tests"
swift test

echo "==> Building universal app (version $VERSION)"
FERRITE_VERSION="$VERSION" FERRITE_ARCHES="arm64 x86_64" FERRITE_HARDENED=1 \
  FERRITE_SIGN_IDENTITY="$IDENTITY" ./scripts/make-app.sh

APP="build/Ferrite.app"
codesign --verify --strict --deep "$APP"
echo "    archs: $(lipo -archs "$APP/Contents/MacOS/Ferrite")"

mkdir -p dist
ZIP="dist/Ferrite-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" = "1" ]; then
  PROFILE="${FERRITE_NOTARY_PROFILE:-ferrite-notary}"
  echo "==> Notarizing (profile: $PROFILE)"
  # On "Invalid": xcrun notarytool log <submission-id> --keychain-profile "$PROFILE"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the ticket stapled
  spctl -a -t exec -vv "$APP"              # Gatekeeper verdict on the final app
fi

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "==> $ZIP"
echo "    sha256: $SHA"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Bumping Casks/ferrite.rb and the dev-build default version"
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
            -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/ferrite.rb
  sed -i '' -e "s/^VERSION=\"\${FERRITE_VERSION:-.*}\"/VERSION=\"\${FERRITE_VERSION:-$VERSION}\"/" scripts/make-app.sh

  cat <<EOF

Release artifact ready. Next steps:
  git add Casks/ferrite.rb scripts/make-app.sh
  git commit -m "release: v$VERSION"
  git tag v$VERSION
  git push origin main v$VERSION
  gh release create v$VERSION "$ZIP" --title "Ferrite $VERSION"
EOF
else
  echo
  echo "Dry run complete (not notarized; cask untouched)."
fi
