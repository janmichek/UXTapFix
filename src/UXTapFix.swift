// UXTapFix v2.3
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
    .appendingPathComponent("Library/Application Support/UXTapFix", isDirectory: true)
let statusFileURL = supportDirectory.appendingPathComponent("status.json")
let logFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/UXTapFix.log")

let startedAt = Date().timeIntervalSince1970
var lastQuitName: String?
var lastQuitAt: TimeInterval?
var reportedStatusWriteFailure = false

// MARK: - Trackpad support (three-finger tap/click -> middle click)
//
// This uses the private MultitouchSupport.framework, the same undocumented
// interface used by MiddleClick. It is not App Store compatible and Apple may
// change it in any macOS release. If the framework is unavailable, the rest of
// UXTapFix keeps working and only the trackpad shortcut is lost.
//
// Configure with UserDefaults (domain com.user.uxtapfix):
//   middleClickEmulation        Bool    default true
//   middleClickFingers          Int     default 3
//   middleClickAllowMoreFingers Bool    default false
//   middleClickTapToClick       Bool    default true
//   middleClickMaxTimeDelta     Double  default 300 (milliseconds)
//   middleClickMaxDistanceDelta Double  default 0.05 (normalized units)
//   middleClickMultiAction      Bool    default true
//   middleClickMultiClickWindow Double  default: system double-click interval
//                                       (minimum 500 milliseconds, can be overridden; floor 150)

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
    private var fingersDown = false
    private var wasFingersDown = false
    private var clickStartedAt: TimeInterval = 0
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
            print("[UXTapFix] Three-finger middle-click disabled by preference.")
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
                print("[UXTapFix] No multitouch device found yet; will keep trying.")
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
            print("[UXTapFix] Could not register a multitouch callback; will keep trying.")
            lock.lock()
            devices.removeAll()
            lock.unlock()
            return false
        }

        retryTimer?.invalidate()
        retryTimer = nil
        loggedRegistrationFailure = false
        print("[UXTapFix] Three-finger middle-click enabled ✓ (\(fingerCount) fingers)")
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
            print("[UXTapFix] System woke; reconnecting trackpad.")
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
        guard enabled, fingersDown else { return false }
        fingersDown = false
        wasFingersDown = true
        clickStartedAt = now
        lastPhysicalClickAt = now
        return true
    }

    /// Called when the matching left/right mouse-up arrives.
    func endThreeFingerClick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard wasFingersDown else { return false }
        wasFingersDown = false
        // A missed mouse-up should not rewrite a much later click.
        return now - clickStartedAt <= 5
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
            fingersDown = false
            if now - clickStartedAt > 5 {
                wasFingersDown = false
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
                fingersDown = false
                lock.unlock()
                return
            }
            tapStart = now
            startPosition = average
            currentPosition = average
            gestureIsValid = true
            fingersDown = true
            lock.unlock()
            return
        }

        // Fingers rarely lift on the same frame. Keep the last full position
        // when one finger lifts first and wait for the final zero-finger frame.
        if fingerTotal < fingerCount {
            fingersDown = false
            lock.unlock()
            return
        }

        // Adding an extra finger cancels the gesture (unless explicitly allowed).
        if !allowMoreFingers && fingerTotal > fingerCount {
            tapStart = nil
            gestureIsValid = false
            fingersDown = false
            lock.unlock()
            return
        }

        fingersDown = true
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
            print("[UXTapFix] Could not write status file: \(error.localizedDescription)")
        }
    }
}

func startStatusHeartbeat() {
    writeStatus()
    _ = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
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
    print("[UXTapFix] Requesting Accessibility access…")
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let alreadyGranted = AXIsProcessTrustedWithOptions(options)
    print(alreadyGranted
          ? "[UXTapFix] Accessibility already granted ✓"
          : "[UXTapFix] Waiting for Accessibility approval…")
    // Give the system prompt a moment to remain on screen before this helper exits.
    RunLoop.main.run(until: Date().addingTimeInterval(alreadyGranted ? 0.2 : 4.0))
    exit(alreadyGranted ? 0 : 2)
}

if CommandLine.arguments.contains("--request-input-monitoring") {
    let alreadyGranted = inputMonitoringGranted()
    if !alreadyGranted {
        print("[UXTapFix] Requesting Input Monitoring access…")
        _ = CGRequestListenEventAccess()
    }
    print(inputMonitoringGranted()
          ? "[UXTapFix] Input Monitoring granted ✓"
          : "[UXTapFix] Input Monitoring not granted (optional)")
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
        print("[UXTapFix] Removed the legacy main-app login item.")
    } catch {
        print("[UXTapFix] No legacy main-app login item removed: \(error.localizedDescription)")
    }
    exit(0)
}

// MARK: - Accessibility / Dock lookup

func ensureTrusted() -> Bool {
    let trusted = accessibilityGranted()
    if !trusted {
        print("[UXTapFix] ⚠️ Accessibility NOT granted.")
        print("   Open UXTapFix Setup and follow the permission steps, or add")
        print("   \(Bundle.main.bundlePath) in System Settings -> Privacy & Security -> Accessibility.")
    } else {
        print("[UXTapFix] Accessibility trusted ✓")
    }
    return trusted
}

struct DockItem {
    let name: String
    let url: URL?
}

func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func dockItem(at point: CGPoint) -> DockItem? {
    let sys = AXUIElementCreateSystemWide()
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el)
    guard err == .success, let element = el else { return nil }
    guard axAttribute(element, kAXRoleAttribute) as? String == "AXDockItem" else { return nil }

    // AXURL identifies the bundle the tile points at. It is more reliable than
    // the title: Ableton, for example, shows "Ableton Live 12 Suite" in the Dock
    // while NSRunningApplication.localizedName is just "Live".
    let rawURL = axAttribute(element, "AXURL")
    let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))

    var name = axAttribute(element, kAXTitleAttribute) as? String
    if name?.isEmpty != false { name = axAttribute(element, kAXDescriptionAttribute) as? String }
    if name?.isEmpty != false { name = url?.deletingPathExtension().lastPathComponent }
    guard let name, !name.isEmpty else { return nil }
    return DockItem(name: name, url: url)
}

func normalizedBundlePath(_ url: URL) -> String {
    var path = url.resolvingSymlinksInPath().standardizedFileURL.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
}

func runningApp(named name: String, url: URL?) -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications

    // Prefer the Dock tile's bundle over any name comparison. Bundle ID first
    // because the app may have been moved since the Dock tile was created, then
    // the resolved path for bundles without a readable Info.plist.
    if let url {
        if let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty,
           let match = apps.first(where: { $0.bundleIdentifier == bundleID }) {
            return match
        }
        let targetPath = normalizedBundlePath(url)
        if let match = apps.first(where: { app in
            guard let bundleURL = app.bundleURL else { return false }
            return normalizedBundlePath(bundleURL) == targetPath
        }) {
            return match
        }
    }

    if let exact = apps.first(where: { $0.localizedName == name }) { return exact }

    // Last resort: match the bundle or executable filename. Dock titles often
    // carry more words than localizedName ("Ableton Live 12 Suite" vs "Live").
    let target = name.lowercased()
    return apps.first { app in
        var candidates: [String] = []
        if let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent {
            candidates.append(bundleName)
        }
        if let executable = app.executableURL?.lastPathComponent {
            candidates.append(executable)
        }
        if let lastComponent = app.bundleIdentifier?.split(separator: ".").last {
            candidates.append(String(lastComponent))
        }
        return candidates.contains { $0.lowercased() == target }
    }
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

func quitApp(named name: String, url: URL? = nil, mode: QuitMode = .normal) {
    if isBlacklisted(name) {
        print("[UXTapFix] Ignoring blacklisted '\(name)'")
        return
    }
    let apps = NSWorkspace.shared.runningApplications
    if let app = runningApp(named: name, url: url) {
        lastQuitName = name
        lastQuitAt = Date().timeIntervalSince1970
        writeStatus()
        switch mode {
        case .normal:
            print("[UXTapFix] Quitting '\(name)' pid \(app.processIdentifier)")
            if !app.terminate() {
                print("[UXTapFix] terminate() false, retry forceTerminate in 1.2s")
                scheduleForceTerminate([app], after: 1.2)
            }
        case .background:
            let helpers = backgroundHelpers(of: app)
            print("[UXTapFix] Quitting '\(name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            _ = app.terminate()
            for helper in helpers { _ = helper.terminate() }
            scheduleForceTerminate([app] + helpers, after: 1.2)
        case .force:
            let helpers = backgroundHelpers(of: app)
            print("[UXTapFix] Force quitting '\(name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            app.forceTerminate()
            for helper in helpers { helper.forceTerminate() }
        }
        return
    }
    if case .force = mode {
        print("[UXTapFix] No running app for '\(name)' to force quit")
        return
    }
    print("[UXTapFix] No NSRunningApp for '\(name)', trying AppleScript")
    lastQuitName = name
    lastQuitAt = Date().timeIntervalSince1970
    writeStatus()
    let src = "tell application \"\(name)\" to quit"
    var err: NSDictionary?
    if let sc = NSAppleScript(source: src) {
        sc.executeAndReturnError(&err)
        if let e = err { print("[UXTapFix] AppleScript error \(e)") }
        else { print("[UXTapFix] AppleScript quit sent to '\(name)'") }
    }
    if let byBundle = apps.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(name.lowercased()) }) {
        print("[UXTapFix] Fuzzy bundle match \(String(describing: byBundle.bundleIdentifier)) -> terminate")
        _ = byBundle.terminate()
    }
}

// MARK: - Event handling (shared)

// Repeated middle-clicks on one Dock icon escalate: 1 = quit, 2 = quit the
// app and its helpers, 3 = force quit. Clicks are counted while each follows
// the previous one within the double-click window, so a single click keeps its
// usual meaning.
let multiClickEnabled: Bool = UserDefaults.standard.object(forKey: "middleClickMultiAction") == nil
    ? true
    : UserDefaults.standard.bool(forKey: "middleClickMultiAction")
// Match the system's double-click speed so deliberate triple-clicks with a
// real mouse count too. Three-finger taps are faster, but physical
// middle-clicks commonly land 300–500 ms apart, and the old fixed 300 ms
// window let the first click quit the app before the second arrived.
let multiClickWindow: TimeInterval = {
    if UserDefaults.standard.object(forKey: "middleClickMultiClickWindow") != nil {
        return max(0.15, UserDefaults.standard.double(forKey: "middleClickMultiClickWindow") / 1000)
    }
    return max(0.5, NSEvent.doubleClickInterval)
}()

var pendingDockClickCount = 0
var pendingDockClickName: String?
var pendingDockClickWorkItem: DispatchWorkItem?

func registerDockMiddleClick(appName: String, url: URL?) {
    guard multiClickEnabled else {
        quitApp(named: appName, url: url)
        return
    }
    if pendingDockClickName != appName {
        pendingDockClickName = appName
        pendingDockClickCount = 0
    }
    pendingDockClickCount = min(pendingDockClickCount + 1, 3)
    let count = pendingDockClickCount
    print("[UXTapFix] Dock middle-click \(count) on '\(appName)'")

    pendingDockClickWorkItem?.cancel()
    pendingDockClickWorkItem = nil

    // There is nothing beyond force quit, so act immediately on the third
    // click. Waiting for the window to elapse would let continued clicking
    // postpone the force quit indefinitely.
    if count >= 3 {
        pendingDockClickName = nil
        pendingDockClickCount = 0
        quitApp(named: appName, url: url, mode: .force)
        return
    }

    let work = DispatchWorkItem {
        pendingDockClickWorkItem = nil
        pendingDockClickName = nil
        pendingDockClickCount = 0
        quitApp(named: appName, url: url, mode: count == 1 ? .normal : .background)
    }
    pendingDockClickWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + multiClickWindow, execute: work)
}

// MARK: - CGEventTap (can swallow)

var eventTap: CFMachPort?
let middleButton: Int64 = 2
// True while a middle-button down over the Dock was swallowed; its matching up
// must be swallowed too so the Dock does not see a half-click.
var swallowedDockMiddleDown = false

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
            if let item = dockItem(at: loc) {
                swallowedDockMiddleDown = true
                DispatchQueue.main.async { registerDockMiddleClick(appName: item.name, url: item.url) }
                return nil // swallow
            }
            swallowedDockMiddleDown = false
        }
    } else if event.type == .otherMouseUp {
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == middleButton && swallowedDockMiddleDown {
            swallowedDockMiddleDown = false
            return nil // swallow the up that belongs to the swallowed down
        }
    }
    return Unmanaged.passUnretained(event)
}

func tryInstallEventTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.otherMouseUp.rawValue)
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
        print("[UXTapFix] CGEventTap failed (Input Monitoring not granted). Falling back to NSEvent global monitor.")
        return false
    }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[UXTapFix] CGEventTap installed ✓ (will swallow middle-click on Dock)")
    return true
}

func installGlobalMonitor() {
    // Passive fallback. Works with only Accessibility, but the Dock menu may flash.
    NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { e in
        guard e.buttonNumber == 2 else { return }
        // Use the event's CG location (top-left origin), not NSEvent.mouseLocation
        // (bottom-left), so the AX hit test looks at the actual Dock item.
        let pt = e.cgEvent?.location ?? CGEvent(source: nil)?.location
        guard let pt, let item = dockItem(at: pt) else { return }
        DispatchQueue.main.async { registerDockMiddleClick(appName: item.name, url: item.url) }
    }
    print("[UXTapFix] NSEvent global monitor installed ✓ (passive)")
}

// MARK: - Main

print("[UXTapFix] Starting v\(appVersion)…")
_ = ensureTrusted()

let tapOK = tryInstallEventTap()
if !tapOK {
    // Only one handler may register a click: running the passive monitor next
    // to a working event tap can count the same physical click twice.
    installGlobalMonitor()
    print("[UXTapFix] Using fallback monitor. Middle-click still works, but the Dock menu may flash briefly.")
} else {
    print("[UXTapFix] Input Monitoring \(inputMonitoringGranted() ? "granted ✓" : "not granted")")
}

let middleClickOK = MiddleClickEmulator.shared.start()
if MiddleClickEmulator.shared.enabled {
    if middleClickOK {
        print("[UXTapFix] Three-finger tap/click sends a middle click. Middle-click a browser tab to close it.")
    } else {
        print("[UXTapFix] Trackpad support unavailable; middle-click still works with a mouse or another gesture app.")
    }
}

if !NSRunningApplication.runningApplications(withBundleIdentifier: "art.ginzburg.MiddleClick").isEmpty {
    print("[UXTapFix] ⚠️ MiddleClick is also running. Quit it to avoid two middle clicks per three-finger gesture.")
}

startStatusHeartbeat()
print("[UXTapFix] Ready. Three-finger tap/click a Dock icon to quit; middle-click a browser tab to close it. PID \(getpid())")
print("[UXTapFix] Log: \(logFileURL.path)")

signal(SIGTERM) { _ in
    print("[UXTapFix] SIGTERM")
    exit(0)
}
signal(SIGINT) { _ in
    print("[UXTapFix] SIGINT")
    exit(0)
}

CFRunLoopRun()
