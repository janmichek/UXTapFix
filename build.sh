#!/bin/zsh
# Build DockMiddleQuit.app and the DockMiddleQuit Setup app.
# Usage: ./build.sh [output-directory]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$ROOT/dist}"
DAEMON_APP="$OUT/DockMiddleQuit.app"
SETUP_APP="$OUT/DockMiddleQuit Setup.app"
BUILD="$ROOT/build"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.0"

echo "Building DockMiddleQuit 2.2 -> $OUT"

# MARK: Icon
rm -rf "$BUILD/AppIcon.iconset"
mkdir -p "$BUILD"
swift "$ROOT/tools/make-icon.swift" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

# MARK: Daemon app
rm -rf "$DAEMON_APP"
mkdir -p "$DAEMON_APP/Contents/MacOS" "$DAEMON_APP/Contents/Resources"
cp "$ROOT/bundle/Info.plist" "$DAEMON_APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$DAEMON_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$DAEMON_APP/Contents/Info.plist" >/dev/null

swiftc "$ROOT/src/DockMiddleQuit.swift" \
  -o "$DAEMON_APP/Contents/MacOS/DockMiddleQuit" \
  -O \
  -target "$TARGET" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework ServiceManagement

codesign --force --sign - "$DAEMON_APP"

# MARK: Setup app
rm -rf "$SETUP_APP"
mkdir -p "$SETUP_APP/Contents/MacOS" "$SETUP_APP/Contents/Resources"
cp "$ROOT/bundle/Setup-Info.plist" "$SETUP_APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$SETUP_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$SETUP_APP/Contents/Info.plist" >/dev/null

# Embed the daemon and the CLI helpers inside the Setup app so it is
# self-contained when moved to ~/Applications or a DMG.
ditto "$DAEMON_APP" "$SETUP_APP/Contents/Resources/DockMiddleQuit.app"
cp "$ROOT/src/DockMiddleQuit.swift" "$SETUP_APP/Contents/Resources/DockMiddleQuit.swift"
ditto "$ROOT/scripts" "$SETUP_APP/Contents/Resources/scripts"

swiftc "$ROOT/src/Setup/"*.swift \
  -o "$SETUP_APP/Contents/MacOS/DockMiddleQuitSetup" \
  -O \
  -target "$TARGET" \
  -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine

codesign --force --sign - "$SETUP_APP"

# MARK: Verify
codesign --verify --deep --strict "$DAEMON_APP"
codesign --verify --deep --strict "$SETUP_APP"

echo ""
echo "Built:"
echo "  $DAEMON_APP"
echo "  $SETUP_APP"
echo ""
echo "Open the assistant with: open \"$SETUP_APP\""
echo "NOTE: rebuilds use a fresh ad-hoc signature. macOS may ask you to"
echo "      re-approve Accessibility/Input Monitoring after an update."
