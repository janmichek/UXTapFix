DockMiddleQuit - middle-click (or 3-finger tap) on Dock icon to quit app
=========================================================================

Installed:
  App: ~/Applications/DockMiddleQuit.app  (LSUIElement, no Dock icon)
  Binary also at ~/.local/bin/dock-middle-quit
  LaunchAgent: ~/Library/LaunchAgents/com.user.dockmiddlequit.plist  (RunAtLoad + KeepAlive)
  Log: /tmp/dock-middle-quit.log
  Swift source: ~/Library/Application Support/DockMiddleQuit/DockMiddleQuit.swift

How it works:
  - Listens for otherMouseDown button 2 (middle click)
    * physical middle mouse button
    * 3-finger tap (via MiddleClick.app which maps 3-finger tap -> middle click)
      MiddleClick.app is already installed on this Mac (art.ginzburg.MiddleClick 3.1.3)
  - Uses Accessibility API to find which Dock icon is under cursor (AXDockItem)
  - Quits that app via NSRunningApplication.terminate() or AppleScript

Blocked icons (won't quit): Trash, Launchpad, Mission Control, Finder
  Finder is blocked because quitting it just relaunches; run enable-finder-quit.sh to allow.

Required permissions (manual, due to macOS TCC):
  1. System Settings -> Privacy & Security -> Accessibility
     Click + -> Add -> ~/Applications/DockMiddleQuit.app (or ~/.local/bin/dock-middle-quit)
     Enable the toggle.
  2. System Settings -> Privacy & Security -> Input Monitoring
     Same: Add DockMiddleQuit.app and enable.
     (If using fallback NSEvent monitor, Input Monitoring may still be needed on macOS 15+.)

After granting, restart daemon:
  ~/Library/Application\ Support/DockMiddleQuit/restart.sh
  or: launchctl kickstart -k gui/$(id -u)/com.user.dockmiddlequit

Verify:
  tail -f /tmp/dock-middle-quit.log
  Then middle-click (or 3-finger tap) a Dock icon (e.g., TextEdit, Calculator).
  Log should show: "middle-click on 'TextEdit' at (x,y) -> quitting"
  Status script: ~/Library/Application\ Support/DockMiddleQuit/status.sh

Three-finger setup:
  MiddleClick.app already maps 3-finger tap -> middle click (trackpadThreeTap=1).
  To also map 3-finger *click* (press), run:
    defaults write art.ginzburg.MiddleClick trackpadThreeClick -bool true
    killall MiddleClick; open -a MiddleClick

Uninstall:
  ~/Library/Application\ Support/DockMiddleQuit/uninstall.sh

Note: If daemon shows "Accessibility NOT granted" or "CGEventTap failed" in log,
      you still need to add it to Accessibility/Input Monitoring as above.
