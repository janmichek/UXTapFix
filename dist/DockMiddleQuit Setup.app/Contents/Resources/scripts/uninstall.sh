#!/bin/zsh
# Remove DockMiddleQuit, its login item, helper files, and privacy records.
# Usage: uninstall.sh [--yes]
set -u

APP="$HOME/Applications/DockMiddleQuit.app"
SETUP_APP="$HOME/Applications/DockMiddleQuit Setup.app"
SUPPORT="$HOME/Library/Application Support/DockMiddleQuit"
LOG="$HOME/Library/Logs/DockMiddleQuit.log"
PLIST="$HOME/Library/LaunchAgents/com.user.dockmiddlequit.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.user.dockmiddlequit"

if [[ "${1:-}" != "--yes" ]]; then
    echo "This removes:"
    echo "  $APP"
    echo "  $SETUP_APP"
    echo "  $PLIST"
    echo "  $SUPPORT"
    echo "  $LOG"
    echo "  Accessibility + Input Monitoring records for $LABEL"
    echo ""
    read -r "reply?Continue? [y/N] "
    [[ "$reply" == [yY] ]] || { echo "Cancelled."; exit 0; }
fi

echo "Stopping the service…"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x DockMiddleQuit 2>/dev/null || true

echo "Removing files…"
rm -f "$PLIST"
rm -rf "$APP"
rm -rf "$SETUP_APP"
rm -rf "$SUPPORT"
rm -f "$LOG"

echo "Clearing privacy records…"
tccutil reset Accessibility "$LABEL" 2>/dev/null || true
tccutil reset ListenEvent "$LABEL" 2>/dev/null || true

echo ""
echo "Done. If an old DockMiddleQuit entry remains in System Settings,"
echo "select it and click the minus button."
