DockMiddleQuit helper scripts
=============================

The main way to install and repair permissions is the guided app:

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
  Header:      ~/Library/Application Support/DockMiddleQuit/MultitouchSupport/

Scripts
-------
  status.sh
      Shows the app version, launchd state, live permission check, status file,
      log tail, trackpad settings, and whether MiddleClick is still running.

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
  to an older build. In Setup, click Grant Access again; it clears the stale
  record first. The equivalent terminal command is:

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
  Built in. A three-finger tap (or a physical click with three fingers down on
  the trackpad) sends a real middle click:

    Dock icon     -> the app quits
    Browser tab   -> the tab closes
    Terminal      -> selected text is pasted

  Quit the MiddleClick app if it is still running, otherwise one gesture makes
  two middle clicks. Remove it with: brew uninstall --cask middleclick

  Settings (then restart the service):

    defaults write com.user.dockmiddlequit middleClickEmulation -bool false
    defaults write com.user.dockmiddlequit middleClickFingers 4
    defaults write com.user.dockmiddlequit middleClickTapToClick -bool false
    launchctl kickstart -k gui/$(id -u)/com.user.dockmiddlequit

  The gesture uses Apple's private MultitouchSupport framework and may stop
  working after a macOS update.
