#!/bin/zsh
# Build UXTapFix.app and the UXTapFix Setup app.
# Usage: ./build.sh [output-directory]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$ROOT/dist}"
DAEMON_APP="$OUT/UXTapFix.app"
SETUP_APP="$OUT/UXTapFix Setup.app"
BUILD="$ROOT/build"
# Build both slices so the release runs natively on Apple silicon and Intel.
TARGETS=("arm64-apple-macos13.0" "x86_64-apple-macos13.0")
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/bundle/Info.plist")"
SETUP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/bundle/Setup-Info.plist")"

if [[ "$VERSION" != "$SETUP_VERSION" ]]; then
    echo "Version mismatch: daemon is $VERSION but Setup is $SETUP_VERSION." >&2
    echo "Keep bundle/Info.plist and bundle/Setup-Info.plist in sync." >&2
    exit 1
fi

echo "Building UXTapFix $VERSION -> $OUT"

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

DAEMON_SLICES=()
for target in "${TARGETS[@]}"; do
  arch="${target%%-*}"
  slice="$BUILD/UXTapFix-$arch"
  swiftc "$ROOT/src/UXTapFix.swift" \
    -o "$slice" \
    -O \
    -target "$target" \
    -I "$ROOT/src/MultitouchSupport" \
    -F /System/Library/PrivateFrameworks \
    -Xlinker -weak_framework -Xlinker MultitouchSupport \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ServiceManagement
  DAEMON_SLICES+=("$slice")
done
lipo -create "${DAEMON_SLICES[@]}" -output "$DAEMON_APP/Contents/MacOS/UXTapFix"

codesign --force --sign - "$DAEMON_APP"

# MARK: Setup app
rm -rf "$SETUP_APP"
mkdir -p "$SETUP_APP/Contents/MacOS" "$SETUP_APP/Contents/Resources"
cp "$ROOT/bundle/Setup-Info.plist" "$SETUP_APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$SETUP_APP/Contents/Resources/AppIcon.icns"
plutil -lint "$SETUP_APP/Contents/Info.plist" >/dev/null

# Embed the daemon and the CLI helpers inside the Setup app so it is
# self-contained when moved to ~/Applications or a DMG.
ditto "$DAEMON_APP" "$SETUP_APP/Contents/Resources/UXTapFix.app"
cp "$ROOT/src/UXTapFix.swift" "$SETUP_APP/Contents/Resources/UXTapFix.swift"
ditto "$ROOT/src/MultitouchSupport" "$SETUP_APP/Contents/Resources/MultitouchSupport"
ditto "$ROOT/scripts" "$SETUP_APP/Contents/Resources/scripts"

SETUP_SLICES=()
for target in "${TARGETS[@]}"; do
  arch="${target%%-*}"
  slice="$BUILD/UXTapFixSetup-$arch"
  swiftc "$ROOT/src/Setup/"*.swift \
    -o "$slice" \
    -O \
    -target "$target" \
    -parse-as-library \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine
  SETUP_SLICES+=("$slice")
done
lipo -create "${SETUP_SLICES[@]}" -output "$SETUP_APP/Contents/MacOS/UXTapFixSetup"

codesign --force --sign - "$SETUP_APP"

# MARK: Verify
codesign --verify --deep --strict "$DAEMON_APP"
codesign --verify --deep --strict "$SETUP_APP"

for binary in "$DAEMON_APP/Contents/MacOS/UXTapFix" "$SETUP_APP/Contents/MacOS/UXTapFixSetup"; do
  archs="$(lipo -archs "$binary")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || {
    echo "Expected a universal binary, got: $archs" >&2
    exit 1
  }
done

echo ""
echo "Built:"
echo "  $DAEMON_APP"
echo "  $SETUP_APP"
echo ""
echo "Open the assistant with: open \"$SETUP_APP\""
echo "NOTE: rebuilds use a fresh ad-hoc signature. macOS may ask you to"
echo "      re-approve Accessibility/Input Monitoring after an update."
