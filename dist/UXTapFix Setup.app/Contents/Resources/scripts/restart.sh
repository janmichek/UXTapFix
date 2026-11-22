#!/bin/zsh
# Restart the UXTapFix launchd service and show the newest log lines.
set -u

LOG="$HOME/Library/Logs/UXTapFix.log"
PLIST="$HOME/Library/LaunchAgents/com.user.uxtapfix.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.user.uxtapfix"

if ! launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null; then
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl kickstart -k "$DOMAIN/$LABEL"
fi
sleep 1
echo ""
echo "--- $LOG ---"
tail -n 20 "$LOG" 2>&1
