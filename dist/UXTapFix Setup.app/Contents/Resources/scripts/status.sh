#!/bin/zsh
# Print UXTapFix service, permission, and log status.
set -u

APP="$HOME/Applications/UXTapFix.app"
BIN="$APP/Contents/MacOS/UXTapFix"
SUPPORT="$HOME/Library/Application Support/UXTapFix"
LOG="$HOME/Library/Logs/UXTapFix.log"
PLIST="$HOME/Library/LaunchAgents/com.user.uxtapfix.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.user.uxtapfix"

echo "=== UXTapFix status ==="
if [[ -d "$APP" ]]; then
    echo "App:         $APP"
    echo "Version:     $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
    ls -lh "$BIN" 2>&1 | sed 's/^/             /'
else
    echo "App:         not installed at $APP"
fi

echo ""
echo "Login item:  $PLIST"
if [[ -f "$PLIST" ]]; then
    echo "             present"
else
    echo "             missing (launch at login is off)"
fi

echo ""
echo "Service:"
launchctl print "$DOMAIN/$LABEL" 2>&1 | head -n 40

echo ""
echo "Status file: $SUPPORT/status.json"
echo "(permissions here are reported by the running daemon itself)"
if [[ -f "$SUPPORT/status.json" ]]; then
    cat "$SUPPORT/status.json"
else
    echo "  missing (the service has not written it yet)"
fi

echo ""
echo "Log (last 30 lines): $LOG"
tail -n 30 "$LOG" 2>&1

echo ""
echo "Trackpad settings:"
defaults read com.user.uxtapfix 2>/dev/null | grep -E 'middleClick' || echo "  defaults (3 fingers, tap-to-click on)"
echo ""
echo "MiddleClick app:"
if pgrep -x MiddleClick >/dev/null 2>&1; then
    echo "  running (quit it to avoid two middle clicks per gesture)"
else
    echo "  not running"
fi
