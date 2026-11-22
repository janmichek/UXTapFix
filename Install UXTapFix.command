#!/bin/zsh
# Double-click launcher for the guided setup assistant.
# Copies the ad-hoc-signed Setup app to a writable temporary folder, clears
# the download quarantine flag there, and opens it. DMGs are read-only, so
# clearing quarantine in place cannot work.
set -euo pipefail

cd "$(dirname "$0")"
SETUP_APP=""

if [[ -d "UXTapFix Setup.app" ]]; then
    SETUP_APP="UXTapFix Setup.app"
elif [[ -d "dist/UXTapFix Setup.app" ]]; then
    SETUP_APP="dist/UXTapFix Setup.app"
elif [[ -x "./build.sh" ]]; then
    echo "Building UXTapFix…"
    ./build.sh
    SETUP_APP="dist/UXTapFix Setup.app"
fi

if [[ -z "$SETUP_APP" ]]; then
    echo "Could not find UXTapFix Setup.app." >&2
    echo "Put this command next to the Setup app, or run ./build.sh first." >&2
    echo ""
    read -r "?Press Return to close…"
    exit 1
fi

if pgrep -x UXTapFixSetup >/dev/null 2>&1; then
    echo "UXTapFix Setup is already running. Close it, then run this command again." >&2
    echo ""
    read -r "?Press Return to close…"
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uxtapfix-setup.XXXXXX")"
DEST="$WORK/UXTapFix Setup.app"

echo "Preparing UXTapFix Setup…"
ditto "$SETUP_APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"

echo ""
echo "Setup is opening from $DEST."
echo "The temporary copy can be removed after Setup closes."
