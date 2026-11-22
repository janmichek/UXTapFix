# UXTapFix

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
open "dist/UXTapFix Setup.app"
```

Or use the convenience installer, which builds and opens the assistant:

```sh
./install.sh
```

On a Mac that already has a build in `dist/`, `./install.sh --no-build` skips
the compile.

If you downloaded a DMG, open **UXTapFix Setup.app**. Because the app is
ad-hoc signed rather than notarized, macOS may say it cannot verify it the
first time — right-click the app and choose **Open**, or double-click
**Install UXTapFix.command**, which clears the download quarantine flag
and opens the same assistant.

## What the Setup app does

The assistant is a three-step native SwiftUI app:

1. **Welcome** — animated previews of three features (a three-finger trackpad
   tap synced to a middle click, quitting a Dock app, and a triple-click
   force quit) plus a short summary. Click **Install** to copy
   `UXTapFix.app` to `~/Applications` and add a per-user LaunchAgent. No
   admin rights, no system-wide changes.
2. **Permissions & Login** — opens the exact macOS privacy panes and shows
   permission status live, read from the running background service. The
   **Start UXTapFix when I log in** switch lives here too, so the utility is
   ready every time you log in. You can turn it off at any time.
3. **Finish** — shows a few gestures to try. **Finish** closes the assistant.

The assistant copies itself to `~/Applications/UXTapFix Setup.app`, so
you can reopen it later to review permission status. The footer has a **Close**
button.

If an old copy exists at `/Applications/UXTapFix.app`, Setup stops it,
moves it to the Trash, and installs the new per-user build.

## Permissions

macOS requires you to flip these switches yourself; no app can do it for you.

| Permission | Why | Required |
| --- | --- | --- |
| **Accessibility** | Ask macOS which Dock icon is under the pointer, and create the event tap that catches middle clicks. | Yes |
| **Input Monitoring** | Included automatically with Accessibility. No separate switch is needed. | Built in |

Click **Open System Settings** on the Accessibility row. The assistant asks the
daemon process to register with macOS, then opens the matching System Settings
pane. The row updates within a couple of seconds after you flip the switch.

macOS does not reliably list ad-hoc builds in the **Input Monitoring** pane.
UXTapFix does not need a separate entry there: Accessibility already grants
both listen and post access, so the event tap works with Accessibility alone.
Setup therefore shows a single Accessibility row; Input Monitoring counts as
granted as soon as Accessibility is.

### If the switch looks on but status stays off

That usually means the permission belongs to an older build with a different
code signature. Click **Open System Settings** again. While the service is
reporting live status, Setup clears the stale Accessibility record with
`tccutil` first so macOS can add the current app.

The terminal equivalent:

```sh
tccutil reset Accessibility com.user.uxtapfix
```

Do **not** reset `ListenEvent`: it removes UXTapFix from the Input Monitoring
list, and an ad-hoc build cannot reliably add itself back. The app does not
need that entry.

After granting a permission, the assistant automatically restarts the service
so the event tap picks it up. The daemon also retries the tap on its own, so a
grant that lands after launch does not require a manual restart.

## Launch at login

Setup writes a per-user LaunchAgent:

```
~/Library/LaunchAgents/com.user.uxtapfix.plist
```

It starts UXTapFix when you log in and restarts it if it exits. Toggle
**Start UXTapFix when I log in** on the **Permissions & Login** step to enable
or disable it. Turning it off stops the service and removes the plist; nothing
else is affected.

## Three-finger tap and click

UXTapFix turns a three-finger trackpad tap (or a physical click while
three fingers are on the trackpad) into a real middle click. The middle click
is posted system-wide, so the app under the pointer decides what to do:

| Where you middle-click | What happens |
| --- | --- |
| A Dock icon | The app quits |
| A browser tab (Chrome, Safari, Firefox, Arc, …) | The tab closes |
| A link | The browser opens it in a background tab |
| Terminal | Selected text is pasted |

Repeating the middle-click on the same Dock icon:

| Middle-clicks on one Dock icon | What happens |
| --- | --- |
| 1× | The app and any helpers it leaves behind quit; its Dock tile is cleared. The app is never force-quit — it gets as long as it needs for a save sheet or a slow shutdown. |
| 2× | Same as a single click; there is no separate 2× action. |
| 3× | The app and its helpers are force-quit immediately. |

On macOS 26 and later, a quit app can leave its Dock icon behind with a
**Running in Background** label. After a normal or force quit, UXTapFix also
presses the Dock's own **Stop Running in Background** command when that state
is present, so the icon goes away instead of lingering.

Clicks count as a sequence when they follow each other within your Mac's
double-click speed (about half a second by default), so a single click waits
that long before the app quits. A third click or tap force-quits right away.
Middle-clicks anywhere other than the Dock are never counted or delayed.

The gesture is built in. You do **not** need MiddleClick anymore. If
MiddleClick is still running, quit it first — otherwise one gesture produces
two middle clicks. To remove it:

```sh
brew uninstall --cask middleclick
```

The defaults are three fingers and tap-to-click. You can change them:

```sh
defaults write com.user.uxtapfix middleClickEmulation -bool false
defaults write com.user.uxtapfix middleClickFingers 4
defaults write com.user.uxtapfix middleClickAllowMoreFingers -bool true
defaults write com.user.uxtapfix middleClickTapToClick -bool false
defaults write com.user.uxtapfix middleClickMaxTimeDelta 300
defaults write com.user.uxtapfix middleClickMaxDistanceDelta 0.05
defaults write com.user.uxtapfix middleClickMultiAction -bool false
defaults write com.user.uxtapfix middleClickMultiClickWindow 500
launchctl kickstart -k gui/$(id -u)/com.user.uxtapfix
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
- `middleClickMultiAction false` turns off the 3× force-quit escalation: a
  single click quits immediately and extra clicks behave like single clicks.
- `middleClickMultiClickWindow` is milliseconds, minimum 150. It is the
  longest gap allowed between repeated clicks on the same Dock icon. By
  default it follows your Mac's double-click setting (at least 500 ms), so
  normal triple-clicks with a mouse are counted reliably.

If macOS opens Look Up on a three-finger tap, both actions can fire. Set
**System Settings → Trackpad → Point & Click → Look up & data detectors** to
**Force Click with one finger** to avoid the conflict.

The gesture relies on Apple's private `MultitouchSupport.framework`. It is not
App Store compatible and may stop working after a macOS update. If that
happens, the rest of UXTapFix keeps working, and you can use a mouse or
another gesture utility for the middle click.

## Installed locations

| What | Where |
| --- | --- |
| Background app | `~/Applications/UXTapFix.app` |
| Setup assistant | `~/Applications/UXTapFix Setup.app` |
| Login item | `~/Library/LaunchAgents/com.user.uxtapfix.plist` |
| Live status | `~/Library/Application Support/UXTapFix/status.json` |
| Helper scripts | `~/Library/Application Support/UXTapFix/` |
| Log | `~/Library/Logs/UXTapFix.log` |

The daemon rewrites `status.json` every two seconds with its version, PID,
permission state, event-tap state, and last quit. The Setup app polls that file
instead of guessing.

## Terminal install (headless)

For CI, remote setup, or people who prefer scripts:

```sh
./install.sh --headless
```

This builds the daemon, stops any old copy, migrates a legacy
`/Applications/UXTapFix.app` to the Trash, installs the app and
LaunchAgent, starts the service, and prints the two permission steps. It also
copies the Setup app into `~/Applications` so the guided permission screens are
available afterward.

The scripts in `scripts/` are installed alongside the app:

```sh
~/Library/Application\ Support/UXTapFix/status.sh
~/Library/Application\ Support/UXTapFix/restart.sh
~/Library/Application\ Support/UXTapFix/uninstall.sh
~/Library/Application\ Support/UXTapFix/enable-finder-quit.sh
```

## Build a DMG

```sh
./make-dmg.sh
```

The script builds both apps and produces
`dist/UXTapFix-2.3.dmg` with:

- `UXTapFix Setup.app` (the self-contained installer, daemon embedded)
- `Install UXTapFix.command` (quarantine-clearing launcher)
- `Read Me.txt`

The Setup app embeds the daemon, icon, source, and helper scripts, so it works
from the DMG without the repository.

## How it works

1. A `CGEventTap` listens for `otherMouseDown` with button number 2 (middle
   click). It swallows the click when the pointer is over the Dock so the Dock
   context menu does not flash. Accessibility grants both listen and post
   access; if the tap cannot be created, an `NSEvent` global monitor is a
   passive fallback.
2. The private `MultitouchSupport.framework` reports trackpad touch frames. A
   short, still three-finger tap posts a real middle click at the pointer. A
   physical left/right click while three fingers are down is rewritten in the
   event tap to a middle click. Browsers and other apps then handle it
   natively — UXTapFix does not script browsers.
3. On each middle click, the Accessibility API resolves the element under the
   pointer (`AXUIElementCopyElementAtPosition`) and checks for `AXDockItem`.
4. The icon title is matched to a running app and quit with
   `NSRunningApplication.terminate()`. A normal quit waits for the app to exit
   on its own; only a triple-click calls `forceTerminate()`.
5. `Trash`, `Launchpad`, `Mission Control`, and `Finder` are ignored. Finder
   relaunches immediately; `scripts/enable-finder-quit.sh` rebuilds with it
   allowed if you really want that.

The daemon is one Swift file (`src/UXTapFix.swift`) plus a minimal
private-framework header in `src/MultitouchSupport/`. The Setup app is SwiftUI
in `src/Setup/`. Both are built with `swiftc` and ad-hoc signed by `build.sh`;
there is no Xcode project.

## Troubleshooting

**The Setup app will not open.** macOS quarantined the ad-hoc signed download.
Right-click → **Open**, or run `Install UXTapFix.command`.

**Accessibility says granted in System Settings but the app says otherwise.**
Click **Grant Access** again. Rebuilding produces a new ad-hoc signature, so old
approvals can be stale.

**Middle-click does nothing.** Check `~/Library/Logs/UXTapFix.log`. Grant
Accessibility, then run
`~/Library/Application\ Support/UXTapFix/restart.sh`. If the log says
`CGEventTap failed`, the event tap is waiting for Accessibility. Input
Monitoring is included with Accessibility and does not need a separate grant.

**Three-finger tap does nothing.** Check the log for
`Three-finger middle-click enabled`. If it says no multitouch device was found,
make sure the trackpad is connected and restart the service. Also quit
MiddleClick if it is still running: two gesture apps both post a click. If the
gesture is disabled, run
`defaults write com.user.uxtapfix middleClickEmulation -bool true` and
restart.

**Three-finger tap opens Look Up instead.** Set **System Settings → Trackpad →
Point & Click → Look up & data detectors** to **Force Click with one finger**.

**A browser tab does not close.** The browser decides what a middle click
does; UXTapFix only posts the click. Test with a mouse that has a real
middle button. Chrome, Safari, Firefox, Arc, and most other browsers close a
tab when its tab is middle-clicked.

**The service is stopped.** Open the Permissions & Login step and make sure
**Start UXTapFix when I log in** is on. You can also run
`~/Library/Application\ Support/UXTapFix/restart.sh`.

**I want to see what it is doing.** Check the live status file:

```sh
cat ~/Library/Application\ Support/UXTapFix/status.json
tail -f ~/Library/Logs/UXTapFix.log
```

**Finder does not quit.** That is intentional: Finder immediately relaunches.
See `enable-finder-quit.sh` for the advanced rebuild.

## Uninstall

Run the headless uninstaller:

```sh
~/Library/Application\ Support/UXTapFix/uninstall.sh
```

That stops the service and removes the app, Setup app, login item, helper
files, log, and privacy records.

The project is ad-hoc signed and not notarized. It requests no network access
and stores nothing beyond the local status/log files listed above.
