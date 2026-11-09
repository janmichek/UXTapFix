#!/bin/zsh
# Build a distributable DMG containing the guided Setup app.
# Usage: ./make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
STAGE="$ROOT/build/dmg"
SETUP_APP="$DIST/DockMiddleQuit Setup.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/bundle/Setup-Info.plist")"
DMG="$DIST/DockMiddleQuit-$VERSION.dmg"

"$ROOT/build.sh" "$DIST"

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$SETUP_APP" "$STAGE/DockMiddleQuit Setup.app"
cp "$ROOT/Install DockMiddleQuit.command" "$STAGE/Install DockMiddleQuit.command"
chmod +x "$STAGE/Install DockMiddleQuit.command"

if [[ -f "$ROOT/build/AppIcon.icns" ]]; then
    cp "$ROOT/build/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$STAGE"
    fi
fi

cat > "$STAGE/Read Me.txt" <<'README'
DockMiddleQuit
==============

Middle-click (or three-finger tap) a Dock icon to quit that app.

INSTALL
-------
1. Open "DockMiddleQuit Setup.app".
   If macOS says it can't verify the app, right-click it and choose Open.
   That warning appears because this build is ad-hoc signed, not notarized.

2. Follow the short steps:
   Welcome -> Install -> Access -> Login -> Ready.

   No admin password is needed. The app is installed in your user folder:
   ~/Applications/DockMiddleQuit.app

If double-clicking the Setup app is blocked, double-click
"Install DockMiddleQuit.command" instead. It clears the download quarantine
flag and opens the same assistant.

PERMISSIONS
-----------
macOS requires you to approve two switches manually:
  - Accessibility (required)
  - Input Monitoring (recommended)

The Setup app opens the exact System Settings pane and updates live when the
switch is on. If a switch already looks on but status stays off, click Reset
on that permission card, then Grant Access again. This clears an old entry
left behind by a previous build.

THREE-FINGER TAP
----------------
DockMiddleQuit reacts to a middle click. For trackpad users, install the free
MiddleClick app (https://github.com/artginzburg/MiddleClick) and map
three-finger tap to middle click. The Setup app detects it for you.

UNINSTALL
---------
Reopen "DockMiddleQuit Setup.app" (it is copied to ~/Applications) and use
the gear menu -> Uninstall. This removes the app, login item, helper files,
and its privacy permissions.
README

echo ""
echo "Creating $DMG…"
rm -f "$DMG"
if diskutil image create from --help >/dev/null 2>&1 \
    && diskutil image create from \
        --format UDZO \
        --volumeName "DockMiddleQuit $VERSION" \
        "$STAGE" "$DMG" >/dev/null 2>&1; then
    : # Newer macOS releases deprecate hdiutil.
else
    rm -f "$DMG"
    hdiutil create \
        -volname "DockMiddleQuit $VERSION" \
        -srcfolder "$STAGE" \
        -ov \
        -format UDZO \
        "$DMG" >/dev/null
fi

echo ""
echo "Built: $DMG"
shasum -a 256 "$DMG"
