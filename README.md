# UXTapFix

Improve missing UX on your MacBook. This was never finished feature and always overlooked. A three-finger trackpad tap that closes tabs, opens links, and quits Dock apps.

<p align="center">
  <img src="assets/previews/three-finger-tap.gif" width="254" alt="A three-finger tap and a middle click light up as the same action">
  <img src="assets/previews/quit-dock-app.gif" width="254" alt="A three-finger tap on a Dock icon quits the app">
  <img src="assets/previews/multi-action.gif" width="254" alt="One click quits, three clicks force quit">
</p>


## Gestures

- Close tabs and open links in a new tab with a 3-finger tap / middle click.
- Quit app from Dock with 3-finger tap / middle click.
- Force quit app from Dock with 3x 3-finger tap / middle click.
- Paste text in Terminal with 3-finger tap

## Install

Download the installer from latest [release](https://github.com/janmichek/UXTapFix/releases/). Continue with helpful installer setup.

Setup installs a small background service in your user folder and helps you grant the permissions macOS requires. No admin password, and it never phones home. Requires **macOS 13** or later.

**Possible conflicts:** if macOS opens Look Up on a three-finger tap, set **System Settings → Trackpad → Point & Click → Look up & data detectors** to *Force Click with one finger*.

The trackpad gesture uses Apple's private `MultitouchSupport.framework` (weak-linked, not App Store compatible). A real middle-click mouse still quits Dock apps if that framework is missing.

## Permissions

**Accessibility** is required. It lets UXTapFix see which Dock icon is under the pointer and create the event tap. macOS requires you to flip the switch yourself. After you do, Setup restarts the service; the daemon also retries the tap on its own.
