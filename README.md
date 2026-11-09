# DockMiddleQuit

Middle-click (or three-finger tap) a Dock icon to quit that app.

A tiny macOS background utility with a guided setup assistant. It installs
entirely in your user folder, needs **no admin password**, and never phones
home.

```
middle-click an app in the Dock  ->  the app quits
```

## Requirements

- macOS 13 Ventura or later.
- Xcode Command Line Tools to build from source (`xcode-select --install`).
  The prebuilt DMG needs neither Xcode nor admin rights.

## Quick start

Build the app and its Setup assistant:

```sh
./build.sh
open "dist/DockMiddleQuit Setup.app"
```

Or use the convenience installer, which builds and opens the assistant:

```sh
./install.sh
```

On a Mac that already has a build in `dist/`, `./install.sh --no-build` skips
the compile.

If you downloaded a DMG, open **DockMiddleQuit Setup.app**. Because the app is
ad-hoc signed rather than notarized, macOS may say it cannot verify it the
first time — right-click the app and choose **Open**, or double-click
**Install DockMiddleQuit.command**, which clears the download quarantine flag
and opens the same assistant.

## What the Setup app does

The assistant is a five-step native SwiftUI app:

1. **Welcome** — what the utility does, with a live Dock animation.
2. **Install** — copies `DockMiddleQuit.app` to `~/Applications` and installs a
   per-user LaunchAgent. No admin rights, no system-wide changes.
3. **Access** — opens the exact macOS privacy panes and shows permission status
   live, read from the running background service.
4. **Login** — confirms the LaunchAgent so the utility is ready every time you
   log in. You can turn this off at any time.
5. **Ready** — a summary of permissions, login, and service health, plus an
   optional MiddleClick helper for trackpad taps.

The assistant copies itself to `~/Applications/DockMiddleQuit Setup.app`, so
you can reopen it later to check status, repair permissions, reinstall, view
the log, or uninstall. The gear menu has all of those actions.

If an old copy exists at `/Applications/DockMiddleQuit.app`, Setup stops it,
moves it to the Trash, and installs the new per-user build.

## Permissions

macOS requires you to flip these switches yourself; no app can do it for you.

| Permission | Why | Required |
| --- | --- | --- |
| **Accessibility** | Ask macOS which Dock icon is under the pointer. | Yes |
| **Input Monitoring** | Catch the middle click before the Dock flashes its menu. | Recommended |

Click **Grant Access** on a permission card. The assistant asks the daemon
process to register with macOS, then opens the matching System Settings pane.
The card updates within a couple of seconds after you flip the switch.

### If the switch looks on but status stays off

That usually means the permission belongs to an older build with a different
code signature. Click **Reset** on the affected card, then **Grant Access**
again. This clears the stale record with `tccutil` so macOS can add the current
app.

The terminal equivalent:

```sh
tccutil reset Accessibility com.user.dockmiddlequit
tccutil reset ListenEvent com.user.dockmiddlequit
```

After granting a permission, the assistant automatically restarts the service
so the event tap picks it up.

## Launch at login

Setup writes a per-user LaunchAgent:

```
~/Library/LaunchAgents/com.user.dockmiddlequit.plist
```

It starts DockMiddleQuit when you log in and restarts it if it exits. Toggle
**Launch at login** in the assistant to enable or disable it. Turning it off
stops the service and removes the plist; nothing else is affected.

## Three-finger tap

DockMiddleQuit reacts to a real middle click. Trackpad users can install the
free [MiddleClick](https://github.com/artginzburg/MiddleClick) app and map a
three-finger tap to a middle click. The Ready step detects MiddleClick, reports
whether the gesture is enabled, and offers to open it.

## Installed locations

| What | Where |
| --- | --- |
| Background app | `~/Applications/DockMiddleQuit.app` |
| Setup assistant | `~/Applications/DockMiddleQuit Setup.app` |
| Login item | `~/Library/LaunchAgents/com.user.dockmiddlequit.plist` |
| Live status | `~/Library/Application Support/DockMiddleQuit/status.json` |
| Helper scripts | `~/Library/Application Support/DockMiddleQuit/` |
| Log | `~/Library/Logs/DockMiddleQuit.log` |

The daemon rewrites `status.json` every two seconds with its version, PID,
permission state, event-tap state, and last quit. The Setup app polls that file
instead of guessing.

## Terminal install (headless)

For CI, remote setup, or people who prefer scripts:

```sh
./install.sh --headless
```

This builds the daemon, stops any old copy, migrates a legacy
`/Applications/DockMiddleQuit.app` to the Trash, installs the app and
LaunchAgent, starts the service, and prints the two permission steps. It also
copies the Setup app into `~/Applications` so the guided permission screens are
available afterward.

The scripts in `scripts/` are installed alongside the app:

```sh
~/Library/Application\ Support/DockMiddleQuit/status.sh
~/Library/Application\ Support/DockMiddleQuit/restart.sh
~/Library/Application\ Support/DockMiddleQuit/uninstall.sh
~/Library/Application\ Support/DockMiddleQuit/enable-finder-quit.sh
```

## Build a DMG

```sh
./make-dmg.sh
```

The script builds both apps and produces
`dist/DockMiddleQuit-2.2.dmg` with:

- `DockMiddleQuit Setup.app` (the self-contained installer, daemon embedded)
- `Install DockMiddleQuit.command` (quarantine-clearing launcher)
- `Read Me.txt`

The Setup app embeds the daemon, icon, source, and helper scripts, so it works
from the DMG without the repository.

## How it works

1. A `CGEventTap` listens for `otherMouseDown` with button number 2 (middle
   click). It swallows the click so the Dock context menu does not flash. If
   Input Monitoring is unavailable, an `NSEvent` global monitor is a passive
   fallback.
2. On each middle click, the Accessibility API resolves the element under the
   pointer (`AXUIElementCopyElementAtPosition`) and checks for `AXDockItem`.
3. The icon title is matched to a running app and quit with
   `NSRunningApplication.terminate()`. If needed it escalates to
   `forceTerminate()` after 1.2 seconds, then AppleScript.
4. `Trash`, `Launchpad`, `Mission Control`, and `Finder` are ignored. Finder
   relaunches immediately; `scripts/enable-finder-quit.sh` rebuilds with it
   allowed if you really want that.

The daemon is one Swift file (`src/DockMiddleQuit.swift`). The Setup app is
SwiftUI in `src/Setup/`. Both are built with `swiftc` and ad-hoc signed by
`build.sh`; there is no Xcode project.

## Troubleshooting

**The Setup app will not open.** macOS quarantined the ad-hoc signed download.
Right-click → **Open**, or run `Install DockMiddleQuit.command`.

**Accessibility says granted in System Settings but the app says otherwise.**
Use **Reset** on the permission card, then **Grant Access** again. Rebuilding
produces a new ad-hoc signature, so old approvals can be stale.

**Middle-click does nothing.** Open the gear menu → **Open Log**. Grant
Accessibility, then use **Restart** on the Login step. If the log mentions
`CGEventTap failed`, enable Input Monitoring as well.

**The service is stopped.** Open the Login step and make sure **Launch at
login** is on, then click **Restart**. You can also run
`~/Library/Application\ Support/DockMiddleQuit/restart.sh`.

**I want to see what it is doing.** Check the live status file:

```sh
cat ~/Library/Application\ Support/DockMiddleQuit/status.json
tail -f ~/Library/Logs/DockMiddleQuit.log
```

**Finder does not quit.** That is intentional: Finder immediately relaunches.
See `enable-finder-quit.sh` for the advanced rebuild.

## Uninstall

Open `~/Applications/DockMiddleQuit Setup.app`, use the gear menu →
**Uninstall DockMiddleQuit…**. That stops the service, removes the app, Setup
app, login item, helper files, log, and privacy records.

Headless equivalent:

```sh
~/Library/Application\ Support/DockMiddleQuit/uninstall.sh
```

The project is ad-hoc signed and not notarized. It requests no network access
and stores nothing beyond the local status/log files listed above.
