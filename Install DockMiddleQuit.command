#!/bin/zsh
# Double-click launcher for the guided setup assistant.
# Also clears the download quarantine flag from ad-hoc signed builds.
set -euo pipefail

cd "$(dirname "$0")"
SETUP_APP=""

if [[ -d "DockMiddleQuit Setup.app" ]]; then
    SETUP_APP="DockMiddleQuit Setup.app"
elif [[ -d "dist/DockMiddleQuit Setup.app" ]]; then
    SETUP_APP="dist/DockMiddleQuit Setup.app"
elif [[ -x "./build.sh" ]]; then
    echo "Building DockMiddleQuit…"
    ./build.sh
    SETUP_APP="dist/DockMiddleQuit Setup.app"
fi

if [[ -z "$SETUP_APP" ]]; then
    echo "Could not find DockMiddleQuit Setup.app." >&2
    echo "Put this command next to the Setup app, or run ./build.sh first." >&2
    echo ""
    read -r "?Press Return to close…"
    exit 1
fi

xattr -dr com.apple.quarantine "$SETUP_APP" 2>/dev/null || true
open "$SETUP_APP"
