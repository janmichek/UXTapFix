// DockMiddleQuit v2.2
// Middle-click (button 2) a Dock icon to quit that app.
// Supports CGEventTap (swallows the click) with an NSEvent global monitor fallback.
//
// The Setup app asks this binary to request TCC permissions and reads status.json
// to show live permission / health information.
import Cocoa
import ApplicationServices
import CoreGraphics
import Darwin
import ServiceManagement
setlinebuf(stdout)

let appVersion = "2.2"
let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DockMiddleQuit", isDirectory: true)
let statusFileURL = supportDirectory.appendingPathComponent("status.json")
let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DockMiddleQuit.log")

let startedAt = Date().timeIntervalSince1970
var lastQuitName: String?
var lastQuitAt: TimeInterval?
var statusTimer: Timer?
var reportedStatusWriteFailure = false

// MARK: - Permission helpers

func accessibilityGranted() -> Bool {
    AXIsProcessTrusted()
}

func inputMonitoringGranted() -> Bool {
    CGPreflightListenEventAccess()
}

func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

// MARK: - Status reporting (read by the Setup app)

func writeStatus() {
    var payload: [String: Any] = [
        "version": appVersion,
        "pid": Int(getpid()),
        "accessibility": accessibilityGranted(),
        "inputMonitoring": inputMonitoringGranted(),
        "eventTapActive": eventTap != nil,
        "startedAt": startedAt,
        "updatedAt": Date().timeIntervalSince1970
    ]
    if let lastQuitName { payload["lastQuitApp"] = lastQuitName }
    if let lastQuitAt { payload["lastQuitAt"] = lastQuitAt }

    do {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: statusFileURL, options: .atomic)
        reportedStatusWriteFailure = false
    } catch {
        if !reportedStatusWriteFailure {
            reportedStatusWriteFailure = true
            print("[DockMiddleQuit] Could not write status file: \(error.localizedDescription)")
        }
    }
}

func startStatusHeartbeat() {
    writeStatus()
    statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        writeStatus()
    }
}

// MARK: - CLI modes used by the Setup app
// Keep these before any event-tap setup so another app instance can request a
// permission prompt without becoming a second background service.

if CommandLine.arguments.contains("--version") {
    print(appVersion)
    exit(0)
}

if CommandLine.arguments.contains("--check") {
    printJSON([
        "version": appVersion,
        "accessibility": accessibilityGranted(),
        "inputMonitoring": inputMonitoringGranted()
    ])
    exit(0)
}

if CommandLine.arguments.contains("--request-accessibility") {
    print("[DockMiddleQuit] Requesting Accessibility access…")
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let alreadyGranted = AXIsProcessTrustedWithOptions(options)
    print(alreadyGranted
          ? "[DockMiddleQuit] Accessibility already granted ✓"
          : "[DockMiddleQuit] Waiting for Accessibility approval…")
    // Give the system prompt a moment to remain on screen before this helper exits.
    RunLoop.main.run(until: Date().addingTimeInterval(alreadyGranted ? 0.2 : 4.0))
    exit(alreadyGranted ? 0 : 2)
}

if CommandLine.arguments.contains("--request-input-monitoring") {
    let alreadyGranted = inputMonitoringGranted()
    if !alreadyGranted {
        print("[DockMiddleQuit] Requesting Input Monitoring access…")
        _ = CGRequestListenEventAccess()
    }
    print(inputMonitoringGranted()
          ? "[DockMiddleQuit] Input Monitoring granted ✓"
          : "[DockMiddleQuit] Input Monitoring not granted (optional)")
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    exit(inputMonitoringGranted() ? 0 : 2)
}

// Older builds could be added with "Open at Login" (a Background Task
// Management app login item). The new installer uses a LaunchAgent instead.
// Best-effort cleanup: unregister the main-app login item if it exists. The
// Setup app also checks BTM and tells the user if anything is left behind.
if CommandLine.arguments.contains("--unregister-login-item") {
    do {
        try SMAppService.mainApp.unregister()
        print("[DockMiddleQuit] Removed the legacy main-app login item.")
    } catch {
        print("[DockMiddleQuit] No legacy main-app login item removed: \(error.localizedDescription)")
    }
    exit(0)
}

// MARK: - Accessibility / Dock lookup

func ensureTrusted() -> Bool {
    let trusted = accessibilityGranted()
    if !trusted {
        print("[DockMiddleQuit] ⚠️ Accessibility NOT granted.")
        print("   Open DockMiddleQuit Setup and follow the permission steps, or add")
        print("   \(Bundle.main.bundlePath) in System Settings -> Privacy & Security -> Accessibility.")
    } else {
        print("[DockMiddleQuit] Accessibility trusted ✓")
    }
    return trusted
}

func dockAppName(at point: CGPoint) -> String? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el)
    guard err == .success, let element = el else { return nil }
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
    // Finder relaunches; Trash/Launchpad/Mission Control are not normal apps.
    // Run scripts/enable-finder-quit.sh if you want middle-click to quit Finder.
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
        lastQuitName = name
        lastQuitAt = Date().timeIntervalSince1970
        writeStatus()
        if !app.terminate() {
            print("[DockMiddleQuit] terminate() false, retry forceTerminate in 1.2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if !app.isTerminated { app.forceTerminate() }
            }
        }
        return
    }
    print("[DockMiddleQuit] No NSRunningApp for '\(name)', trying AppleScript")
    lastQuitName = name
    lastQuitAt = Date().timeIntervalSince1970
    writeStatus()
    let src = "tell application \"\(name)\" to quit"
    var err: NSDictionary?
    if let sc = NSAppleScript(source: src) {
        sc.executeAndReturnError(&err)
        if let e = err { print("[DockMiddleQuit] AppleScript error \(e)") }
        else { print("[DockMiddleQuit] AppleScript quit sent to '\(name)'") }
    }
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
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: tapCallback,
        userInfo: nil
    ) else {
        print("[DockMiddleQuit] CGEventTap failed (Input Monitoring not granted). Falling back to NSEvent global monitor.")
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
    // Passive fallback. Works with only Accessibility, but the Dock menu may flash.
    NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { e in
        if e.buttonNumber == 2 {
            let pt = NSEvent.mouseLocation
            handleMiddleClick(at: pt)
        }
    }
    print("[DockMiddleQuit] NSEvent global monitor installed ✓ (passive)")
}

// MARK: - Main

print("[DockMiddleQuit] Starting v\(appVersion)…")
_ = ensureTrusted()

let tapOK = tryInstallEventTap()
installGlobalMonitor()
if !tapOK {
    print("[DockMiddleQuit] Using fallback monitor. Middle-click still works, but the Dock menu may flash briefly.")
} else {
    print("[DockMiddleQuit] Input Monitoring \(inputMonitoringGranted() ? "granted ✓" : "not granted")")
}

startStatusHeartbeat()
print("[DockMiddleQuit] Ready. Middle-click (or 3-finger tap) any Dock icon to quit. PID \(getpid())")
print("[DockMiddleQuit] Log: \(logFileURL.path)")

signal(SIGTERM) { _ in
    print("[DockMiddleQuit] SIGTERM")
    exit(0)
}
signal(SIGINT) { _ in
    print("[DockMiddleQuit] SIGINT")
    exit(0)
}

CFRunLoopRun()
