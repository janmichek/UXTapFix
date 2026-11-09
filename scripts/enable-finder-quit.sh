#!/bin/zsh
# Allow middle-click to quit Finder (by default blocked)
# Edits Swift source to remove Finder from blacklist and rebuilds
FILE="$HOME/Library/Application Support/DockMiddleQuit/DockMiddleQuit.swift"
if grep -q '"finder"' "$FILE"; then
  echo "Removing finder from blacklist..."
  # This is a demo - blacklist is in Swift source, rebuild required
  sed -i '' 's/\"finder\", //g; s/, \"finder\"//g; s/\"finder\"//g' "$FILE"
  echo "Rebuilding..."
  swiftc "$FILE" -o "$HOME/Applications/DockMiddleQuit.app/Contents/MacOS/DockMiddleQuit" -framework Cocoa -framework ApplicationServices
  codesign --force --deep --sign - "$HOME/Applications/DockMiddleQuit.app"
  "$HOME/Library/Application Support/DockMiddleQuit/restart.sh"
else
  echo "Finder already allowed or not found in blacklist"
fi
