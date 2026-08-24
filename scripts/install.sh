#!/bin/bash
# Installs Ferrite as the daily driver in /Applications and points the
# Launch-at-Login registration at that stable copy.
#
# Why: build/Ferrite.app lives in a gitignored directory that make-app.sh
# deletes on every rebuild, so a login item registered from there breaks the
# moment build/ is wiped. Dev builds keep using build/; /Applications is what
# starts at login.
#
# The Accessibility grant is keyed to the code signature (identity
# "Ferrite Dev"), not the path, so the installed copy needs no re-approval.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="build/Ferrite.app"
DEST="/Applications/Ferrite.app"

# Transition: retire an installed MacTLM (pre-rename identity of this app).
# Its on-disk state (~/Library/Application Support/MacTLM, defaults domain
# dev.mactlm.MacTLM) is deliberately left behind — Ferrite migrates from it
# on first launch and it stays as the rollback copy.
OLD_APP="/Applications/MacTLM.app"
if [ -d "$OLD_APP" ]; then
  "$OLD_APP/Contents/MacOS/MacTLM" --login-unregister >/dev/null 2>&1 || true
  pkill -f "MacTLM.app/Contents/MacOS/MacTLM" 2>/dev/null || true
  sleep 1
  rm -rf "$OLD_APP"
  echo "Removed old $OLD_APP (login item unregistered, process stopped)."
fi

./scripts/make-app.sh

# Stop whatever is running, from either location and either name.
pkill -f "Ferrite.app/Contents/MacOS/Ferrite" 2>/dev/null || true
pkill -f "MacTLM.app/Contents/MacOS/MacTLM" 2>/dev/null || true
sleep 1

# Drop a stale login item registered from the build directory.
if [ -x "$SRC/Contents/MacOS/Ferrite" ]; then
  "$SRC/Contents/MacOS/Ferrite" --login-unregister >/dev/null 2>&1 || true
fi

if [ ! -w /Applications ]; then
  echo "error: /Applications is not writable; re-run with sudo" >&2
  exit 1
fi

rm -rf "$DEST"
/usr/bin/ditto "$SRC" "$DEST"   # ditto preserves the code signature
codesign --verify --strict "$DEST"

# Register for login from the installed copy, then start it.
"$DEST/Contents/MacOS/Ferrite" --login-register
open "$DEST"

echo
echo "Installed $DEST"
echo "Dev builds still go to $SRC via scripts/make-app.sh."
echo "If macOS asks for approval, allow Ferrite under System Settings > General > Login Items."
