// UXTapFix v2.4
// Middle-click (button 2) a Dock icon to quit that app.
// Also turns a three-finger trackpad tap/click into a middle click, so the
// same gesture closes a browser tab outside the Dock, closes the window under
// the pointer in Mission Control and App Exposé, and deletes the Calendar
// event under the pointer.
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

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.4"
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
//   middleClickAllowFinderQuit  Bool    default false
//   middleClickCloseOverview    Bool    default true
//   middleClickRemoveCalendarEvent Bool default true

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> Unmanaged<CFMutableArray>?

/// Load the private framework ourselves. The build weak-links it so a future
/// macOS release that removes it cannot stop the daemon from launching; the
/// trackpad feature simply stays off until the framework is present again.
private let multitouchFrameworkHandle: UnsafeMutableRawPointer? = {
    let paths = [
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport"
    ]
    let requiredSymbols = [
        "MTDeviceCreateList",
        "MTRegisterContactFrameCallback",
        "MTUnregisterContactFrameCallback",
        "MTDeviceStart",
        "MTDeviceStop"
    ]
    for path in paths {
        guard let handle = dlopen(path, RTLD_LAZY) else { continue }
        if requiredSymbols.allSatisfy({ dlsym(handle, $0) != nil }) {
            return handle
        }
        _ = dlclose(handle)
    }
    return nil
}()

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
    /// A physical left/right click is being rewritten to a middle click, and
    /// the matching mouse-up has not arrived yet.
    private var rewritingPhysicalClick = false
    private var clickStartedAt: TimeInterval = 0
    // Set when a physical click is rewritten, so the tap does not also post.
    private var lastPhysicalClickAt: TimeInterval = 0
    /// A physical click happened during this gesture. Even a slow click must not
    /// produce a second emulated click when the fingers finally lift.
    private var physicalClickDuringGesture = false

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
        let configuredFingerCount = defaults.object(forKey: "middleClickFingers") == nil
            ? 3
            : defaults.integer(forKey: "middleClickFingers")
        fingerCount = max(2, configuredFingerCount)
        if configuredFingerCount < 2 {
            print("[UXTapFix] middleClickFingers must be at least 2; using 2.")
        }
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
        guard multitouchFrameworkHandle != nil else {
            print("[UXTapFix] MultitouchSupport.framework unavailable; the trackpad shortcut is disabled.")
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
        fingersDown = false
        rewritingPhysicalClick = false
        physicalClickDuringGesture = false
        tapStart = nil
        gestureIsValid = false
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
        let list = MTDeviceCreateList()?.takeRetainedValue() as? [MTDevice] ?? []
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
        rewritingPhysicalClick = true
        physicalClickDuringGesture = true
        clickStartedAt = now
        lastPhysicalClickAt = now
        return true
    }

    /// Called when the matching left/right mouse-up arrives.
    func endThreeFingerClick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard rewritingPhysicalClick else { return false }
        rewritingPhysicalClick = false
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
            let physicalClick = physicalClickDuringGesture
            let canPost = tapToClick
                && gestureIsValid
                && duration <= maxTimeDelta
                && distance <= maxDistanceDelta
                && !recentlyClicked
                && !physicalClick
                && now - lastEmulatedAt > maxTimeDelta * 0.3

            tapStart = nil
            gestureIsValid = false
            fingersDown = false
            physicalClickDuringGesture = false
            if now - clickStartedAt > 5 {
                rewritingPhysicalClick = false
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
            physicalClickDuringGesture = false
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
            physicalClickDuringGesture = false
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

// MARK: - Status reporting (read by the Setup app)

func writeStatus() {
    var payload: [String: Any] = [
        "version": appVersion,
        "pid": Int(getpid()),
        "accessibility": accessibilityGranted(),
        "inputMonitoring": inputMonitoringGranted(),
        "eventTapActive": eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
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
    refreshOverviewHosts()
    var tick = 0
    _ = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        // Permissions granted while this process is running are cached by
        // TCC. Retry the tap every few seconds; once it is installed there is
        // no more work to do.
        tick += 1
        refreshOverviewHosts()
        if tick % 3 == 0 {
            retryEventTapIfNeeded()
        }
        writeStatus()
    }
}

// MARK: - CLI modes used by the Setup app
// Keep these before any event-tap setup so another app instance can request a
// permission prompt without becoming a second background service.

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

func axURL(_ element: AXUIElement) -> URL? {
    let rawURL = axAttribute(element, "AXURL")
    return (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
}

func dockItem(at point: CGPoint) -> DockItem? {
    let sys = AXUIElementCreateSystemWide()
    // This runs inside the event-tap callback. Bound the synchronous AX IPC so
    // a busy Dock cannot trip the tap watchdog and cost us the click.
    AXUIElementSetMessagingTimeout(sys, 0.1)
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el)
    guard err == .success, let element = el else { return nil }
    AXUIElementSetMessagingTimeout(element, 0.1)
    guard axAttribute(element, kAXRoleAttribute) as? String == "AXDockItem" else { return nil }

    // AXURL identifies the bundle the tile points at. It is more reliable than
    // the title: Ableton, for example, shows "Ableton Live 12 Suite" in the Dock
    // while NSRunningApplication.localizedName is just "Live".
    let url = axURL(element)

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

func runningApp(for item: DockItem) -> NSRunningApplication? {
    let name = item.name
    let url = item.url
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

func isBlacklisted(_ item: DockItem) -> Bool {
    let finderAllowed = UserDefaults.standard.bool(forKey: "middleClickAllowFinderQuit")

    // Prefer the bundle/path. Localized Dock titles ("Papierkorb", "Schreibtisch")
    // made the old title-only check unreliable outside English.
    if let url = item.url {
        let path = normalizedBundlePath(url)
        if path == "/System/Library/CoreServices/Finder.app" {
            return !finderAllowed
        }
        if path.hasSuffix("/.Trash") || path.hasSuffix("/Launchpad.app") || path.hasSuffix("/Mission Control.app") {
            return true
        }
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            switch bundleID {
            case "com.apple.finder":
                return !finderAllowed
            case "com.apple.launchpad.launcher", "com.apple.exposelauncher":
                return true
            default:
                break
            }
        }
    }

    let lower = item.name.lowercased()
    if lower == "finder" {
        return !finderAllowed
    }
    let trashPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash", isDirectory: true)
        .path
    let localizedTrashName = FileManager.default.displayName(atPath: trashPath).lowercased()
    // Finder relaunches; Trash/Launchpad/Mission Control are not normal apps.
    // Run scripts/enable-finder-quit.sh if you want middle-click to quit Finder.
    return ["trash", "launchpad", "mission control"].contains(lower) || lower == localizedTrashName
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

/// `isTerminated` can lag the actual exit. A dead pid is gone; EPERM means the
/// process still exists and belongs to someone else, so it is not treated as exited.
func hasExited(_ app: NSRunningApplication) -> Bool {
    if app.isTerminated { return true }
    let pid = app.processIdentifier
    guard pid > 0 else { return true }
    errno = 0
    if kill(pid, 0) == 0 { return false }
    return errno != EPERM
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
    let element = AXUIElementCreateApplication(dock.processIdentifier)
    // Menu automation runs on the main queue, not in the event-tap callback,
    // so give the Dock enough time to open and populate its menu.
    AXUIElementSetMessagingTimeout(element, 1.0)
    return element
}

func findDockItem(in element: AXUIElement, matching target: DockItem, matchURL: Bool) -> AXUIElement? {
    if axAttribute(element, kAXRoleAttribute) as? String == "AXDockItem" {
        if matchURL, let url = target.url {
            if let itemURL = axURL(element), normalizedBundlePath(itemURL) == normalizedBundlePath(url) {
                return element
            }
        } else if axAttribute(element, kAXTitleAttribute) as? String == target.name {
            return element
        }
    }
    guard let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let match = findDockItem(in: child, matching: target, matchURL: matchURL) {
            return match
        }
    }
    return nil
}

func dockItemElement(for target: DockItem) -> AXUIElement? {
    guard let dock = dockApplicationElement() else { return nil }
    // The bundle path is stable even when the Dock title differs from the app
    // name; fall back to the visible title when the URL is unavailable.
    if target.url != nil, let match = findDockItem(in: dock, matching: target, matchURL: true) {
        return match
    }
    return findDockItem(in: dock, matching: target, matchURL: false)
}

/// The Dock reports 1 while any part of the app is still alive, including a
/// helper that keeps the tile labelled "Running in Background". A pinned app
/// that is fully quit reports 0.
func dockItemIsRunning(_ item: AXUIElement) -> Bool {
    // If the attribute is unavailable, do not risk opening a normal app's
    // menu; treating it as "not running" keeps the ordinary tile untouched.
    guard let number = axAttribute(item, "AXIsApplicationRunning") as? NSNumber else { return false }
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
var backgroundStopCurrent: DockItem?
var backgroundStopQueue: [DockItem] = []

func isSameDockItem(_ lhs: DockItem, _ rhs: DockItem) -> Bool {
    lhs.name == rhs.name && sameDockTarget(lhs.url, rhs.url)
}

func stopRunningInBackground(_ target: DockItem, attempts: Int = 3) {
    let sameAsCurrent = backgroundStopCurrent.map { isSameDockItem($0, target) } ?? false
    let alreadyQueued = backgroundStopQueue.contains { isSameDockItem($0, target) }
    // A second app quit while the Dock menu is open used to be ignored, so
    // its "Running in Background" tile stayed. Queue it and run it next.
    guard !sameAsCurrent, !alreadyQueued else { return }
    backgroundStopQueue.append(target)
    drainBackgroundStopQueue(attempts: attempts)
}

func retryDockStop(_ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
}

func sameDockTarget(_ lhs: URL?, _ rhs: URL?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        return normalizedBundlePath(lhs) == normalizedBundlePath(rhs)
    default:
        return false
    }
}

func drainBackgroundStopQueue(attempts: Int) {
    guard !backgroundStopInProgress, !backgroundStopQueue.isEmpty else { return }
    let next = backgroundStopQueue.removeFirst()
    backgroundStopInProgress = true
    backgroundStopCurrent = next
    attemptStopRunningInBackground(next, attempt: 0, attempts: attempts) {
        backgroundStopInProgress = false
        backgroundStopCurrent = nil
        drainBackgroundStopQueue(attempts: attempts)
    }
}

func attemptStopRunningInBackground(_ target: DockItem, attempt: Int, attempts: Int, completion: @escaping () -> Void) {
    // The Dock needs a moment to register the background activity after the
    // processes exit, so retry a few times before giving up.
    guard attempt < attempts else {
        print("[UXTapFix] Dock has no background activity to stop for '\(target.name)'.")
        completion()
        return
    }

    guard let element = dockItemElement(for: target) else {
        retryDockStop {
            attemptStopRunningInBackground(target, attempt: attempt + 1, attempts: attempts, completion: completion)
        }
        return
    }

    // Do not flash a normal app's context menu: it has no background command.
    guard dockItemIsRunning(element) else {
        completion()
        return
    }

    func retry() {
        retryDockStop {
            attemptStopRunningInBackground(target, attempt: attempt + 1, attempts: attempts, completion: completion)
        }
    }

    guard AXUIElementPerformAction(element, kAXShowMenuAction as CFString) == .success else {
        retry()
        return
    }

    waitForDockMenu(of: element, target: target, attempt: attempt, attempts: attempts, pollsLeft: 20, completion: completion)
}

func waitForDockMenu(of item: AXUIElement, target: DockItem, attempt: Int, attempts: Int, pollsLeft: Int, completion: @escaping () -> Void) {
    guard pollsLeft > 0 else {
        retryDockStop {
            attemptStopRunningInBackground(target, attempt: attempt + 1, attempts: attempts, completion: completion)
        }
        return
    }

    if let shownAttribute = axAttribute(item, "AXShownMenuUIElement") {
        guard CFGetTypeID(shownAttribute) == AXUIElementGetTypeID() else {
            retryDockStop {
                attemptStopRunningInBackground(target, attempt: attempt + 1, attempts: attempts, completion: completion)
            }
            return
        }
        let shown = shownAttribute as! AXUIElement
        AXUIElementSetMessagingTimeout(shown, 1.0)
        let title = localizedDockMenuTitle("STOP_RUNNING_IN_BACKGROUND", fallback: "Stop Running in Background")
        if let menuItem = findMenuItem(in: shown, titled: title) {
            let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
            if result == .success {
                print("[UXTapFix] Stopped '\(target.name)' running in the background.")
            } else {
                print("[UXTapFix] Could not stop '\(target.name)' in the background (AX error \(result.rawValue)).")
            }
            completion()
        } else {
            _ = AXUIElementPerformAction(shown, kAXCancelAction as CFString)
            retryDockStop {
                attemptStopRunningInBackground(target, attempt: attempt + 1, attempts: attempts, completion: completion)
            }
        }
        return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        waitForDockMenu(of: item, target: target, attempt: attempt, attempts: attempts, pollsLeft: pollsLeft - 1, completion: completion)
    }
}

/// Waits for the quit to finish, then clears the Dock's background state. The
/// Dock tile is what the user sees, so it must go even when every process is
/// already gone. A pinned app that is fully closed reports `isRunning == 0`,
/// so its ordinary tile is left alone.
func clearBackgroundActivity(after apps: [NSRunningApplication], target: DockItem) {
    let deadline = Date().addingTimeInterval(2.5)
    func poll() {
        let stillRunning = runningApp(for: target)
        if stillRunning == nil && apps.allSatisfy(hasExited) {
            stopRunningInBackground(target)
        } else if Date() >= deadline {
            print("[UXTapFix] '\(target.name)' is still running; not touching its Dock tile.")
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
var normalQuitWaits: [pid_t: Int] = [:]

func finishQuit(
    app: NSRunningApplication,
    helpers: [NSRunningApplication],
    descendants: [pid_t],
    target: DockItem,
    force: Bool
) {
    let pid = app.processIdentifier
    if force {
        // Drop a normal-quit waiter so it cannot keep polling after this.
        normalQuitWaits[pid] = nil
        if !hasExited(app) { app.forceTerminate() }
        for helper in helpers where !hasExited(helper) {
            helper.forceTerminate()
        }
        forceTerminate(processIDs: descendants)
        clearBackgroundActivity(after: [app] + helpers, target: target)
        return
    }

    normalQuitWaits[pid, default: 0] += 1
    let generation = normalQuitWaits[pid] ?? 0
    let deadline = Date().addingTimeInterval(300)

    func waitForExit() {
        // A newer normal quit, or a force quit, owns this app now.
        guard normalQuitWaits[pid] == generation else { return }
        let allTerminated = hasExited(app) && helpers.allSatisfy(hasExited)
        if allTerminated {
            normalQuitWaits[pid] = nil
            clearBackgroundActivity(after: [app] + helpers, target: target)
        } else if Date() >= deadline {
            // The user cancelled the quit, or a helper is stuck. Do not force
            // anything; just stop retaining the app and leave its tile alone.
            normalQuitWaits[pid] = nil
            print("[UXTapFix] '\(target.name)' is still running; leaving its Dock tile alone.")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: waitForExit)
        }
    }
    waitForExit()
}

func quitApp(_ target: DockItem, mode: QuitMode = .normal) {
    if isBlacklisted(target) {
        print("[UXTapFix] Ignoring blacklisted '\(target.name)'")
        return
    }
    if let app = runningApp(for: target) {
        lastQuitName = target.name
        lastQuitAt = Date().timeIntervalSince1970
        writeStatus()

        let helpers = backgroundHelpers(of: app)
        let descendants = descendantProcessIDs(of: app.processIdentifier)

        switch mode {
        case .normal:
            print("[UXTapFix] Quitting '\(target.name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            _ = app.terminate()
            for helper in helpers { _ = helper.terminate() }
            finishQuit(app: app, helpers: helpers, descendants: descendants, target: target, force: false)
        case .force:
            print("[UXTapFix] Force quitting '\(target.name)' pid \(app.processIdentifier) and \(helpers.count) background process(es)")
            app.forceTerminate()
            for helper in helpers { helper.forceTerminate() }
            finishQuit(app: app, helpers: helpers, descendants: descendants, target: target, force: true)
        }
        return
    }

    print("[UXTapFix] No running app for '\(target.name)'")
    // The app may already be gone while macOS still shows its tile as "Running
    // in Background". A click on that tile should clear exactly that state.
    clearBackgroundActivity(after: [], target: target)
}

// MARK: - Mission Control / App Exposé

// One middle-click on a window thumbnail closes that window and leaves the
// overview up, the same way a middle-click closes a browser tab.
//
// The thumbnail layout is unpublished. Through macOS 26 the Dock exposes it as
// `mc` → `mc.display` → `mc.windows` (and `appexpose` for App Exposé). On
// macOS 27 it moved to WindowManager: `mc.display` / `appexpose.display` hold
// the window buttons directly, and each button's `wid` is the real window id.
// The Dock keeps an empty `mc` group. Space tiles (Desktop 1, a full-screen
// app, the add button) live under `mc.spaces` and are not windows.
let closeOverviewEnabled: Bool = UserDefaults.standard.object(forKey: "middleClickCloseOverview") == nil
    ? true
    : UserDefaults.standard.bool(forKey: "middleClickCloseOverview")
let removeCalendarEventEnabled: Bool = UserDefaults.standard.object(forKey: "middleClickRemoveCalendarEvent") == nil
    ? true
    : UserDefaults.standard.bool(forKey: "middleClickRemoveCalendarEvent")

// Carbon `kVK_Delete` — the Mac delete/backspace key Calendar uses to remove events.
private let deleteKeyCode: CGKeyCode = 0x33

enum OverviewKind {
    case missionControl
    case appExpose

    var logName: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        }
    }
}

struct OverviewThumbnail {
    let title: String
    let windowID: CGWindowID?
    let frame: CGRect
    let kind: OverviewKind
}

struct OverviewWindow {
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String
    let frame: CGRect
    let windowID: CGWindowID?
}

private struct OverviewHostPIDs {
    var windowManager: pid_t = 0
    var dock: pid_t = 0
}

private struct OverviewScan {
    var populated = false
    var kind: OverviewKind?
    var match: OverviewThumbnail?
}

private let overviewHostLock = NSLock()
private var overviewHosts = OverviewHostPIDs()
// While the overview is closed, skip the Dock tree briefly. Copying it on
// every browser-tab click can stall the event tap long enough for macOS to
// disable it.
private var overviewDockClosedUntil: TimeInterval = 0

/// `_AXUIElementGetWindow` is private but stable; Rectangle and AltTab use it.
/// Resolved at runtime so a missing symbol only loses id matching.
private typealias AXGetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private let axGetWindow: AXGetWindowFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
        return nil
    }
    return unsafeBitCast(symbol, to: AXGetWindowFunction.self)
}()

func refreshOverviewHosts() {
    func pid(_ bundleID: String) -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier ?? 0
    }
    let hosts = OverviewHostPIDs(
        windowManager: pid("com.apple.WindowManager"),
        dock: pid("com.apple.dock")
    )
    overviewHostLock.lock()
    overviewHosts = hosts
    overviewHostLock.unlock()
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axAttribute(element, attribute) as? String
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let raw = axAttribute(element, kAXChildrenAttribute) else { return [] }
    if let values = raw as? [AXUIElement] { return values }
    guard CFGetTypeID(raw) == CFArrayGetTypeID(), let objects = raw as? [AnyObject] else { return [] }
    return objects.compactMap { value in
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    if let raw = axAttribute(element, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() {
        var rect = CGRect.zero
        if AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 {
            return rect
        }
    }
    guard let positionValue = axAttribute(element, kAXPositionAttribute),
          let sizeValue = axAttribute(element, kAXSizeAttribute),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: position, size: size)
}

private func axUInt32(_ element: AXUIElement, _ attribute: String) -> UInt32? {
    guard let number = axAttribute(element, attribute) as? NSNumber else { return nil }
    let value = number.uint32Value
    return value == 0 ? nil : value
}

private func cgWindowID(of element: AXUIElement) -> CGWindowID? {
    guard let axGetWindow else { return nil }
    var id: CGWindowID = 0
    guard axGetWindow(element, &id) == .success, id != 0 else { return nil }
    return id
}

private func prepareAX(_ element: AXUIElement, timeout: Float = 0.05) -> AXUIElement {
    AXUIElementSetMessagingTimeout(element, timeout)
    return element
}

/// The window under `point`, or nil when no overview is up or the pointer is
/// on a space tile / the wallpaper gap. Safe to call from the event-tap thread:
/// it only reads the cached host pids and the accessibility tree.
func overviewThumbnail(containing point: CGPoint) -> OverviewThumbnail? {
    guard closeOverviewEnabled else { return nil }
    let now = ProcessInfo.processInfo.systemUptime
    overviewHostLock.lock()
    let hosts = overviewHosts
    let dockClosedUntil = overviewDockClosedUntil
    overviewHostLock.unlock()

    // macOS 27 publishes the live tree here. A quiet WindowManager has no
    // `mc.display`, so this stays cheap while the overview is closed.
    if hosts.windowManager > 0 {
        var scan = OverviewScan()
        scanOverviewHost(hosts.windowManager, point: point, scan: &scan)
        if let match = scan.match { return match }
        if scan.populated { return nil }
    }

    if now < dockClosedUntil || hosts.dock <= 0 { return nil }
    var scan = OverviewScan()
    scanOverviewHost(hosts.dock, point: point, scan: &scan)
    if !scan.populated {
        overviewHostLock.lock()
        overviewDockClosedUntil = now + 0.2
        overviewHostLock.unlock()
    }
    return scan.match
}

private func scanOverviewHost(_ pid: pid_t, point: CGPoint, scan: inout OverviewScan) {
    let root = prepareAX(AXUIElementCreateApplication(pid), timeout: 0.08)
    for child in axChildren(root) {
        switch axString(child, kAXIdentifierAttribute) ?? "" {
        case "mc":
            scanOverviewContainer(child, kind: .missionControl, point: point, scan: &scan)
        case "mc.display":
            scanOverviewDisplay(child, kind: .missionControl, point: point, scan: &scan)
        case "appexpose":
            scanOverviewContainer(child, kind: .appExpose, point: point, scan: &scan)
        case "appexpose.display":
            scanOverviewDisplay(child, kind: .appExpose, point: point, scan: &scan)
        default:
            break
        }
    }
}

private func scanOverviewContainer(_ container: AXUIElement, kind: OverviewKind, point: CGPoint, scan: inout OverviewScan) {
    _ = prepareAX(container)
    for child in axChildren(container) {
        switch axString(child, kAXIdentifierAttribute) ?? "" {
        case "mc.display", "appexpose.display":
            scanOverviewDisplay(child, kind: kind, point: point, scan: &scan)
        case "mc.windows", "appexpose.windows":
            noteOverviewButtons(axChildren(child), kind: kind, point: point, scan: &scan)
        default:
            break
        }
    }
}

private func scanOverviewDisplay(_ display: AXUIElement, kind: OverviewKind, point: CGPoint, scan: inout OverviewScan) {
    _ = prepareAX(display)
    for child in axChildren(display) {
        let identifier = axString(child, kAXIdentifierAttribute) ?? ""
        // Desktop tiles and the "+" button are spaces, not windows.
        if identifier == "mc.spaces" || identifier.hasPrefix("mc.spaces") { continue }
        if identifier == "mc.windows" || identifier == "appexpose.windows" {
            noteOverviewButtons(axChildren(child), kind: kind, point: point, scan: &scan)
            continue
        }
        if axString(child, kAXRoleAttribute) == "AXButton" {
            noteOverviewButtons([child], kind: kind, point: point, scan: &scan)
        }
    }
}

private func axActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

private func noteOverviewButtons(_ buttons: [AXUIElement], kind: OverviewKind, point: CGPoint, scan: inout OverviewScan) {
    for button in buttons {
        _ = prepareAX(button)
        let identifier = axString(button, kAXIdentifierAttribute) ?? ""
        if identifier == "mc.spaces.add" || identifier.hasPrefix("mc.spaces") { continue }
        if let role = axString(button, kAXRoleAttribute), role != "AXButton" { continue }
        guard let frame = axFrame(button), frame.width >= 24, frame.height >= 24 else { continue }
        let title = axString(button, kAXTitleAttribute) ?? ""
        let windowID = axUInt32(button, "wid")
        if title.isEmpty && windowID == nil { continue }
        scan.populated = true
        if scan.kind == nil { scan.kind = kind }
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else { continue }
        let candidate = OverviewThumbnail(title: title, windowID: windowID, frame: frame, kind: kind)
        if let current = scan.match {
            // A window id beats a title-only sibling (a nested control has no wid).
            // Otherwise the smaller frame is the control the pointer is actually on.
            if current.windowID != nil && candidate.windowID == nil { continue }
            if current.windowID == nil && candidate.windowID != nil {
                scan.match = candidate
                continue
            }
            let area = frame.width * frame.height
            if current.frame.width * current.frame.height <= area { continue }
        }
        scan.match = candidate
    }
}

func consumeMiddleClick(at point: CGPoint) -> Bool {
    if let item = dockItem(at: point) {
        DispatchQueue.main.async { registerDockMiddleClick(item) }
        return true
    }
    if let thumb = overviewThumbnail(containing: point) {
        DispatchQueue.main.async { closeOverviewWindow(thumb) }
        return true
    }
    if removeCalendarEventEnabled, let event = calendarEvent(at: point) {
        DispatchQueue.main.async { removeCalendarEvent(event) }
        return true
    }
    return false
}

// MARK: - Calendar events

// Tag synthetic clicks so our own event tap never rewrites them.
private let syntheticEventTag: Int64 = 0x55585446

struct CalendarEventHit {
    let element: AXUIElement
    let label: String
    let pid: pid_t
    let point: CGPoint
}

private func axParent(_ element: AXUIElement) -> AXUIElement? {
    guard let raw = axAttribute(element, kAXParentAttribute) else { return nil }
    guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
}

/// Week/day events are `AXStaticText` with Press + ShowMenu under a
/// `day-column-*` list. Mini-month day cells only expose `AXOpen`.
private func isCalendarEventElement(_ element: AXUIElement) -> Bool {
    guard axString(element, kAXRoleAttribute) == "AXStaticText" else { return false }
    let actions = axActions(element)
    guard actions.contains(kAXPressAction as String),
          actions.contains(kAXShowMenuAction as String) else { return false }
    if let parent = axParent(element) {
        let parentID = axString(parent, kAXIdentifierAttribute) ?? ""
        if parentID.hasPrefix("day-column-") { return true }
    }
    let desc = axString(element, kAXDescriptionAttribute) ?? ""
    return desc.localizedCaseInsensitiveContains("Starts on")
        || desc.localizedCaseInsensitiveContains("All-Day")
        || desc.localizedCaseInsensitiveContains("All Day")
}

func calendarEvent(at point: CGPoint) -> CalendarEventHit? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iCal").first else {
        return nil
    }
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.1)
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el) == .success,
          let start = el else { return nil }

    var pid: pid_t = 0
    guard AXUIElementGetPid(start, &pid) == .success, pid == app.processIdentifier else {
        return nil
    }

    var current: AXUIElement? = start
    for _ in 0..<6 {
        guard let node = current else { break }
        AXUIElementSetMessagingTimeout(node, 0.1)
        if isCalendarEventElement(node) {
            let label = axString(node, kAXDescriptionAttribute)
                ?? axString(node, kAXTitleAttribute)
                ?? "event"
            return CalendarEventHit(element: node, label: label, pid: pid, point: point)
        }
        let id = axString(node, kAXIdentifierAttribute) ?? ""
        // Landed on the empty day column / chrome, not an event.
        if id.hasPrefix("day-column-") || id == "week-container" || id == "canvasFrame" || id == "CALMainWindow" {
            return nil
        }
        current = axParent(node)
    }
    return nil
}

private func postLeftClick(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { continue }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }
}

private func calendarHasModalSheet(pid: pid_t) -> Bool {
    let axApp = prepareAX(AXUIElementCreateApplication(pid), timeout: 0.2)
    let windows = axAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for window in windows {
        if let sheets = axAttribute(window, "AXSheets") as? [AXUIElement], !sheets.isEmpty {
            return true
        }
        let subrole = axString(window, kAXSubroleAttribute)
        if subrole == "AXSystemDialog" { return true }
    }
    return false
}

func removeCalendarEvent(_ hit: CalendarEventHit) {
    let short = hit.label.count > 60 ? String(hit.label.prefix(57)) + "…" : hit.label
    print("[UXTapFix] Removing Calendar event '\(short)'")
    guard let app = NSRunningApplication(processIdentifier: hit.pid) else { return }

    let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == hit.pid
    if !wasFrontmost {
        _ = activateApp(app, from: NSWorkspace.shared.frontmostApplication)
    }

    // A real left-click selects the event and focuses Calendar's grid in one
    // step; AXPress alone can leave first-responder focus behind on the first
    // click, forcing a second click to actually delete.
    let clickDelay: TimeInterval = wasFrontmost ? 0.0 : 0.08
    DispatchQueue.main.asyncAfter(deadline: .now() + clickDelay) {
        postLeftClick(at: hit.point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard axElementIsValid(hit.element) else { return }
            postKey(virtualKey: deleteKeyCode, to: hit.pid)
            // A recurring event opens its confirmation sheet asynchronously.
            // Give it time to appear; never send another Delete into that sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard axElementIsValid(hit.element), !calendarHasModalSheet(pid: hit.pid) else { return }
                _ = prepareAX(hit.element, timeout: 0.25)
                _ = AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard axElementIsValid(hit.element), !calendarHasModalSheet(pid: hit.pid) else { return }
                    postKey(virtualKey: deleteKeyCode, to: hit.pid)
                }
            }
        }
    }
}

private func collapsedTitle(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix("…") || text.hasSuffix("...") {
        if text.hasSuffix("…") {
            text.removeLast()
        } else if text.count >= 3 {
            text.removeLast(3)
        } else {
            break
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

/// Lower is better. nil means the titles are not the same window.
private func titleMatchScore(_ thumbnail: String, _ window: String, appName: String) -> Double? {
    let thumb = collapsedTitle(thumbnail)
    let win = collapsedTitle(window)
    if !win.isEmpty && thumb == win { return 0 }
    if thumb.count >= 8 && !win.isEmpty && win.hasPrefix(thumb) { return 0.35 }
    if win.count >= 8 && !thumb.isEmpty && thumb.hasPrefix(win) { return 0.45 }
    if thumb.count >= 8 && win.count >= 8 && (win.contains(thumb) || thumb.contains(win)) { return 0.75 }
    let app = collapsedTitle(appName)
    if !app.isEmpty && thumb == app && win.isEmpty { return 0.4 }
    if !app.isEmpty && thumb == app { return 1.15 }
    return nil
}

private func isOverviewProcess(_ app: NSRunningApplication) -> Bool {
    switch app.bundleIdentifier {
    case "com.apple.dock", "com.apple.WindowManager", "com.apple.exposelauncher":
        return true
    default:
        return false
    }
}

private func windows(of app: NSRunningApplication) -> [OverviewWindow] {
    let axApp = prepareAX(AXUIElementCreateApplication(app.processIdentifier), timeout: 0.25)
    guard let elements = axAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    var result: [OverviewWindow] = []
    for element in elements {
        guard axString(element, kAXRoleAttribute) == "AXWindow" else { continue }
        guard let frame = axFrame(element), frame.width >= 20, frame.height >= 20 else { continue }
        result.append(OverviewWindow(
            element: element,
            app: app,
            title: axString(element, kAXTitleAttribute) ?? "",
            frame: frame,
            windowID: cgWindowID(of: element)
        ))
    }
    return result
}

private func windowOwner(of windowID: CGWindowID) -> pid_t? {
    guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for item in info {
        guard let number = item[kCGWindowNumber as String] as? NSNumber,
              number.uint32Value == windowID,
              let pid = item[kCGWindowOwnerPID as String] as? NSNumber else { continue }
        let value = pid.int32Value
        return value > 0 ? value : nil
    }
    return nil
}

private func bestTitleMatch(_ thumb: OverviewThumbnail, among windows: [OverviewWindow]) -> OverviewWindow? {
    let aspect = thumb.frame.width / max(thumb.frame.height, 1)
    var ranked: [(score: Double, window: OverviewWindow)] = []
    for window in windows {
        guard var score = titleMatchScore(thumb.title, window.title, appName: window.app.localizedName ?? "") else {
            continue
        }
        let windowAspect = window.frame.width / max(window.frame.height, 1)
        score += abs(aspect - windowAspect) / max(aspect, windowAspect)
        ranked.append((score, window))
    }
    ranked.sort { $0.score < $1.score }
    guard let best = ranked.first, best.score <= 1.35 else { return nil }
    if ranked.count > 1, ranked[1].score - best.score < 0.12 {
        print("[UXTapFix] Overview thumbnail '\(thumb.title)' matches more than one window; left them open")
        return nil
    }
    return best.window
}

private func matchedWindow(for thumb: OverviewThumbnail) -> OverviewWindow? {
    if let windowID = thumb.windowID, let pid = windowOwner(of: windowID),
       let app = NSRunningApplication(processIdentifier: pid), !isOverviewProcess(app) {
        let owned = windows(of: app)
        if let exact = owned.first(where: { $0.windowID == windowID }) { return exact }
        // The id named the app, but the window itself did not expose one.
        // Stay inside that app so a similar title elsewhere cannot be closed.
        return bestTitleMatch(thumb, among: owned)
    }

    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !isOverviewProcess($0)
    }
    return bestTitleMatch(thumb, among: apps.flatMap(windows(of:)))
}

private func axElementIsValid(_ element: AXUIElement) -> Bool {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
}

private func pressCloseButton(_ window: AXUIElement) -> Bool {
    guard let raw = axAttribute(window, kAXCloseButtonAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
    let button = prepareAX(raw as! AXUIElement, timeout: 0.3)
    if let enabled = axAttribute(button, kAXEnabledAttribute) as? NSNumber, !enabled.boolValue {
        return false
    }
    return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
}

private func windowNeedsAttention(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
    if let children = axAttribute(window, kAXChildrenAttribute) as? [AXUIElement],
       children.contains(where: { axString($0, kAXRoleAttribute) == "AXSheet" }) {
        return true
    }
    let axApp = prepareAX(AXUIElementCreateApplication(app.processIdentifier), timeout: 0.25)
    let windows = axAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.contains { candidate in
        let subrole = axString(candidate, kAXSubroleAttribute)
        return subrole == "AXDialog" || subrole == "AXSystemDialog"
    }
}

private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
        event.flags = flags
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

@discardableResult
private func activateApp(_ app: NSRunningApplication, from other: NSRunningApplication?) -> Bool {
    if #available(macOS 14.0, *), let other {
        return app.activate(from: other, options: [])
    }
    return app.activate(options: [])
}

/// True when that overview is still showing window thumbnails. An empty `mc`
/// group on the Dock (macOS 27) does not count.
private func overviewIsOpen(_ kind: OverviewKind) -> Bool {
    overviewHostLock.lock()
    let hosts = overviewHosts
    overviewHostLock.unlock()
    let offscreen = CGPoint(x: -10000, y: -10000)
    for pid in [hosts.windowManager, hosts.dock] where pid > 0 {
        var scan = OverviewScan()
        scanOverviewHost(pid, point: offscreen, scan: &scan)
        if scan.populated && scan.kind == kind { return true }
    }
    return false
}

private func leaveOverview(_ kind: OverviewKind) {
    // Closing may already have dismissed the overview. Toggling Mission
    // Control then would open it on top of the save sheet, and Escape would
    // cancel the sheet.
    guard overviewIsOpen(kind) else { return }
    switch kind {
    case .missionControl:
        // Toggling the app dismisses the overview without sending Escape, so a
        // save sheet is not cancelled.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    case .appExpose:
        postKey(virtualKey: 53)
    }
}

private func closeWithCommandW(_ window: OverviewWindow, kind: OverviewKind) {
    guard axElementIsValid(window.element) else { return }
    let previous = NSWorkspace.shared.frontmostApplication
    let appElement = prepareAX(AXUIElementCreateApplication(window.app.processIdentifier), timeout: 0.4)
    AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    _ = activateApp(window.app, from: previous)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        guard let focused = axAttribute(appElement, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              CFEqual(focused as CFTypeRef, window.element) else {
            print("[UXTapFix] Could not focus '\(window.title)'; left it open")
            if let previous, previous.processIdentifier != window.app.processIdentifier {
                _ = activateApp(previous, from: window.app)
            }
            return
        }
        postKey(virtualKey: 13, flags: .maskCommand, to: window.app.processIdentifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !axElementIsValid(window.element) {
                if let previous, previous.processIdentifier != window.app.processIdentifier {
                    _ = activateApp(previous, from: window.app)
                }
                return
            }
            if windowNeedsAttention(window.element, app: window.app) {
                print("[UXTapFix] Save prompt open for '\(window.title)'; leaving \(kind.logName)")
                leaveOverview(kind)
                return
            }
            if let previous, previous.processIdentifier != window.app.processIdentifier {
                _ = activateApp(previous, from: window.app)
            }
            print("[UXTapFix] '\(window.title)' stayed open")
        }
    }
}

func closeOverviewWindow(_ thumb: OverviewThumbnail) {
    guard let window = matchedWindow(for: thumb) else {
        let id = thumb.windowID.map(String.init) ?? "none"
        print("[UXTapFix] No window matched the \(thumb.kind.logName) thumbnail '\(thumb.title)' (wid \(id))")
        return
    }
    let label = window.title.isEmpty ? (window.app.localizedName ?? thumb.title) : window.title
    print("[UXTapFix] Closing '\(label)' from \(thumb.kind.logName)")

    guard pressCloseButton(window.element) else {
        closeWithCommandW(window, kind: thumb.kind)
        return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        if !axElementIsValid(window.element) { return }
        if windowNeedsAttention(window.element, app: window.app) {
            print("[UXTapFix] Save prompt open for '\(label)'; leaving \(thumb.kind.logName)")
            leaveOverview(thumb.kind)
            return
        }
        print("[UXTapFix] Close button did not dismiss '\(label)'; trying ⌘W")
        closeWithCommandW(window, kind: thumb.kind)
    }
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
var pendingDockClick: DockItem?
var pendingDockClickWorkItem: DispatchWorkItem?

func registerDockMiddleClick(_ target: DockItem) {
    guard multiClickEnabled else {
        quitApp(target)
        return
    }
    if pendingDockClick?.name != target.name {
        // The window only exists so more clicks on this same icon can arrive.
        // A click on a different icon used to cancel the previous quit and
        // never run it.
        commitPendingDockClick()
        pendingDockClickCount = 0
    }
    pendingDockClick = target
    pendingDockClickCount = min(pendingDockClickCount + 1, 3)
    let count = pendingDockClickCount
    print("[UXTapFix] Dock middle-click \(count) on '\(target.name)'")

    pendingDockClickWorkItem?.cancel()
    pendingDockClickWorkItem = nil

    // There is nothing beyond force quit, so act immediately on the third
    // click. Waiting for the window to elapse would let continued clicking
    // postpone the force quit indefinitely.
    if count >= 3 {
        pendingDockClick = nil
        pendingDockClickCount = 0
        quitApp(target, mode: .force)
        return
    }

    // One click and two clicks both mean "quit normally". The wait only exists
    // so a third click can still arrive and turn it into a force quit.
    let work = DispatchWorkItem {
        commitPendingDockClick()
    }
    pendingDockClickWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + multiClickWindow, execute: work)
}

func commitPendingDockClick() {
    pendingDockClickWorkItem?.cancel()
    pendingDockClickWorkItem = nil
    guard let target = pendingDockClick else { return }
    pendingDockClick = nil
    pendingDockClickCount = 0
    quitApp(target, mode: .normal)
}

// MARK: - CGEventTap (can swallow)

var eventTap: CFMachPort?
var globalMonitor: Any?
let middleButton: Int64 = 2
// True while a middle-button down over the Dock or an overview thumbnail was
// swallowed; its matching up must be swallowed too so the target does not see
// a half-click.
var swallowedMiddleDown = false

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // An up that never arrived must not be swallowed on the next click.
        swallowedMiddleDown = false
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if event.getIntegerValueField(.eventSourceUserData) == syntheticEventTag {
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
        // A down before the previous up means the up was missed.
        swallowedMiddleDown = false
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == middleButton, consumeMiddleClick(at: event.location) {
            swallowedMiddleDown = true
            return nil // swallow
        }
    } else if event.type == .otherMouseUp {
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == middleButton && swallowedMiddleDown {
            swallowedMiddleDown = false
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
            print("[UXTapFix] CGEventTap unavailable (check Accessibility). Falling back to NSEvent global monitor.")
        }
        return false
    }
    eventTap = tap
    swallowedMiddleDown = false
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("[UXTapFix] CGEventTap installed ✓ (will swallow middle-click on the Dock and in Mission Control)")
    return true
}

/// A permission can land after launch (the usual case during Setup). TCC
/// caches the old answer in this process, so retry the tap instead of making
/// the user restart the background service.
func retryEventTapIfNeeded() {
    guard accessibilityGranted() else { return }
    if let tap = eventTap {
        if CGEvent.tapIsEnabled(tap: tap) { return }
        // The callback re-enables most disabled taps. If that did not stick,
        // discard the dead tap and build a fresh one below.
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) { return }
        CFMachPortInvalidate(tap)
        eventTap = nil
    }
    if tryInstallEventTap(logFailure: false) {
        removeGlobalMonitor()
        print("[UXTapFix] Accessibility became available; event tap is active without a restart.")
    } else {
        // Keep a passive path alive if the tap cannot be rebuilt.
        installGlobalMonitor()
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
        guard let pt else { return }
        _ = consumeMiddleClick(at: pt)
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
    print("[UXTapFix] Using fallback monitor. Dock clicks still require Accessibility; the Dock menu may flash briefly.")
} else {
    print("[UXTapFix] Input Monitoring \(inputMonitoringGranted() ? "granted ✓" : "not granted")")
}

let middleClickOK = MiddleClickEmulator.shared.start()
if MiddleClickEmulator.shared.enabled {
    if middleClickOK {
        print("[UXTapFix] Three-finger tap/click sends a middle click. Middle-click a browser tab, a window in Mission Control, or a Calendar event, to close or delete it.")
    } else {
        print("[UXTapFix] Trackpad support unavailable; middle-click still works with a mouse or another gesture app.")
    }
}

if !NSRunningApplication.runningApplications(withBundleIdentifier: "art.ginzburg.MiddleClick").isEmpty {
    print("[UXTapFix] ⚠️ MiddleClick is also running. Quit it to avoid two middle clicks per three-finger gesture.")
}

startStatusHeartbeat()
if !closeOverviewEnabled {
    print("[UXTapFix] Mission Control window close disabled by preference.")
}
if !removeCalendarEventEnabled {
    print("[UXTapFix] Calendar event removal disabled by preference.")
}
print("[UXTapFix] Ready. Three-finger tap/click a Dock icon to quit, a browser tab to close it, a Mission Control window to close it, or a Calendar event to delete it. PID \(getpid())")
print("[UXTapFix] Log: \(logFileURL.path)")

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    print("[UXTapFix] SIGTERM")
    exit(0)
}
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    print("[UXTapFix] SIGINT")
    exit(0)
}
sigtermSource.resume()
sigintSource.resume()

CFRunLoopRun()
