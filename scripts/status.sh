#!/bin/zsh
echo "=== DockMiddleQuit status ==="
echo "App bundle: $HOME/Applications/DockMiddleQuit.app"
ls -lh "$HOME/Applications/DockMiddleQuit.app/Contents/MacOS/DockMiddleQuit" 2>&1 | head
echo ""
echo "LaunchAgent: ~/Library/LaunchAgents/com.user.dockmiddlequit.plist"
launchctl print gui/$(id -u)/com.user.dockmiddlequit 2>&1 | head -n 50
echo ""
echo "Process:"
ps aux | grep -E "DockMiddleQuit|dock-middle" | grep -v grep 2>&1 | head
echo ""
echo "Log (last 30 lines):"
cat /tmp/dock-middle-quit.log 2>&1 | tail -n 30
echo ""
echo "MiddleClick config:"
defaults read art.ginzburg.MiddleClick 2>&1 | head -n 20
defaults read com.knollsoft.Middle 2>&1 | head -n 20
echo ""
echo "Dock autohide:"
defaults read com.apple.dock autohide 2>&1 | head
