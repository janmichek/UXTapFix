#!/bin/zsh
# Double-click launcher for the guided setup assistant.
# Also clears the download quarantine flag from ad-hoc signed builds.
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

xattr -dr com.apple.quarantine "$SETUP_APP" 2>/dev/null || true
open "$SETUP_APP"
