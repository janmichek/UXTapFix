#!/bin/zsh
# Fresh install / restore on this or another Mac.
# Builds the app, installs the LaunchAgent, and starts it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/DockMiddleQuit.app"
SUPPORT="$HOME/Library/Application Support/DockMiddleQuit"
PLIST="$HOME/Library/LaunchAgents/com.user.dockmiddlequit.plist"
LABEL="gui/$(id -u)/com.user.dockmiddlequit"

"$ROOT/build.sh" "$APP"

# Keep the helper scripts + source where the original install lived.
mkdir -p "$SUPPORT"
cp "$ROOT/src/DockMiddleQuit.swift" "$SUPPORT/"
cp "$ROOT/scripts/"*.sh "$ROOT/scripts/README.txt" "$SUPPORT/"
chmod +x "$SUPPORT/"*.sh

mkdir -p "$(dirname "$PLIST")"
sed "s#/Users/yeahboi#$HOME#g" "$ROOT/launchagent/com.user.dockmiddlequit.plist" > "$PLIST"

launchctl bootout "$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "$LABEL"

sleep 1
echo ""
echo "Installed. Log: /tmp/dock-middle-quit.log"
tail -n 10 /tmp/dock-middle-quit.log 2>/dev/null || true
echo ""
echo "MANUAL STEP: System Settings -> Privacy & Security ->"
echo "  Accessibility      -> add $APP and enable it"
echo "  Input Monitoring   -> add $APP and enable it"
echo "Then restart: $SUPPORT/restart.sh"
echo ""
echo "3-finger tap needs MiddleClick.app (maps 3-finger tap -> middle click)."
