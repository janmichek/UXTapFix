// UXTapFix v2.4
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
// True while a middle-button down over the Dock was swallowed; its matching up
// must be swallowed too so the Dock does not see a half-click.
var swallowedDockMiddleDown = false

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // An up that never arrived must not be swallowed on the next click.
        swallowedDockMiddleDown = false
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
        // A down before the previous up means the up was missed.
        swallowedDockMiddleDown = false
        let btn = event.getIntegerValueField(.mouseEventButtonNumber)
        if btn == middleButton {
            let loc = event.location
            if let item = dockItem(at: loc) {
                swallowedDockMiddleDown = true
                DispatchQueue.main.async { registerDockMiddleClick(item) }
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
            print("[UXTapFix] CGEventTap unavailable (check Accessibility). Falling back to NSEvent global monitor.")
        }
        return false
    }
    eventTap = tap
    swallowedDockMiddleDown = false
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
        guard let pt, let item = dockItem(at: pt) else { return }
        DispatchQueue.main.async { registerDockMiddleClick(item) }
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
