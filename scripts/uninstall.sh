#!/bin/zsh
echo "Uninstalling DockMiddleQuit..."
launchctl bootout gui/$(id -u)/com.user.dockmiddlequit 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/com.user.dockmiddlequit.plist"
rm -rf "$HOME/Applications/DockMiddleQuit.app"
rm -f "$HOME/.local/bin/dock-middle-quit"
rm -f /tmp/dock-middle-quit.log
echo "Done. Also remove from System Settings -> Privacy & Security -> Accessibility & Input Monitoring if listed."
