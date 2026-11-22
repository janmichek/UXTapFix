#!/bin/zsh
# Allow middle-click to quit Finder.
#
# Finder normally relaunches immediately, so UXTapFix ignores it by default.
# This flips a per-user preference and restarts the service; no rebuild, no
# code-signature change, and no permission reset.
set -euo pipefail

APP="$HOME/Applications/UXTapFix.app"
PLIST="$HOME/Library/LaunchAgents/com.user.uxtapfix.plist"
DOMAIN="gui/$(id -u)"
LABEL="com.user.uxtapfix"
PREF="com.user.uxtapfix"

if [[ ! -d "$APP" ]]; then
    echo "UXTapFix is not installed at $APP." >&2
    echo "Install it with the Setup app first." >&2
    exit 1
fi
if [[ ! -f "$PLIST" ]]; then
    echo "Launch at Login is off. Turn it on in UXTapFix Setup, then run this again." >&2
    exit 1
fi

defaults write "$PREF" middleClickAllowFinderQuit -bool true
if ! launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null; then
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
    launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
fi

echo ""
echo "Finder is now allowed. Middle-click its Dock icon to quit it."
echo "Finder will relaunch itself, so the tile comes back."
echo ""
echo "To restore the default:"
echo "  defaults write $PREF middleClickAllowFinderQuit -bool false"
echo "  launchctl kickstart -k $DOMAIN/$LABEL"
