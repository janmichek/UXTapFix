#!/bin/zsh
# Restart the UXTapFix launchd service and show the newest log lines.
set -u

LOG="$HOME/Library/Logs/UXTapFix.log"
DOMAIN="gui/$(id -u)"
LABEL="com.user.uxtapfix"

launchctl kickstart -k "$DOMAIN/$LABEL" 2>&1
sleep 1
echo ""
echo "--- $LOG ---"
tail -n 20 "$LOG" 2>&1
