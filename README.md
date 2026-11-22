# UXTapFix

A three-finger tap that closes tabs, opens links, and quits Dock apps.

- Close tabs and open links in a new tab with a 3-finger tap.
- Tap a Dock icon with three fingers to quit the app.
- Click or tap once to quit, or three times to force quit.

Setup installs a small background service in your user folder and helps you grant the permissions macOS requires. No admin password, and it never phones home. Requires **macOS 13** or later.

The trackpad gesture uses Apple's private `MultitouchSupport.framework` (weak-linked, not App Store compatible). A real middle-click mouse still quits Dock apps if that framework is missing.

## Install

From source (Xcode Command Line Tools: `xcode-select --install`):

```sh
./build.sh
open "dist/UXTapFix Setup.app"
```

`./install.sh` builds and opens Setup. `./install.sh --no-build` uses the build already in `dist/`. `./install.sh --headless` installs the app and login item without UI; add `--force` to replace a newer install.

From a DMG, open **UXTapFix Setup.app**. The release is ad-hoc signed, not notarized. Verify the SHA-256 that `make-dmg.sh` prints against the downloaded file. If macOS blocks the app, right-click it and choose **Open**, or double-click **Install UXTapFix.command** (it copies Setup to a writable temp folder, clears quarantine, and opens it).

`./make-dmg.sh` writes `dist/UXTapFix-2.3.dmg` with Setup, `Install UXTapFix.command`, and `Read Me.txt`. Setup embeds the daemon, so the DMG works without the repository.

## Setup

1. **Welcome** — previews of the three-finger tap, Dock quit, and triple-click force quit. **Install** starts installation.
2. **Install** — starts right away and shows a live checklist: copies `UXTapFix.app` to `~/Applications` and adds a per-user LaunchAgent. An older copy in `/Applications` is moved to the Trash. A leftover DockMiddleQuit install is removed.
3. **Setup** — opens System Settings for Accessibility and shows live status from the running service. **Start UXTapFix when I log in** is on this step. Turning it off stops the service and removes the login item.
4. **Finish** — gestures to try. Setup also copies itself to `~/Applications/UXTapFix Setup.app`.

## Permissions

**Accessibility** is required. It lets UXTapFix see which Dock icon is under the pointer and create the event tap. macOS requires you to flip the switch yourself. After you do, Setup restarts the service; the daemon also retries the tap on its own.

This build uses an active filtering tap, which Accessibility authorizes. It does not need a separate Input Monitoring entry. Leave `ListenEvent` alone; resetting it drops the app from that pane, and an ad-hoc build cannot reliably add itself back.

If System Settings shows Accessibility on but Setup stays off, the grant belongs to an older signature. Click **Open System Settings** again — Setup clears the stale record — or run:

```sh
tccutil reset Accessibility com.user.uxtapfix
```

## Gestures

| Where | What happens |
| --- | --- |
| Dock icon, once | The app quits and any leftover helpers stop. It is never force-quit, so a save sheet can stay open. |
| Same Dock icon, twice | Same as once. There is no separate second-click action. |
| Same Dock icon, 3× | Force quit. |
| Browser tab | The tab closes (Chrome, Safari, Firefox, Arc, and most others). |
| A link | Opens in a background tab. |
| Terminal | Pastes the selection. |

Clicks on one Dock icon count when each follows the last within your double-click speed (at least half a second). A single click waits that long; a third click force-quits immediately. Clicks outside the Dock are not counted or delayed.

On macOS 26 and later, a quit app can linger in the Dock as **Running in Background**. UXTapFix then runs the Dock's **Stop Running in Background** command.

Quit MiddleClick if it is still installed (`brew uninstall --cask middleclick`); both apps would post a click. If a three-finger tap opens Look Up, set **System Settings → Trackpad → Point & Click → Look up & data detectors** to **Force Click with one finger**.

Finder, Trash, Launchpad, and Mission Control are ignored. To allow quitting Finder (it relaunches immediately), set `middleClickAllowFinderQuit` or run `enable-finder-quit.sh`.

Defaults live in `com.user.uxtapfix`. After a change:

```sh
launchctl kickstart -k gui/$(id -u)/com.user.uxtapfix
```

| Key | Default | |
| --- | --- | --- |
| `middleClickEmulation` | `true` | Trackpad gesture. `false` keeps a real middle-click mouse. |
| `middleClickFingers` | `3` | `2` or more. Two fingers conflicts with right-click. |
| `middleClickAllowMoreFingers` | `false` | Accept the configured count or more. |
| `middleClickTapToClick` | `true` | `false` keeps physical multi-finger clicks only. |
| `middleClickMaxTimeDelta` | `300` | Milliseconds. |
| `middleClickMaxDistanceDelta` | `0.05` | Normalized trackpad units. |
| `middleClickMultiAction` | `true` | `false` quits on the first click and skips force-quit. |
| `middleClickMultiClickWindow` | system | Milliseconds, minimum 150. Follows the double-click interval, at least 500, unless set. |
| `middleClickAllowFinderQuit` | `false` | Finder relaunches immediately. |

## Files

| What | Where |
| --- | --- |
| App | `~/Applications/UXTapFix.app` |
| Setup | `~/Applications/UXTapFix Setup.app` |
| Login item | `~/Library/LaunchAgents/com.user.uxtapfix.plist` |
| Status | `~/Library/Application Support/UXTapFix/status.json` |
| Scripts | `status.sh`, `restart.sh`, `uninstall.sh`, `enable-finder-quit.sh` in that folder |
| Log | `~/Library/Logs/UXTapFix.log` |

`status.json` is rewritten every two seconds with version, PID, permissions, event-tap state, and the last quit. Setup reads that file.

Uninstall lists what it will remove and asks first. `--yes` skips the prompt:

```sh
~/Library/Application\ Support/UXTapFix/uninstall.sh
```

That stops the service and removes the app, Setup, login item, helpers, log, and privacy records.

If a click does nothing, check the log, grant Accessibility, and run `restart.sh`. `CGEventTap failed` means the tap is waiting on Accessibility. `Three-finger middle-click enabled` means the trackpad gesture started; if the log says no device was found, reconnect the trackpad and restart.

## Develop

```sh
./tests/smoke.sh
```

The smoke test checks syntax, type-checks and builds both apps, verifies signatures, and asserts `MultitouchSupport` is weak-linked.

The daemon is `src/UXTapFix.swift` plus a header in `src/MultitouchSupport/`. Setup is SwiftUI in `src/Setup/`. `build.sh` compiles with `swiftc` and ad-hoc signs both apps. There is no Xcode project.

A `CGEventTap` catches middle click (button 2) and swallows it over the Dock. `MultitouchSupport` turns a short three-finger tap, or a click with three fingers down, into that same click. Accessibility resolves the `AXDockItem` under the pointer. One click calls `terminate()`; three calls `forceTerminate()`. If the tap cannot be created, an `NSEvent` monitor is the fallback. UXTapFix posts the click; the app under the pointer decides what it means.
