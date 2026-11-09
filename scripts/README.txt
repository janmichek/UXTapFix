DockMiddleQuit helper scripts
=============================

The main way to install, repair permissions, and uninstall is the guided app:

  ~/Applications/DockMiddleQuit Setup.app

These scripts are for terminal users and troubleshooting. They are copied to:

  ~/Library/Application Support/DockMiddleQuit/

Installed locations
-------------------
  App:         ~/Applications/DockMiddleQuit.app
  Login item:  ~/Library/LaunchAgents/com.user.dockmiddlequit.plist
  Log:         ~/Library/Logs/DockMiddleQuit.log
  Live status: ~/Library/Application Support/DockMiddleQuit/status.json
  Source:      ~/Library/Application Support/DockMiddleQuit/DockMiddleQuit.swift

Scripts
-------
  status.sh
      Shows the app version, launchd state, live permission check, status file,
      log tail, and MiddleClick configuration.

  restart.sh
      Restarts the LaunchAgent and prints the newest log lines.

  uninstall.sh
      Stops the service and removes the app, Setup app, login item, helper
      files, log, and privacy records. Add --yes to skip the confirmation.

  enable-finder-quit.sh
      Advanced: rebuilds the daemon with Finder removed from the blacklist.
      Finder normally reopens instantly, so this is off by default. The rebuild
      changes the ad-hoc signature, so Accessibility must be approved again.
      Reinstalling from Setup restores the normal build.

Permissions (manual, by macOS design)
-------------------------------------
  1. System Settings -> Privacy & Security -> Accessibility
     Enable DockMiddleQuit.
  2. System Settings -> Privacy & Security -> Input Monitoring
     Enable DockMiddleQuit (recommended; makes quitting smoother).

  If a switch already looks on but status still shows false, the entry belongs
  to an older build. In Setup, click Reset on that permission card, then Grant
  Access again. The equivalent terminal command is:

    tccutil reset Accessibility com.user.dockmiddlequit
    tccutil reset ListenEvent com.user.dockmiddlequit

Launch at login
---------------
  The Setup app writes a per-user LaunchAgent with RunAtLoad + KeepAlive.
  Turning "Launch at login" off removes the plist and stops the service.
  To restart it manually:

    launchctl kickstart -k gui/$(id -u)/com.user.dockmiddlequit

Three-finger tap
----------------
  DockMiddleQuit reacts to a middle click. The free MiddleClick app maps a
  three-finger tap to a middle click:

    https://github.com/artginzburg/MiddleClick

  The Setup app detects MiddleClick and offers to open it.
