#!/bin/zsh
# Advanced: allow middle-click to quit Finder.
#
# Finder normally relaunches immediately, so UXTapFix ignores it. This
# patches the installed source, rebuilds the daemon, re-signs it, and requests
# Accessibility again. Reinstalling from the Setup app restores the default.
set -euo pipefail

APP="$HOME/Applications/UXTapFix.app"
SUPPORT="$HOME/Library/Application Support/UXTapFix"
SOURCE="$SUPPORT/UXTapFix.swift"
BIN="$APP/Contents/MacOS/UXTapFix"
DOMAIN="gui/$(id -u)"
LABEL="com.user.uxtapfix"

if [[ ! -f "$SOURCE" ]]; then
    echo "Source not found: $SOURCE" >&2
    echo "Reinstall with the Setup app, then run this script again." >&2
    exit 1
fi

if ! grep -q '"finder"' "$SOURCE"; then
    echo "Finder is already allowed (or the blacklist changed). Nothing to do."
    exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc was not found. Install the Xcode Command Line Tools first:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

cp "$SOURCE" "$SOURCE.backup"
echo "Removing Finder from the blacklist…"
sed -i '' 's/\"finder\", //g; s/, \"finder\"//g; s/\"finder\"//g' "$SOURCE"

TMP_BIN="$(mktemp /tmp/UXTapFix.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

echo "Rebuilding the daemon…"
swiftc "$SOURCE" \
    -o "$TMP_BIN" \
    -O \
    -target "$(uname -m)-apple-macos13.0" \
    -I "$SUPPORT/MultitouchSupport" \
    -F /System/Library/PrivateFrameworks \
    -framework MultitouchSupport \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ServiceManagement

mv "$TMP_BIN" "$BIN"
chmod +x "$BIN"
codesign --force --sign - "$APP"

echo "Restarting the service…"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

# The rebuild has a fresh ad-hoc signature, so the old TCC records are stale.
tccutil reset Accessibility com.user.uxtapfix 2>/dev/null || true
tccutil reset ListenEvent com.user.uxtapfix 2>/dev/null || true

SETUP_APP="$HOME/Applications/UXTapFix Setup.app"
if [[ -d "$SETUP_APP" ]]; then
    open "$SETUP_APP"
else
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
fi

echo ""
echo "Finder is now allowed. macOS treats the rebuilt app as new, so approve"
echo "Accessibility again in the Setup app. Reinstalling from Setup restores the"
echo "default build (Finder ignored)."
