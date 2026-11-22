#!/bin/zsh
# Static checks plus a full signed build into a temporary directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TARGET="$(uname -m)-apple-macos13.0"

echo "Checking shell syntax…"
zsh -n install.sh build.sh make-dmg.sh "Install UXTapFix.command" scripts/*.sh

echo "Checking plists…"
plutil -lint bundle/Info.plist bundle/Setup-Info.plist launchagent/com.user.uxtapfix.plist >/dev/null

echo "Type-checking Swift…"
swiftc -typecheck src/Setup/*.swift -parse-as-library -target "$TARGET"
swiftc -typecheck src/UXTapFix.swift \
    -target "$TARGET" \
    -I src/MultitouchSupport \
    -F /System/Library/PrivateFrameworks \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ServiceManagement

echo "Building into a temporary directory…"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/uxtapfix-smoke.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
./build.sh "$OUT" >/dev/null

echo "Verifying signatures and weak framework link…"
codesign --verify --deep --strict "$OUT/UXTapFix.app"
codesign --verify --deep --strict "$OUT/UXTapFix Setup.app"
otool -L "$OUT/UXTapFix.app/Contents/MacOS/UXTapFix" | grep -q 'MultitouchSupport.*weak'
plutil -extract CFBundleShortVersionString raw "$OUT/UXTapFix.app/Contents/Info.plist" >/dev/null
plutil -extract CFBundleShortVersionString raw "$OUT/UXTapFix Setup.app/Contents/Info.plist" >/dev/null

echo "Smoke tests passed."
