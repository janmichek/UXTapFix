# DockMiddleQuit

Middle-click (or 3-finger tap) a Dock icon to quit that app.

This is a backup of a small tool I vibecoded on 2026-09-11. It is **not** a
third-party app — it's a ~160-line Swift file compiled into a custom `.app`
bundle and kept alive by a macOS LaunchAgent.

## What it actually is

| Piece | What it is |
| --- | --- |
| `DockMiddleQuit.app` | A single Swift CLI binary wrapped in a minimal `.app` bundle (96 KB). `LSUIElement` = true, so it has no Dock icon. |
| `com.user.dockmiddlequit.plist` | A per-user LaunchAgent (`RunAtLoad` + `KeepAlive`) that runs the binary at login and restarts it if it dies. |
| `DockMiddleQuit.swift` | The entire program. One file, no project, no Xcode, no dependencies. |
| `MiddleClick.app` | Separate app, **not** part of this. It maps 3-finger tap → middle click. DockMiddleQuit only sees a middle click. |

So "the app" is really: **a Swift file + a launchd service**. There was never an
Xcode project or package — it was built with `swiftc` and `codesign`.

## How it works

1. Listens for `otherMouseDown` with button number 2 (middle click), using a
   `CGEventTap` (swallows the click so the Dock context menu doesn't flash) with
   an `NSEvent` global monitor as fallback.
2. On each middle click, asks the Accessibility API what's under the cursor
   (`AXUIElementCopyElementAtPosition`) and checks the role is `AXDockItem`.
3. Reads the icon's title, then quits the matching running app via
   `NSRunningApplication.terminate()`, falling back to `forceTerminate()` after
   1.2 s and then AppleScript (`tell application "…" to quit`).
4. Ignores `Trash`, `Launchpad`, `Mission Control`, and `Finder` (Finder just
   relaunches; see `scripts/enable-finder-quit.sh` to change that).

## Layout of this backup

```
DockMiddleQuit/
├── README.md
├── build.sh                  rebuild the .app from source
├── install.sh                build + install LaunchAgent + start (fresh Mac restore)
├── src/
│   └── DockMiddleQuit.swift  the whole program
├── bundle/
│   └── Info.plist            app bundle metadata (LSUIElement, TCC usage strings)
├── launchagent/
│   └── com.user.dockmiddlequit.plist
├── scripts/                  original helpers, preserved as-is
│   ├── README.txt            original install notes
│   ├── restart.sh            kickstart the daemon and tail the log
│   ├── status.sh             daemon status, log, MiddleClick config
│   ├── uninstall.sh          bootout + remove app, plist, log
│   └── enable-finder-quit.sh edit source to allow quitting Finder, rebuild
└── dist/
    └── DockMiddleQuit.app    prebuilt copy of the working v2.1 bundle
```

## Restore on a new Mac

```sh
./install.sh
```

Then grant permissions manually (macOS TCC cannot be scripted):

- System Settings → Privacy & Security → **Accessibility** → add
  `~/Applications/DockMiddleQuit.app`, enable it.
- System Settings → Privacy & Security → **Input Monitoring** → same.

Start it: `launchctl kickstart -k gui/$(id -u)/com.user.dockmiddlequit`
Check it: `tail -f /tmp/dock-middle-quit.log`

For 3-finger tap, install [MiddleClick](https://github.com/artginzburg/MiddleClick)
and make sure 3-finger tap → middle click is enabled. Without it, only a real
middle mouse button works.

## Gotchas

- **Rebuilding resets permissions.** The app is ad-hoc signed (`codesign -s -`),
  so a rebuild produces a new signature and macOS may drop it from Accessibility
  / Input Monitoring. Re-add it if it goes silent.
- **Input Monitoring** is needed for the `CGEventTap` path; without it the app
  falls back to a passive monitor and the Dock menu may briefly flash.
- No entitlements, no notarization, no sandbox. Ad-hoc signed only.
- `scripts/*.sh` from the original install still hardcode `$HOME` paths — fine on
  this machine, adjust if restoring elsewhere.
- Log lives at `/tmp/dock-middle-quit.log` and is wiped on reboot.

## Original install locations (for reference)

```
~/Applications/DockMiddleQuit.app
~/.local/bin/dock-middle-quit
~/Library/Application Support/DockMiddleQuit/   (source + helper scripts)
~/Library/LaunchAgents/com.user.dockmiddlequit.plist
/tmp/dock-middle-quit.log
```
