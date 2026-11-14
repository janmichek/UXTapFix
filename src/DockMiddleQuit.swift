// DockMiddleQuit v2.3
// Middle-click (button 2) a Dock icon to quit that app.
// Also turns a three-finger trackpad tap/click into a middle click, so the
// same gesture closes a browser tab outside the Dock.
// Supports CGEventTap (swallows the click) with an NSEvent global monitor fallback.
//
// The Setup app asks this binary to request TCC permissions and reads status.json
// to show live permission / health information.
import Cocoa
import ApplicationServices
import CoreGraphics
import Darwin
import MultitouchSupport
import ServiceManagement
setlinebuf(stdout)

let appVersion = "2.3"
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

// MARK: - Trackpad support (three-finger tap/click -> middle click)
//
// This uses the private MultitouchSupport.framework, the same undocumented
// interface used by MiddleClick. It is not App Store compatible and Apple may
// change it in any macOS release. If the framework is unavailable, the rest of
// DockMiddleQuit keeps working and only the trackpad shortcut is lost.
//
// Configure with UserDefaults (domain com.user.dockmiddlequit):
//   middleClickEmulation        Bool    default true
//   middleClickFingers          Int     default 3
//   middleClickAllowMoreFingers Bool    default false
//   middleClickTapToClick       Bool    default true
//   middleClickMaxTimeDelta     Double  default 300 (milliseconds)
//   middleClickMaxDistanceDelta Double  default 0.05 (normalized units)

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> Unmanaged<CFMutableArray>?

private let touchCallback: MTFrameCallbackFunction = { _, touches, count, _, _ in
    MiddleClickEmulator.shared.handleFrame(touches, count: count)
}

final class MiddleClickEmulator {
    static let shared = MiddleClickEmulator()

    // MARK: Configuration

    let enabled: Bool
    let fingerCount: Int
    let allowMoreFingers: Bool
    let tapToClick: Bool
    let maxTimeDelta: TimeInterval
    let maxDistanceDelta: Float

    // MARK: Shared state (read by the event tap on another thread)

    private let lock = NSLock()
    private var threeFingersDown = false
    private var wasThreeFingersDown = false
    private var threeFingerClickStartedAt: TimeInterval = 0
    // Set when a physical click is rewritten, so the tap does not also post.
    private var lastPhysicalClickAt: TimeInterval = 0

    // MARK: Touch state

    private var devices: [MTDevice] = []
    private var tapStart: TimeInterval?
    private var startPosition = SIMD2<Float>(0, 0)
    private var currentPosition = SIMD2<Float>(0, 0)
    private var gestureIsValid = false
    private var lastEmulatedAt: TimeInterval = 0
    private var retryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var loggedRegistrationFailure = false

    private init() {
        let defaults = UserDefaults.standard

        func boolValue(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
        }
        func doubleValue(_ key: String, default value: Double) -> Double {
            defaults.object(forKey: key) == nil ? value : defaults.double(forKey: key)
        }

        enabled = boolValue("middleClickEmulation", default: true)
        fingerCount = max(1, defaults.object(forKey: "middleClickFingers") == nil
                          ? 3
                          : defaults.integer(forKey: "middleClickFingers"))
        allowMoreFingers = boolValue("middleClickAllowMoreFingers", default: false)
        tapToClick = boolValue("middleClickTapToClick", default: true)
        maxTimeDelta = max(0.05, doubleValue("middleClickMaxTimeDelta", default: 300) / 1000)
        maxDistanceDelta = Float(max(0.001, doubleValue("middleClickMaxDistanceDelta", default: 0.05)))
    }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard enabled else {
            print("[DockMiddleQuit] Three-finger middle-click disabled by preference.")
            return false
        }

        lock.lock()
        let alreadyRunning = !devices.isEmpty
        lock.unlock()
        if alreadyRunning { return true }

        observeWake()
        if registerDevices() {
            return true
        }
        scheduleRetry()
        return false
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil

        lock.lock()
        let list = devices
        devices.removeAll()
        lock.unlock()

        for device in list {
            _ = device.unregister(contactFrameCallback: touchCallback)
            device.stop()
        }
    }

    func restart() {
        stop()
        _ = start()
    }

    private func registerDevices() -> Bool {
        let list = MTDeviceCreateList()?.takeUnretainedValue() as? [MTDevice] ?? []
        guard !list.isEmpty else {
            if !loggedRegistrationFailure {
                loggedRegistrationFailure = true
                print("[DockMiddleQuit] No multitouch device found yet; will keep trying.")
            }
            return false
        }

        lock.lock()
        devices = list
        lock.unlock()

        var registeredCount = 0
        for device in list {
            if device.register(contactFrameCallback: touchCallback) {
                device.start(runMode: 0)
                registeredCount += 1
            }
        }

        guard registeredCount > 0 else {
            print("[DockMiddleQuit] Could not register a multitouch callback; will keep trying.")
            lock.lock()
            devices.removeAll()
            lock.unlock()
            return false
        }

        retryTimer?.invalidate()
        retryTimer = nil
        loggedRegistrationFailure = false
        print("[DockMiddleQuit] Three-finger middle-click enabled ✓ (\(fingerCount) fingers)")
        return true
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.registerDevices() {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[DockMiddleQuit] System woke; reconnecting trackpad.")
            self?.restart()
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !devices.isEmpty
    }

    // MARK: Event-tap helpers

    /// Called when a left/right mouse-down arrives while three fingers are down.
    /// Returns true when the event should be rewritten to a middle click.
    func beginThreeFingerClick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard enabled, threeFingersDown else { return false }
        threeFingersDown = false
        wasThreeFingersDown = true
        threeFingerClickStartedAt = now
        lastPhysicalClickAt = now
        return true
    }

    /// Called when the matching left/right mouse-up arrives.
    func endThreeFingerClick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard wasThreeFingersDown else { return false }
        wasThreeFingersDown = false
        // A missed mouse-up should not rewrite a much later click.
        return now - threeFingerClickStartedAt <= 5
    }

    // MARK: Touch handling

    func handleFrame(_ touches: UnsafeMutablePointer<MTTouch>?, count: Int32) {
        guard enabled else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let fingerTotal = Int(count)

        lock.lock()

        // All fingers lifted: decide whether this was a valid tap.
        if fingerTotal == 0 {
            let duration = tapStart.map { now - $0 } ?? .infinity
            let distance = manhattan(startPosition, currentPosition)
            let naturalClickGuard = maxTimeDelta * 0.75
            let recentlyClicked = now - lastPhysicalClickAt <= naturalClickGuard
            let canPost = tapToClick
                && gestureIsValid
                && duration <= maxTimeDelta
                && distance <= maxDistanceDelta
                && !recentlyClicked
                && now - lastEmulatedAt > maxTimeDelta * 0.3

            tapStart = nil
            gestureIsValid = false
            threeFingersDown = false
            if now - threeFingerClickStartedAt > 5 {
                wasThreeFingersDown = false
            }
            if canPost { lastEmulatedAt = now }
            lock.unlock()

            if canPost {
                postMiddleClick()
            }
            return
        }

        // Not tracking yet. Start only when the configured number of fingers
        // is actually down; frames with one or two fingers are just the start
        // of the gesture.
        if tapStart == nil {
            let canStart = fingerTotal == fingerCount
                || (allowMoreFingers && fingerTotal > fingerCount)
            guard canStart, let average = averagePosition(touches, count: fingerTotal) else {
                threeFingersDown = false
                lock.unlock()
                return
            }
            tapStart = now
            startPosition = average
            currentPosition = average
            gestureIsValid = true
            threeFingersDown = true
            lock.unlock()
            return
        }

        // Fingers rarely lift on the same frame. Keep the last full position
        // when one finger lifts first and wait for the final zero-finger frame.
        if fingerTotal < fingerCount {
            threeFingersDown = false
            lock.unlock()
            return
        }

        // Adding an extra finger cancels the gesture (unless explicitly allowed).
        if !allowMoreFingers && fingerTotal > fingerCount {
            tapStart = nil
            gestureIsValid = false
            threeFingersDown = false
            lock.unlock()
            return
        }

        threeFingersDown = true
        if let average = averagePosition(touches, count: fingerTotal) {
            currentPosition = average
        }
        if now - (tapStart ?? now) > maxTimeDelta {
            gestureIsValid = false
        }

        lock.unlock()
    }

    private func averagePosition(_ touches: UnsafeMutablePointer<MTTouch>?, count: Int) -> SIMD2<Float>? {
        guard let touches, count > 0 else { return nil }
        let samples = min(fingerCount, count)
        var sumX: Float = 0
        var sumY: Float = 0
        for index in 0..<samples {
            let position = touches[index].normalizedVector.position
            sumX += position.x
            sumY += position.y
        }
        return SIMD2<Float>(sumX / Float(samples), sumY / Float(samples))
    }

    private func postMiddleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: location,
            mouseButton: .center
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseUp,
            mouseCursorPosition: location,
            mouseButton: .center
        )?.post(tap: .cghidEventTap)
    }

    private func manhattan(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        abs(a.x - b.x) + abs(a.y - b.y)
    }
}

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
        "middleClickEmulation": MiddleClickEmulator.shared.isRunning,
        "middleClickEnabled": MiddleClickEmulator.shared.enabled,
        "middleClickFingers": MiddleClickEmulator.shared.fingerCount,
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

enum QuitMode {
    case normal      // graceful quit, the v2.3 behavior
    case background  // quit the app and its helpers, force leftovers after a grace period
    case force       // immediate force quit
}

func backgroundHelpers(of app: NSRunningApplication) -> [NSRunningApplication] {
    // Chrome-, Slack- and VS Code-style helpers share the app's bundle ID with
    // a dot suffix; an exact match or "<bundleID>." prefix keeps siblings such
    // as com.apple.SafariServices out of a com.apple.Safari quit.
    guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return [] }
    let prefix = bundleID + "."
    return NSWorkspace.shared.runningApplications.filter { other in
        guard other.processIdentifier != app.processIdentifier,
              let otherID = other.bundleIdentifier,
              !otherID.isEmpty else { return false }
        return otherID == bundleID || otherID.hasPrefix(prefix)
    }
}

func scheduleForceTerminate(_ apps: [NSRunningApplication], after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        for app in apps where !app.isTerminated {
            app.forceTerminate()
        }
    }
}

func quitApp(named name: String, mode: QuitMode = .normal) {
    if isBlacklisted(name) {
        print("[DockMiddleQuit] Ignoring blacklisted '\(name)'")
        return
    }
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: { $0.localizedName == name }) {
        lastQuitName = name
        lastQuitAt = Date().timeIntervalSince1970
        writeStatus()
        switch mode {
        case .normal:
            print("[DockMiddleQuit] Quitting '\(name)' pid \(app.processIdentifier)")
            if !app.terminate() {
                print("[DockMiddleQuit] terminate() false, retry forceTerminate in 1.2s")
                scheduleForceTerminate([app], after: 1.2)
            }
        case .background:
            let helpers = backgroundHelpers(of: app)
            print("[DockMiddleQuit] Quitting '\(name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            _ = app.terminate()
            for helper in helpers { _ = helper.terminate() }
            scheduleForceTerminate([app] + helpers, after: 1.2)
        case .force:
            let helpers = backgroundHelpers(of: app)
            print("[DockMiddleQuit] Force quitting '\(name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            app.forceTerminate()
            for helper in helpers { helper.forceTerminate() }
        }
        return
    }
    if case .force = mode {
        print("[DockMiddleQuit] No running app for '\(name)' to force quit")
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

// Repeated middle-clicks on one Dock icon escalate: 1 = quit, 2 = quit the
// app and its helpers, 3 = force quit. Clicks are counted in a short window so
// that a single click keeps its usual meaning.
let multiClickEnabled: Bool = UserDefaults.standard.object(forKey: "middleClickMultiAction") == nil
    ? true
    : UserDefaults.standard.bool(forKey: "middleClickMultiAction")
let multiClickWindow: TimeInterval = max(
    0.15,
    (UserDefaults.standard.object(forKey: "middleClickMultiClickWindow") == nil
        ? 300
        : UserDefaults.standard.double(forKey: "middleClickMultiClickWindow")) / 1000
)

var pendingDockClickCount = 0
var pendingDockClickName: String?
var pendingDockClickWorkItem: DispatchWorkItem?

func registerDockMiddleClick(appName: String) {
    guard multiClickEnabled else {
        quitApp(named: appName)
        return
    }
    if pendingDockClickName != appName {
        pendingDockClickName = appName
        pendingDockClickCount = 0
    }
    pendingDockClickCount = min(pendingDockClickCount + 1, 3)
    let count = pendingDockClickCount
    print("[DockMiddleQuit] Dock middle-click \(count) on '\(appName)'")

    pendingDockClickWorkItem?.cancel()
    let work = DispatchWorkItem {
        pendingDockClickWorkItem = nil
        pendingDockClickName = nil
        pendingDockClickCount = 0
        switch count {
        case 1: quitApp(named: appName, mode: .normal)
        case 2: quitApp(named: appName, mode: .background)
        default: quitApp(named: appName, mode: .force)
        }
    }
    pendingDockClickWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + multiClickWindow, execute: work)
}

// MARK: - CGEventTap (can swallow)

var eventTap: CFMachPort?
let middleButton: Int64 = 2

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let emulator = MiddleClickEmulator.shared

    // Three fingers held down + a physical left/right click becomes a middle
    // click. This mirrors MiddleClick and makes three-finger click work in
    // browsers and Terminal, not just the tap-to-click gesture.
    if type == .leftMouseDown || type == .rightMouseDown {
        if emulator.beginThreeFingerClick() {
            event.type = .otherMouseDown
            event.setIntegerValueField(.mouseEventButtonNumber, value: middleButton)
        }
    } else if type == .leftMouseUp || type == .rightMouseUp {
        if emulator.endThreeFingerClick() {
            event.type = .otherMouseUp
            event.setIntegerValueField(.mouseEventButtonNumber, value: middleButton)
        }
    }

    if event.type == .otherMouseDown {
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == middleButton {
            let loc = event.location
            if let name = dockAppName(at: loc) {
                DispatchQueue.main.async { registerDockMiddleClick(appName: name) }
                return nil // swallow
            }
        }
    }
    return Unmanaged.passUnretained(event)
}

func tryInstallEventTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.rightMouseUp.rawValue)
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
            if let name = dockAppName(at: pt) {
                registerDockMiddleClick(appName: name)
            }
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

let middleClickOK = MiddleClickEmulator.shared.start()
if MiddleClickEmulator.shared.enabled {
    if middleClickOK {
        print("[DockMiddleQuit] Three-finger tap/click sends a middle click. Middle-click a browser tab to close it.")
    } else {
        print("[DockMiddleQuit] Trackpad support unavailable; middle-click still works with a mouse or another gesture app.")
    }
}

if !NSRunningApplication.runningApplications(withBundleIdentifier: "art.ginzburg.MiddleClick").isEmpty {
    print("[DockMiddleQuit] ⚠️ MiddleClick is also running. Quit it to avoid two middle clicks per three-finger gesture.")
}

startStatusHeartbeat()
print("[DockMiddleQuit] Ready. Three-finger tap/click a Dock icon to quit; middle-click a browser tab to close it. PID \(getpid())")
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
