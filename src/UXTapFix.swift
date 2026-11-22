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
    // Accessibility already grants listen (and post) access. macOS can keep
    // CGPreflightListenEventAccess() false for the lifetime of a process if
    // Accessibility was granted after launch, even though event taps work.
    // Treat Accessibility as the source of truth so Setup never sends the
    // user to an Input Monitoring pane that cannot list an ad-hoc build.
    CGPreflightListenEventAccess() || accessibilityGranted()
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
    var tick = 0
    _ = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        // Permissions granted while this process is running are cached by
        // TCC. Retry the tap every few seconds; once it is installed there is
        // no more work to do.
        tick += 1
        if tick % 3 == 0 {
            retryEventTapIfNeeded()
        }
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
    case normal  // graceful quit, then clear any background activity
    case force   // immediate force quit
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

/// Every process below `pid` in the process tree, captured before the app
/// exits. Helpers are usually `NSRunningApplication` instances, but terminal
/// jobs and language servers are plain child processes.
func descendantProcessIDs(of pid: pid_t) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size: size_t = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

    let capacity = size / MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
    let count = size / MemoryLayout<kinfo_proc>.stride

    var childrenByParent: [pid_t: [pid_t]] = [:]
    for index in 0..<count {
        let process = processes[index]
        let parent = process.kp_eproc.e_ppid
        let child = process.kp_proc.p_pid
        guard parent > 0, child > 0 else { continue }
        childrenByParent[parent, default: []].append(child)
    }

    var result: [pid_t] = []
    var queue = childrenByParent[pid] ?? []
    while let child = queue.popLast() {
        result.append(child)
        queue.append(contentsOf: childrenByParent[child] ?? [])
    }
    return result
}

func forceTerminate(processIDs: [pid_t]) {
    let ownPID = getpid()
    for processID in processIDs where processID > 0 && processID != ownPID {
        kill(processID, SIGKILL)
    }
}

// MARK: - Dock "Running in Background" state
//
// macOS 26 and later can keep an app's Dock tile after its processes are gone,
// labelled "Running in Background". Killing the process does not clear that
// state; the Dock's own "Stop Running in Background" command does. Drive that
// command through Accessibility so a quit really makes the icon disappear.

func dockApplicationElement() -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        return nil
    }
    return AXUIElementCreateApplication(dock.processIdentifier)
}

func findDockItem(in element: AXUIElement, name: String, url: URL?, matchURL: Bool) -> AXUIElement? {
    if axAttribute(element, kAXRoleAttribute) as? String == "AXDockItem" {
        if matchURL, let url {
            let rawURL = axAttribute(element, "AXURL")
            let itemURL = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
            if let itemURL, normalizedBundlePath(itemURL) == normalizedBundlePath(url) {
                return element
            }
        } else if axAttribute(element, kAXTitleAttribute) as? String == name {
            return element
        }
    }
    guard let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let match = findDockItem(in: child, name: name, url: url, matchURL: matchURL) {
            return match
        }
    }
    return nil
}

func dockItemElement(named name: String, url: URL?) -> AXUIElement? {
    guard let dock = dockApplicationElement() else { return nil }
    // The bundle path is stable even when the Dock title differs from the app
    // name; fall back to the visible title when the URL is unavailable.
    if url != nil, let match = findDockItem(in: dock, name: name, url: url, matchURL: true) {
        return match
    }
    return findDockItem(in: dock, name: name, url: url, matchURL: false)
}

/// The Dock reports 1 while any part of the app is still alive, including a
/// helper that keeps the tile labelled "Running in Background". A pinned app
/// that is fully quit reports 0.
func dockItemIsRunning(_ item: AXUIElement) -> Bool {
    guard let number = axAttribute(item, "AXIsApplicationRunning") as? NSNumber else { return true }
    return number.boolValue
}

func localizedDockMenuTitle(_ key: String, fallback: String) -> String {
    let dock = Bundle(path: "/System/Library/CoreServices/Dock.app")
    let title = dock?.localizedString(forKey: key, value: nil, table: "DockMenus") ?? key
    return title == key ? fallback : title
}

func findMenuItem(in element: AXUIElement, titled title: String) -> AXUIElement? {
    if axAttribute(element, kAXRoleAttribute) as? String == "AXMenuItem",
       axAttribute(element, kAXTitleAttribute) as? String == title {
        return element
    }
    guard let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let match = findMenuItem(in: child, titled: title) { return match }
    }
    return nil
}

var backgroundStopInProgress = false

func stopRunningInBackground(named name: String, url: URL?, attempts: Int = 3) {
    guard !backgroundStopInProgress else { return }
    backgroundStopInProgress = true
    attemptStopRunningInBackground(named: name, url: url, attempt: 0, attempts: attempts) {
        backgroundStopInProgress = false
    }
}

func attemptStopRunningInBackground(named name: String, url: URL?, attempt: Int, attempts: Int, completion: @escaping () -> Void) {
    // The Dock needs a moment to register the background activity after the
    // processes exit, so retry a few times before giving up.
    guard attempt < attempts else {
        print("[UXTapFix] Dock has no background activity to stop for '\(name)'.")
        completion()
        return
    }

    guard let item = dockItemElement(named: name, url: url) else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            attemptStopRunningInBackground(named: name, url: url, attempt: attempt + 1, attempts: attempts, completion: completion)
        }
        return
    }

    // Do not flash a normal app's context menu: it has no background command.
    guard dockItemIsRunning(item) else {
        completion()
        return
    }

    func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            attemptStopRunningInBackground(named: name, url: url, attempt: attempt + 1, attempts: attempts, completion: completion)
        }
    }

    guard AXUIElementPerformAction(item, kAXShowMenuAction as CFString) == .success else {
        retry()
        return
    }

    waitForDockMenu(of: item, named: name, url: url, attempt: attempt, attempts: attempts, pollsLeft: 20, completion: completion)
}

func waitForDockMenu(of item: AXUIElement, named name: String, url: URL?, attempt: Int, attempts: Int, pollsLeft: Int, completion: @escaping () -> Void) {
    guard pollsLeft > 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            attemptStopRunningInBackground(named: name, url: url, attempt: attempt + 1, attempts: attempts, completion: completion)
        }
        return
    }

    if let shownAttribute = axAttribute(item, "AXShownMenuUIElement") {
        let shown = shownAttribute as! AXUIElement
        let title = localizedDockMenuTitle("STOP_RUNNING_IN_BACKGROUND", fallback: "Stop Running in Background")
        if let menuItem = findMenuItem(in: shown, titled: title) {
            let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
            if result == .success {
                print("[UXTapFix] Stopped '\(name)' running in the background.")
            } else {
                print("[UXTapFix] Could not stop '\(name)' in the background (AX error \(result.rawValue)).")
            }
            completion()
        } else {
            _ = AXUIElementPerformAction(shown, kAXCancelAction as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                attemptStopRunningInBackground(named: name, url: url, attempt: attempt + 1, attempts: attempts, completion: completion)
            }
        }
        return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        waitForDockMenu(of: item, named: name, url: url, attempt: attempt, attempts: attempts, pollsLeft: pollsLeft - 1, completion: completion)
    }
}

/// Waits for the quit to finish, then clears the Dock's background state. The
/// Dock tile is what the user sees, so it must go even when every process is
/// already gone. A pinned app that is fully closed reports `isRunning == 0`,
/// so its ordinary tile is left alone.
func clearBackgroundActivity(after apps: [NSRunningApplication], named name: String, url: URL?) {
    let deadline = Date().addingTimeInterval(2.5)
    func poll() {
        let stillRunning = runningApp(named: name, url: url)
        if stillRunning == nil && apps.allSatisfy({ $0.isTerminated }) {
            stopRunningInBackground(named: name, url: url)
        } else if Date() >= deadline {
            print("[UXTapFix] '\(name)' is still running; not touching its Dock tile.")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
}

/// Normal quits are never escalated. The app gets as long as it needs to show
/// a save sheet or finish its own shutdown. Once every process has exited we
/// clear a lingering "Running in Background" Dock tile. Force quit is only used
/// when the user explicitly asks for it with a triple-click.
func finishQuit(
    app: NSRunningApplication,
    helpers: [NSRunningApplication],
    descendants: [pid_t],
    named name: String,
    url: URL?,
    force: Bool
) {
    if force {
        if !app.isTerminated { app.forceTerminate() }
        for helper in helpers where !helper.isTerminated {
            helper.forceTerminate()
        }
        forceTerminate(processIDs: descendants)
        clearBackgroundActivity(after: [app] + helpers, named: name, url: url)
        return
    }

    func waitForExit() {
        let allTerminated = app.isTerminated && helpers.allSatisfy { $0.isTerminated }
        if allTerminated {
            clearBackgroundActivity(after: [app] + helpers, named: name, url: url)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: waitForExit)
        }
    }
    waitForExit()
}

func quitApp(named name: String, url: URL? = nil, mode: QuitMode = .normal) {
    if isBlacklisted(name) {
        print("[UXTapFix] Ignoring blacklisted '\(name)'")
        return
    }
    if let app = runningApp(named: name, url: url) {
        lastQuitName = name
        lastQuitAt = Date().timeIntervalSince1970
        writeStatus()

        let helpers = backgroundHelpers(of: app)
        let descendants = descendantProcessIDs(of: app.processIdentifier)

        switch mode {
        case .normal:
            print("[UXTapFix] Quitting '\(name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            _ = app.terminate()
            for helper in helpers { _ = helper.terminate() }
            finishQuit(app: app, helpers: helpers, descendants: descendants, named: name, url: url, force: false)
        case .force:
            print("[UXTapFix] Force quitting '\(name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            app.forceTerminate()
            for helper in helpers { helper.forceTerminate() }
            finishQuit(app: app, helpers: helpers, descendants: descendants, named: name, url: url, force: true)
        }
        return
    }

    print("[UXTapFix] No running app for '\(name)'")
    // The app may already be gone while macOS still shows its tile as "Running
    // in Background". A click on that tile should clear exactly that state.
    clearBackgroundActivity(after: [], named: name, url: url)
}

// MARK: - Event handling (shared)

// One middle-click quits; three force-quit. A second click is only part of
// the sequence and performs the same normal quit. Clicks are counted while
// each follows the previous one within the double-click window.
let multiClickEnabled: Bool = UserDefaults.standard.object(forKey: "middleClickMultiAction") == nil
    ? true
    : UserDefaults.standard.bool(forKey: "middleClickMultiAction")
// Match the system's double-click speed so deliberate triple-clicks with a
// real mouse count too. Three-finger taps are faster, but physical
// middle-clicks commonly land 300–500 ms apart, and a fixed 300 ms window
// would fire the normal quit before the third click arrived.
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

    // One click and two clicks both mean "quit normally". The wait only exists
    // so a third click can still arrive and turn it into a force quit.
    let work = DispatchWorkItem {
        pendingDockClickWorkItem = nil
        pendingDockClickName = nil
        pendingDockClickCount = 0
        quitApp(named: appName, url: url, mode: .normal)
    }
    pendingDockClickWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + multiClickWindow, execute: work)
}

// MARK: - CGEventTap (can swallow)

var eventTap: CFMachPort?
var globalMonitor: Any?
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

func tryInstallEventTap(logFailure: Bool = true) -> Bool {
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
        if logFailure {
            print("[UXTapFix] CGEventTap failed (Accessibility not granted). Falling back to NSEvent global monitor.")
        }
        return false
    }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[UXTapFix] CGEventTap installed ✓ (will swallow middle-click on Dock)")
    return true
}

/// A permission can land after launch (the usual case during Setup). TCC
/// caches the old answer in this process, so retry the tap instead of making
/// the user restart the background service.
func retryEventTapIfNeeded() {
    guard eventTap == nil, accessibilityGranted() else { return }
    if tryInstallEventTap(logFailure: false) {
        removeGlobalMonitor()
        print("[UXTapFix] Accessibility became available; event tap is active without a restart.")
    }
}


func installGlobalMonitor() {
    guard globalMonitor == nil else { return }
    // Passive fallback. Works with only Accessibility, but the Dock menu may flash.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { e in
        guard e.buttonNumber == 2 else { return }
        // Use the event's CG location (top-left origin), not NSEvent.mouseLocation
        // (bottom-left), so the AX hit test looks at the actual Dock item.
        let pt = e.cgEvent?.location ?? CGEvent(source: nil)?.location
        guard let pt, let item = dockItem(at: pt) else { return }
        DispatchQueue.main.async { registerDockMiddleClick(appName: item.name, url: item.url) }
    }
    print("[UXTapFix] NSEvent global monitor installed ✓ (passive)")
}

func removeGlobalMonitor() {
    guard let monitor = globalMonitor else { return }
    NSEvent.removeMonitor(monitor)
    globalMonitor = nil
    print("[UXTapFix] Passive monitor removed; the event tap handles clicks now.")
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
