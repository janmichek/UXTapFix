#!/bin/zsh
# Rebuild DockMiddleQuit.app from src/DockMiddleQuit.swift
# Usage: ./build.sh [output-app-path]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/Applications/DockMiddleQuit.app}"
BIN="$APP/Contents/MacOS/DockMiddleQuit"

echo "Building -> $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/bundle/Info.plist" "$APP/Contents/Info.plist"

swiftc "$ROOT/src/DockMiddleQuit.swift" \
  -o "$BIN" \
  -framework Cocoa \
  -framework ApplicationServices

codesign --force --deep --sign - "$APP"
echo "Done: $(du -h "$BIN" | cut -f1) at $BIN"
echo "NOTE: a fresh ad-hoc signature can reset Accessibility/Input Monitoring"
echo "      permissions. If middle-click stops working, re-add the app under"
echo "      System Settings -> Privacy & Security -> Accessibility + Input Monitoring."
