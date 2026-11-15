# DockMiddleQuit

Middle-click (or three-finger tap/click) a Dock icon to quit that app.
Middle-click a browser tab to close it — the trackpad gesture is built in, so
you no longer need the MiddleClick helper app.

A tiny macOS background utility with a guided setup assistant. It installs
entirely in your user folder, needs **no admin password**, and never phones
home.

```
middle-click an app in the Dock  ->  the app quits
middle-click a browser tab       ->  the tab closes
```

## Requirements

- macOS 13 Ventura or later.
- Xcode Command Line Tools to build from source (`xcode-select --install`).
  The prebuilt DMG needs neither Xcode nor admin rights.

The trackpad gesture uses Apple's private `MultitouchSupport.framework`, so
this build is not App Store compatible. The Dock shortcut still works with any
real middle-click mouse if Apple ever removes the private interface.

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

The assistant is a four-step native SwiftUI app:

1. **Welcome** — animated previews of the two main gestures (quit a Dock app,
   close a browser tab) plus a short summary. Click **Install** to copy
   `DockMiddleQuit.app` to `~/Applications` and add a per-user LaunchAgent. No
   admin rights, no system-wide changes.
2. **Permissions** — opens the exact macOS privacy panes and shows permission
   status live, read from the running background service.
3. **Launch at Login** — confirms the LaunchAgent so the utility is ready every
   time you log in. You can turn this off at any time.
4. **Setup Complete** — a short summary of permissions, login, and service
   health.

The assistant copies itself to `~/Applications/DockMiddleQuit Setup.app`, so
you can reopen it later to check status, repair permissions, reinstall, view
the log, or uninstall. The menu in the window toolbar has all of those actions.

If an old copy exists at `/Applications/DockMiddleQuit.app`, Setup stops it,
moves it to the Trash, and installs the new per-user build.

## Permissions

macOS requires you to flip these switches yourself; no app can do it for you.

| Permission | Why | Required |
| --- | --- | --- |
| **Accessibility** | Ask macOS which Dock icon is under the pointer. | Yes |
| **Input Monitoring** | Catch the middle click before the Dock flashes its menu, and rewrite a three-finger physical click. | Recommended |

Click **Grant Access** on a permission row. The assistant asks the daemon
process to register with macOS, then opens the matching System Settings pane.
The row updates within a couple of seconds after you flip the switch.

### If the switch looks on but status stays off

That usually means the permission belongs to an older build with a different
code signature. Click **Reset** on the affected row, then **Grant Access**
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

## Three-finger tap and click

DockMiddleQuit turns a three-finger trackpad tap (or a physical click while
three fingers are on the trackpad) into a real middle click. The middle click
is posted system-wide, so the app under the pointer decides what to do:

| Where you middle-click | What happens |
| --- | --- |
| A Dock icon | The app quits |
| A browser tab (Chrome, Safari, Firefox, Arc, …) | The tab closes |
| A link | The browser opens it in a background tab |
| Terminal | Selected text is pasted |

Repeating the middle-click on the same Dock icon escalates:

| Middle-clicks on one Dock icon | What happens |
| --- | --- |
| 1× | The app quits normally. |
| 2× | The app and its background helper processes quit; anything still running is forced after 1.2 s. |
| 3× | The app and its helpers are force-quit immediately. |

Clicks are counted within about 300 ms, so a single click waits that long
before the app quits. Middle-clicks anywhere other than the Dock are never
counted or delayed.

The gesture is built in. You do **not** need MiddleClick anymore. If
MiddleClick is still running, quit it first — otherwise one gesture produces
two middle clicks. To remove it:

```sh
brew uninstall --cask middleclick
```

The defaults are three fingers and tap-to-click. You can change them:

```sh
defaults write com.user.dockmiddlequit middleClickEmulation -bool false
defaults write com.user.dockmiddlequit middleClickFingers 4
defaults write com.user.dockmiddlequit middleClickAllowMoreFingers -bool true
defaults write com.user.dockmiddlequit middleClickTapToClick -bool false
defaults write com.user.dockmiddlequit middleClickMaxTimeDelta 300
defaults write com.user.dockmiddlequit middleClickMaxDistanceDelta 0.05
defaults write com.user.dockmiddlequit middleClickMultiAction -bool false
defaults write com.user.dockmiddlequit middleClickMultiClickWindow 300
launchctl kickstart -k gui/$(id -u)/com.user.dockmiddlequit
```

- `middleClickEmulation false` disables the trackpad gesture but keeps the
  Dock shortcut for a real middle-click mouse.
- `middleClickFingers` accepts 2, 4, 5, or more. Two fingers conflicts with
  the normal right-click gesture.
- `middleClickAllowMoreFingers true` accepts the configured number or more.
- `middleClickTapToClick false` keeps three-finger physical clicks but
  disables the tap gesture.
- `middleClickMaxTimeDelta` is milliseconds; `middleClickMaxDistanceDelta` is
  in normalized trackpad units.
- `middleClickMultiAction false` turns off the 1×/2×/3× escalation: a single
  click quits immediately again and extra clicks behave like single clicks.
- `middleClickMultiClickWindow` is milliseconds, minimum 150. It is the
  window in which repeated clicks on the same Dock icon count toward the
  escalation.

If macOS opens Look Up on a three-finger tap, both actions can fire. Set
**System Settings → Trackpad → Point & Click → Look up & data detectors** to
**Force Click with one finger** to avoid the conflict.

The gesture relies on Apple's private `MultitouchSupport.framework`. It is not
App Store compatible and may stop working after a macOS update. If that
happens, the rest of DockMiddleQuit keeps working, and you can use a mouse or
another gesture utility for the middle click.

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
`dist/DockMiddleQuit-2.3.dmg` with:

- `DockMiddleQuit Setup.app` (the self-contained installer, daemon embedded)
- `Install DockMiddleQuit.command` (quarantine-clearing launcher)
- `Read Me.txt`

The Setup app embeds the daemon, icon, source, and helper scripts, so it works
from the DMG without the repository.

## How it works

1. A `CGEventTap` listens for `otherMouseDown` with button number 2 (middle
   click). It swallows the click when the pointer is over the Dock so the Dock
   context menu does not flash. If Input Monitoring is unavailable, an
   `NSEvent` global monitor is a passive fallback.
2. The private `MultitouchSupport.framework` reports trackpad touch frames. A
   short, still three-finger tap posts a real middle click at the pointer. A
   physical left/right click while three fingers are down is rewritten in the
   event tap to a middle click. Browsers and other apps then handle it
   natively — DockMiddleQuit does not script browsers.
3. On each middle click, the Accessibility API resolves the element under the
   pointer (`AXUIElementCopyElementAtPosition`) and checks for `AXDockItem`.
4. The icon title is matched to a running app and quit with
   `NSRunningApplication.terminate()`. If needed it escalates to
   `forceTerminate()` after 1.2 seconds, then AppleScript.
5. `Trash`, `Launchpad`, `Mission Control`, and `Finder` are ignored. Finder
   relaunches immediately; `scripts/enable-finder-quit.sh` rebuilds with it
   allowed if you really want that.

The daemon is one Swift file (`src/DockMiddleQuit.swift`) plus a minimal
private-framework header in `src/MultitouchSupport/`. The Setup app is SwiftUI
in `src/Setup/`. Both are built with `swiftc` and ad-hoc signed by `build.sh`;
there is no Xcode project.

## Troubleshooting

**The Setup app will not open.** macOS quarantined the ad-hoc signed download.
Right-click → **Open**, or run `Install DockMiddleQuit.command`.

**Accessibility says granted in System Settings but the app says otherwise.**
Use **Reset** on the permission row, then **Grant Access** again. Rebuilding
produces a new ad-hoc signature, so old approvals can be stale.

**Middle-click does nothing.** Open the toolbar menu → **Open Log**. Grant
Accessibility, then use **Restart** on the Launch at Login step. If the log
mentions `CGEventTap failed`, enable Input Monitoring as well.

**Three-finger tap does nothing.** Check the log for
`Three-finger middle-click enabled`. If it says no multitouch device was found,
make sure the trackpad is connected and restart the service. Also quit
MiddleClick if it is still running: two gesture apps both post a click. If the
gesture is disabled, run
`defaults write com.user.dockmiddlequit middleClickEmulation -bool true` and
restart.

**Three-finger tap opens Look Up instead.** Set **System Settings → Trackpad →
Point & Click → Look up & data detectors** to **Force Click with one finger**.

**A browser tab does not close.** The browser decides what a middle click
does; DockMiddleQuit only posts the click. Test with a mouse that has a real
middle button. Chrome, Safari, Firefox, Arc, and most other browsers close a
tab when its tab is middle-clicked.

**The service is stopped.** Open the Launch at Login step and make sure
**Start DockMiddleQuit when I log in** is on, then click **Restart**. You can
also run `~/Library/Application\ Support/DockMiddleQuit/restart.sh`.

**I want to see what it is doing.** Check the live status file:

```sh
cat ~/Library/Application\ Support/DockMiddleQuit/status.json
tail -f ~/Library/Logs/DockMiddleQuit.log
```

**Finder does not quit.** That is intentional: Finder immediately relaunches.
See `enable-finder-quit.sh` for the advanced rebuild.

## Uninstall

Open `~/Applications/DockMiddleQuit Setup.app`, use the toolbar menu →
**Uninstall DockMiddleQuit…**. That stops the service, removes the app, Setup
app, login item, helper files, log, and privacy records.

Headless equivalent:

```sh
~/Library/Application\ Support/DockMiddleQuit/uninstall.sh
```

The project is ad-hoc signed and not notarized. It requests no network access
and stores nothing beyond the local status/log files listed above.
