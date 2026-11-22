#!/bin/zsh
# Remove UXTapFix, its login item, helper files, and privacy records.
# Usage: uninstall.sh [--yes]
set -u

APP="$HOME/Applications/UXTapFix.app"
SETUP_APP="$HOME/Applications/UXTapFix Setup.app"
SUPPORT="$HOME/Library/Application Support/UXTapFix"
LOG="$HOME/Library/Logs/UXTapFix.log"
PLIST="$HOME/Library/LaunchAgents/com.user.uxtapfix.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.user.uxtapfix"
LEGACY_APP="/Applications/UXTapFix.app"
OLD_APP="$HOME/Applications/DockMiddleQuit.app"
OLD_SETUP="$HOME/Applications/DockMiddleQuit Setup.app"
OLD_SUPPORT="$HOME/Library/Application Support/DockMiddleQuit"
OLD_PLIST="$HOME/Library/LaunchAgents/com.user.dockmiddlequit.plist"
OLD_LABEL="com.user.dockmiddlequit"
OLD_SYSTEM_APP="/Applications/DockMiddleQuit.app"
OLD_SYSTEM_SETUP="/Applications/DockMiddleQuit Setup.app"

if [[ "${1:-}" != "--yes" ]]; then
    echo "This removes:"
    echo "  $APP"
    echo "  $SETUP_APP"
    echo "  $PLIST"
    echo "  $SUPPORT"
    echo "  $LOG"
    echo "  Any legacy /Applications or DockMiddleQuit leftovers"
    echo "  Accessibility + Input Monitoring records for $LABEL"
    echo ""
    read -r "reply?Continue? [y/N] "
    [[ "$reply" == [yY] ]] || { echo "Cancelled."; exit 0; }
fi

echo "Stopping the service…"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
pkill -x UXTapFix 2>/dev/null || true
pkill -x UXTapFixSetup 2>/dev/null || true
pkill -x DockMiddleQuit 2>/dev/null || true

echo "Removing files…"
rm -f "$PLIST"
rm -f "$OLD_PLIST"
rm -rf "$APP"
rm -rf "$SETUP_APP"
rm -f "$LOG"
rm -rf "$LEGACY_APP" 2>/dev/null || echo "  Could not remove $LEGACY_APP; delete it manually."
rm -rf "$OLD_APP" "$OLD_SETUP" "$OLD_SYSTEM_APP" "$OLD_SYSTEM_SETUP"
rm -rf "$OLD_SUPPORT"
rm -f /tmp/dock-middle-quit.log
rm -rf "$HOME/Library/Saved Application State/com.user.uxtapfix.savedState"
defaults delete com.user.uxtapfix 2>/dev/null || true

echo "Clearing privacy records…"
tccutil reset Accessibility "$LABEL" 2>/dev/null || true
# ListenEvent is cleared only because UXTapFix is being removed. Do not reset
# it while the app stays installed: an ad-hoc build cannot add itself back.
tccutil reset ListenEvent "$LABEL" 2>/dev/null || true
tccutil reset Accessibility "$OLD_LABEL" 2>/dev/null || true
tccutil reset ListenEvent "$OLD_LABEL" 2>/dev/null || true

# Remove the helper directory last: this script lives inside it.
rm -rf "$SUPPORT"

echo ""
echo "Done. If an old UXTapFix entry remains in System Settings,"
echo "select it and click the minus button."
