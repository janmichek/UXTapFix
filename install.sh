#!/bin/zsh
# DockMiddleQuit installer
#
#   ./install.sh              Build and open the guided Setup app.
#   ./install.sh --headless   Install the daemon + login item without any UI.
#   ./install.sh --no-build   Use the existing dist/ build.
#
# The guided Setup app is the recommended path: it installs into your user
# folder, walks through the two macOS permissions, and manages launch at login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
SETUP_APP="$DIST/DockMiddleQuit Setup.app"
DAEMON_APP="$DIST/DockMiddleQuit.app"
APP="$HOME/Applications/DockMiddleQuit.app"
SETUP_DEST="$HOME/Applications/DockMiddleQuit Setup.app"
SUPPORT="$HOME/Library/Application Support/DockMiddleQuit"
PLIST="$HOME/Library/LaunchAgents/com.user.dockmiddlequit.plist"
LOG="$HOME/Library/Logs/DockMiddleQuit.log"
LEGACY_APP="/Applications/DockMiddleQuit.app"
LABEL="com.user.dockmiddlequit"
DOMAIN="gui/$(id -u)"

mode="guided"
build=1

usage() {
    cat <<'USAGE'
Usage: ./install.sh [--headless] [--no-build]

  (no option)   Build and open the guided Setup app.
  --headless    Install the daemon and login item without any UI.
  --no-build    Use the existing build in dist/.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --headless) mode="headless" ;;
        --no-build) build=0 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Run ./install.sh --help for usage." >&2
            exit 2
            ;;
    esac
done

if (( build )); then
    "$ROOT/build.sh"
else
    if [[ ! -d "$DAEMON_APP" ]]; then
        echo "No existing daemon build found in dist/. Run ./install.sh without --no-build." >&2
        exit 1
    fi
    if [[ "$mode" == "guided" && ! -d "$SETUP_APP" ]]; then
        echo "No existing Setup app found in dist/. Run ./install.sh without --no-build." >&2
        exit 1
    fi
fi

# MARK: Guided install

if [[ "$mode" == "guided" ]]; then
    open "$SETUP_APP"
    echo ""
    echo "DockMiddleQuit Setup is opening. Follow the short steps:"
    echo "  Welcome -> Permissions -> Launch at Login"
    exit 0
fi

# MARK: Headless install

echo "Installing DockMiddleQuit for $(whoami)…"

# Stop any old copy before replacing the bundle.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x DockMiddleQuit 2>/dev/null || true
sleep 0.3

if [[ -d "$LEGACY_APP" ]]; then
    echo "Moving the old /Applications copy to the Trash…"
    mkdir -p "$HOME/.Trash"
    mv "$LEGACY_APP" "$HOME/.Trash/DockMiddleQuit-old-$(date +%Y%m%d-%H%M%S).app" 2>/dev/null || {
        echo "Could not move $LEGACY_APP to the Trash." >&2
        echo "Remove it manually, then run this installer again." >&2
        exit 1
    }
fi

mkdir -p "$HOME/Applications" "$SUPPORT" "$(dirname "$PLIST")" "$(dirname "$LOG")"
rm -rf "$APP"
ditto "$DAEMON_APP" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Keep the source and helper scripts with the installation, like the Setup app.
if [[ -f "$ROOT/src/DockMiddleQuit.swift" ]]; then
    cp "$ROOT/src/DockMiddleQuit.swift" "$SUPPORT/"
fi
if [[ -d "$ROOT/src/MultitouchSupport" ]]; then
    rm -rf "$SUPPORT/MultitouchSupport"
    cp -R "$ROOT/src/MultitouchSupport" "$SUPPORT/"
fi
cp "$ROOT/scripts/"*.sh "$ROOT/scripts/README.txt" "$SUPPORT/"
chmod +x "$SUPPORT/"*.sh

# Optional: keep the guided app around for permission fixes and uninstall.
if [[ -d "$SETUP_APP" ]]; then
    rm -rf "$SETUP_DEST"
    ditto "$SETUP_APP" "$SETUP_DEST"
    xattr -dr com.apple.quarantine "$SETUP_DEST" 2>/dev/null || true
fi

# MARK: Login item

cp "$ROOT/launchagent/$LABEL.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 \"$APP/Contents/MacOS/DockMiddleQuit\"" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath \"$LOG\"" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath \"$LOG\"" "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    # A just-stopped service can still be registered for a moment.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sleep 0.3
    launchctl bootstrap "$DOMAIN" "$PLIST"
fi
launchctl kickstart -k "$DOMAIN/$LABEL"

# Give the daemon a moment to write its status file.
for _ in {1..20}; do
    [[ -f "$SUPPORT/status.json" ]] && break
    sleep 0.25
done

echo ""
echo "Installed:"
echo "  App       $APP"
echo "  Login     $PLIST"
echo "  Log       $LOG"
echo "  Status    $SUPPORT/status.json"
echo ""
echo "macOS still needs your approval (it cannot be scripted):"
echo "  1. Accessibility      $APP"
echo "  2. Input Monitoring   $APP"
echo ""
echo "Open the guided permission screens with:"
echo "  open \"$SETUP_DEST\""
echo ""
echo "Or open System Settings directly:"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent'"
echo ""
echo "If the permission switch already looks on but the app still reports false,"
echo "click Grant Access again in the Setup app. It clears the stale record first."
echo ""
echo "Check the service with: $SUPPORT/status.sh"
