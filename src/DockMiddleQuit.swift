// DockMiddleQuit v2 - supports both CGEventTap (swallow) and NSEvent global monitor (fallback)
// No Input Monitoring required if using NSEvent path (just Accessibility)
// middle-click (button 2) == 3-finger tap if MiddleClick.app maps it
import Cocoa
import ApplicationServices
import Darwin
setlinebuf(stdout)

func ensureTrusted() -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    if !trusted {
        print("[DockMiddleQuit] ⚠️ Accessibility NOT granted. Please add this app/binary to:")
        print("   System Settings -> Privacy & Security -> Accessibility -> + -> select DockMiddleQuit")
        print("   Then restart daemon.")
    } else {
        print("[DockMiddleQuit] Accessibility trusted ✓")
    }
    return trusted
}

func dockAppName(at point: CGPoint) -> String? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el)
    guard err == .success, let element = el else {
        // print("AX err \(err)")
        return nil
    }
    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    guard let r = role as? String, r == "AXDockItem" else { return nil }
    var title: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    if let t = title as? String, !t.isEmpty { return t }
    var desc: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
    return desc as? String
}

func isBlacklisted(_ name: String) -> Bool {
    let lower = name.lowercased()
    // Finder relaunches, Trash/Launchpad not apps. Keep Finder in list to avoid accidental quit.
    // Remove "finder" from set if you DO want middle-click to quit Finder.
    return ["trash", "launchpad", "mission control", "finder"].contains(lower)
}

func quitApp(named name: String) {
    if isBlacklisted(name) {
        print("[DockMiddleQuit] Ignoring blacklisted '\(name)'")
        return
    }
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: { $0.localizedName == name }) {
        print("[DockMiddleQuit] Quitting '\(name)' pid \(app.processIdentifier)")
        if !app.terminate() {
            print("[DockMiddleQuit] terminate() false, retry forceTerminate in 1.2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if !app.isTerminated { app.forceTerminate() }
            }
        }
        return
    }
    print("[DockMiddleQuit] No NSRunningApp for '\(name)', trying AppleScript")
    let src = "tell application \"\(name)\" to quit"
    var err: NSDictionary?
    if let sc = NSAppleScript(source: src) {
        sc.executeAndReturnError(&err)
        if let e = err { print("[DockMiddleQuit] AppleScript error \(e)") }
        else { print("[DockMiddleQuit] AppleScript quit sent to '\(name)'") }
    }
    // also try bundle identifier fuzzy
    if let byBundle = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(name.lowercased()) }) {
        print("[DockMiddleQuit] Fuzzy bundle match \(String(describing: byBundle.bundleIdentifier)) -> terminate")
        _ = byBundle.terminate()
    }
}

// MARK: - Event handling (shared)
func handleMiddleClick(at point: CGPoint) {
    if let name = dockAppName(at: point) {
        print("[DockMiddleQuit] middle-click on '\(name)' at \(point) -> quit")
        quitApp(named: name)
    } else {
        // Not on dock - ignore silently (verbose for debug)
        // print("[DockMiddleQuit] middle-click at \(point) not on dock")
    }
}

// MARK: - CGEventTap (can swallow)
var eventTap: CFMachPort?
let middleButton: Int64 = 2
func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passRetained(event)
    }
    if type == .otherMouseDown {
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == middleButton {
            let loc = event.location
            // check dock synchronously (must be quick)
            if dockAppName(at: loc) != nil {
                DispatchQueue.main.async { handleMiddleClick(at: loc) }
                return nil // swallow
            }
        }
    }
    return Unmanaged.passRetained(event)
}

func tryInstallEventTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        | (1 << CGEventType.tapDisabledByUserInput.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else {
        print("[DockMiddleQuit] CGEventTap failed (need Input Monitoring). Falling back to NSEvent global monitor.")
        return false
    }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[DockMiddleQuit] CGEventTap installed ✓ (will swallow middle-click on Dock)")
    return true
}

func installGlobalMonitor() {
    // NSEvent global monitor - passive, does not swallow, but needs only Accessibility (often already granted)
    // This still works for middle clicks generated by MiddleClick.app (3-finger tap)
    NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { e in
        if e.buttonNumber == 2 {
            let pt = NSEvent.mouseLocation
            handleMiddleClick(at: pt)
        }
    }
    print("[DockMiddleQuit] NSEvent global monitor installed ✓ (passive)")
}

// MARK: - Main
print("[DockMiddleQuit] Starting v2...")
_ = ensureTrusted()

let tapOK = tryInstallEventTap()
if !tapOK {
    installGlobalMonitor()
    print("[DockMiddleQuit] Using fallback monitor. Middle-click will quit but Dock may flash menu briefly.")
} else {
    // also install global as backup in case tap gets disabled
    installGlobalMonitor()
}

print("[DockMiddleQuit] Ready. Middle-click (or 3-finger tap) any Dock icon to quit. PID \(getpid())")
print("[DockMiddleQuit] Log: /tmp/dock-middle-quit.log  (tail -f to debug)")

signal(SIGTERM) { _ in print("[DockMiddleQuit] SIGTERM"); exit(0) }
signal(SIGINT) { _ in print("[DockMiddleQuit] SIGINT"); exit(0) }

CFRunLoopRun()
