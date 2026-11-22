#!/bin/zsh
# UXTapFix installer
#
#   ./install.sh              Build and open the guided Setup app.
#   ./install.sh --headless   Install the daemon + login item without any UI.
#   ./install.sh --no-build   Use the existing dist/ build.
#
# The guided Setup app is the recommended path: it installs into your user
# folder, walks through permissions and launch at login, then shows gestures to try.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
SETUP_APP="$DIST/UXTapFix Setup.app"
DAEMON_APP="$DIST/UXTapFix.app"
APP="$HOME/Applications/UXTapFix.app"
SETUP_DEST="$HOME/Applications/UXTapFix Setup.app"
SUPPORT="$HOME/Library/Application Support/UXTapFix"
PLIST="$HOME/Library/LaunchAgents/com.user.uxtapfix.plist"
LOG="$HOME/Library/Logs/UXTapFix.log"
LEGACY_APP="/Applications/UXTapFix.app"
LABEL="com.user.uxtapfix"
DOMAIN="gui/$(id -u)"
OLD_APP="$HOME/Applications/DockMiddleQuit.app"
OLD_SETUP="$HOME/Applications/DockMiddleQuit Setup.app"
OLD_SUPPORT="$HOME/Library/Application Support/DockMiddleQuit"
OLD_PLIST="$HOME/Library/LaunchAgents/com.user.dockmiddlequit.plist"
OLD_LABEL="com.user.dockmiddlequit"
OLD_SYSTEM_APP="/Applications/DockMiddleQuit.app"
OLD_SYSTEM_SETUP="/Applications/DockMiddleQuit Setup.app"
STAGE_APP="$HOME/Applications/.UXTapFix.app.staging.$$"
BACKUP_APP="$HOME/Applications/.UXTapFix.app.backup.$$"

mode="guided"
build=1
force=0

usage() {
    cat <<'USAGE'
Usage: ./install.sh [--headless] [--no-build] [--force]

  (no option)   Build and open the guided Setup app.
  --headless    Install the daemon and login item without any UI.
  --no-build    Use the existing build in dist/.
  --force       Allow an older build over a newer install (headless only).
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --headless) mode="headless" ;;
        --no-build) build=0 ;;
        --force) force=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Run ./install.sh --help for usage." >&2
            exit 2
            ;;
    esac
done

if [[ "$mode" == "guided" && "$force" == 1 ]]; then
    echo "--force is only supported with --headless." >&2
    exit 2
fi

version_gt() {
    local -a lhs rhs
    lhs=("${(@s:.:)1}")
    rhs=("${(@s:.:)2}")
    local i
    for i in 1 2 3; do
        if (( ${lhs[i]:-0} > ${rhs[i]:-0} )); then return 0; fi
        if (( ${lhs[i]:-0} < ${rhs[i]:-0} )); then return 1; fi
    done
    return 1
}

check_downgrade() {
    local candidate="$1"
    [[ -d "$candidate" ]] || return 0
    local current
    current="$(plutil -extract CFBundleShortVersionString raw "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$current" ]] || return 0
    if version_gt "$current" "$NEW_VERSION"; then
        if (( force )); then
            echo "Warning: replacing newer UXTapFix $current with $NEW_VERSION."
        else
            echo "A newer copy of UXTapFix ($current) is installed at $candidate." >&2
            echo "This build is $NEW_VERSION. Use the newer installer, or pass --force." >&2
            exit 1
        fi
    fi
}

trash_or_remove() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    mkdir -p "$HOME/.Trash"
    local destination="$HOME/.Trash/$(basename "$path")-$(date +%Y%m%d-%H%M%S)"
    mv "$path" "$destination" 2>/dev/null || rm -rf "$path" 2>/dev/null || true
}

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
    if pgrep -x UXTapFixSetup >/dev/null 2>&1; then
        echo "UXTapFix Setup is already running. Close it, then run this installer again." >&2
        exit 1
    fi
    open "$SETUP_APP"
    echo ""
    echo "UXTapFix Setup is opening. Follow the short steps:"
    echo "  Welcome -> Permissions & Login -> Finish"
    exit 0
fi

# MARK: Headless install

echo "Installing UXTapFix for $(whoami)…"

cleanup_install() {
    if [[ -d "$BACKUP_APP" ]]; then
        if [[ ! -d "$APP" ]]; then
            mv "$BACKUP_APP" "$APP" 2>/dev/null || true
            launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
        else
            rm -rf "$BACKUP_APP" 2>/dev/null || true
        fi
    fi
    rm -rf "$STAGE_APP" 2>/dev/null || true
}
trap cleanup_install EXIT

NEW_VERSION="$(plutil -extract CFBundleShortVersionString raw "$DAEMON_APP/Contents/Info.plist")"
check_downgrade "$APP"
check_downgrade "$LEGACY_APP"

mkdir -p "$HOME/Applications" "$SUPPORT" "$(dirname "$PLIST")" "$(dirname "$LOG")"

# Recover a backup from a previously interrupted run before staging again.
if [[ -d "$BACKUP_APP" && ! -d "$APP" ]]; then
    mv "$BACKUP_APP" "$APP"
else
    rm -rf "$BACKUP_APP"
fi

# Stage and verify next to the destination. The running copy stays untouched
# until we reach the stop/replace/start section below.
find "$HOME/Applications" -maxdepth 1 -name '.UXTapFix.app.staging.*' -exec rm -rf {} + 2>/dev/null || true
rm -rf "$STAGE_APP"
ditto "$DAEMON_APP" "$STAGE_APP"
xattr -dr com.apple.quarantine "$STAGE_APP" 2>/dev/null || true
if [[ ! -x "$STAGE_APP/Contents/MacOS/UXTapFix" ]]; then
    echo "The staged app is missing its executable." >&2
    rm -rf "$STAGE_APP"
    exit 1
fi
if ! codesign --verify --deep --strict "$STAGE_APP"; then
    echo "The staged app failed code-signature verification." >&2
    rm -rf "$STAGE_APP"
    exit 1
fi

# Keep the source and helper scripts with the installation, like the Setup app.
if [[ -f "$ROOT/src/UXTapFix.swift" ]]; then
    cp "$ROOT/src/UXTapFix.swift" "$SUPPORT/"
fi
if [[ -d "$ROOT/src/MultitouchSupport" ]]; then
    rm -rf "$SUPPORT/MultitouchSupport"
    cp -R "$ROOT/src/MultitouchSupport" "$SUPPORT/"
fi
cp "$ROOT/scripts/"*.sh "$ROOT/scripts/README.txt" "$SUPPORT/"
chmod +x "$SUPPORT/"*.sh
chmod 644 "$SUPPORT/README.txt" 2>/dev/null || true

# Optional: keep the guided app around for permission fixes and uninstall.
if [[ -d "$SETUP_APP" ]]; then
    rm -rf "$SETUP_DEST"
    ditto "$SETUP_APP" "$SETUP_DEST"
    xattr -dr com.apple.quarantine "$SETUP_DEST" 2>/dev/null || true
fi

# MARK: Login item

cp "$ROOT/launchagent/$LABEL.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 \"$APP/Contents/MacOS/UXTapFix\"" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath \"$LOG\"" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath \"$LOG\"" "$PLIST"
plutil -lint "$PLIST" >/dev/null

# MARK: Legacy DockMiddleQuit cleanup

launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
pkill -x DockMiddleQuit 2>/dev/null || true
for old in "$OLD_SYSTEM_APP" "$OLD_SYSTEM_SETUP" "$OLD_APP" "$OLD_SETUP"; do
    trash_or_remove "$old"
done
rm -rf "$OLD_SUPPORT" 2>/dev/null || true
rm -f "$OLD_PLIST" /tmp/dock-middle-quit.log 2>/dev/null || true

# MARK: Stop the old service and swap in the verified app

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x UXTapFix 2>/dev/null || true
sleep 0.3

if [[ -d "$LEGACY_APP" ]]; then
    echo "Moving the old /Applications copy to the Trash…"
    mkdir -p "$HOME/.Trash"
    mv "$LEGACY_APP" "$HOME/.Trash/UXTapFix-old-$(date +%Y%m%d-%H%M%S).app" 2>/dev/null || {
        echo "Could not move $LEGACY_APP to the Trash." >&2
        echo "Remove it manually, then run this installer again." >&2
        rm -rf "$STAGE_APP"
        exit 1
    }
fi

if [[ -d "$APP" ]]; then
    mv "$APP" "$BACKUP_APP"
fi
if ! mv "$STAGE_APP" "$APP"; then
    rm -rf "$APP"
    if [[ -d "$BACKUP_APP" ]]; then
        mv "$BACKUP_APP" "$APP"
        launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
    fi
    echo "Could not move the new app into place." >&2
    exit 1
fi
rm -rf "$BACKUP_APP"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    # A just-stopped service can still be registered for a moment.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sleep 0.3
    launchctl bootstrap "$DOMAIN" "$PLIST"
fi
launchctl kickstart -k "$DOMAIN/$LABEL"

# Give the daemon a moment to write a fresh status file.
status_ok=0
for _ in {1..24}; do
    if [[ -f "$SUPPORT/status.json" ]]; then
        updated="$(plutil -extract updatedAt raw -o - "$SUPPORT/status.json" 2>/dev/null || true)"
        now="$(date +%s)"
        if printf '%s' "$updated" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
            updated_int="${updated%.*}"
            if (( now - updated_int < 8 )); then
                status_ok=1
                break
            fi
        fi
    fi
    sleep 0.25
done

echo ""
if (( status_ok )); then
    echo "Installed:"
else
    echo "Files installed, but the background service has not reported yet:"
fi
echo "  App       $APP"
echo "  Login     $PLIST"
echo "  Log       $LOG"
echo "  Status    $SUPPORT/status.json"
echo ""
echo "macOS still needs your approval (it cannot be scripted):"
echo "  Accessibility  $APP"
echo "  Input Monitoring is not required separately for this active event tap."
echo ""
echo "Open the guided permission screens with:"
echo "  open \"$SETUP_DEST\""
echo ""
echo "Or open System Settings directly:"
echo "  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
echo ""
echo "If the permission switch already looks on but the app still reports false,"
echo "click Open System Settings again in the Setup app. It clears the stale"
echo "Accessibility record first. Do not reset ListenEvent."
echo ""
echo "Check the service with: $SUPPORT/status.sh"
