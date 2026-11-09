import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Status file written by the daemon

struct DaemonStatus {
    let version: String?
    let pid: Int?
    let accessibility: Bool
    let inputMonitoring: Bool
    let eventTapActive: Bool
    let startedAt: Date?
    let updatedAt: Date
    let lastQuitApp: String?
    let lastQuitAt: Date?

    var isFresh: Bool {
        Date().timeIntervalSince(updatedAt) < 8
    }

    var uptime: TimeInterval? {
        guard let startedAt, isFresh else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    var lastQuitDescription: String? {
        guard let lastQuitAt, let lastQuitApp else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(lastQuitApp) · \(formatter.localizedString(for: lastQuitAt, relativeTo: Date()))"
    }

    static func read(from url: URL) -> DaemonStatus? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func number(_ key: String) -> Double? {
            (object[key] as? NSNumber)?.doubleValue
        }

        guard let updatedAt = number("updatedAt") else { return nil }

        return DaemonStatus(
            version: object["version"] as? String,
            pid: (object["pid"] as? NSNumber)?.intValue,
            accessibility: (object["accessibility"] as? Bool) ?? false,
            inputMonitoring: (object["inputMonitoring"] as? Bool) ?? false,
            eventTapActive: (object["eventTapActive"] as? Bool) ?? false,
            startedAt: number("startedAt").map(Date.init(timeIntervalSince1970:)),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            lastQuitApp: object["lastQuitApp"] as? String,
            lastQuitAt: number("lastQuitAt").map(Date.init(timeIntervalSince1970:))
        )
    }
}

// MARK: - Installer model

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case install
        case permissions
        case login
        case done

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .install: return "Install"
            case .permissions: return "Access"
            case .login: return "Login"
            case .done: return "Ready"
            }
        }
    }

    enum InstallPhase: Equatable {
        case idle
        case stopping
        case copying
        case registering
        case starting
        case finished

        var label: String {
            switch self {
            case .idle: return "Ready to install"
            case .stopping: return "Stopping the old service"
            case .copying: return "Copying DockMiddleQuit.app"
            case .registering: return "Adding the login item"
            case .starting: return "Starting the background service"
            case .finished: return "Installed"
            }
        }
    }

    enum PermissionKind {
        case accessibility
        case inputMonitoring

        var settingsURL: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }

        var requestArgument: String {
            switch self {
            case .accessibility: return "--request-accessibility"
            case .inputMonitoring: return "--request-input-monitoring"
            }
        }

        var displayName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        // Service names accepted by `tccutil reset`.
        var tccService: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "ListenEvent"
            }
        }
    }

    struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published var step: Step = .welcome
    @Published var installed = false
    @Published var launchAtLogin = false
    @Published var status: DaemonStatus?
    @Published var lastRefresh = Date()
    @Published var busy = false
    @Published var installPhase: InstallPhase = .idle
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var requestedPermission: PermissionKind?
    @Published var restartingService = false
    @Published var showUninstallConfirmation = false
    @Published var didJustInstall = false
    @Published var hadLegacyInstall = false
    @Published var legacyLoginItemPresent = false

    private let fileManager = FileManager.default
    private var didBootstrap = false
    private var hasPermissionBaseline = false
    private var previousAccessibility = false
    private var previousInputMonitoring = false
    private var isCheckingLegacyLoginItem = false

    let label = "com.user.dockmiddlequit"
    let setupVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2"

    // MARK: Paths

    var homeURL: URL { fileManager.homeDirectoryForCurrentUser }

    var appURL: URL {
        homeURL.appendingPathComponent("Applications/DockMiddleQuit.app", isDirectory: true)
    }

    var legacyAppURL: URL {
        URL(fileURLWithPath: "/Applications/DockMiddleQuit.app", isDirectory: true)
    }

    var legacyInstalled: Bool {
        fileManager.fileExists(atPath: legacyAppURL.path)
    }

    var setupAppURL: URL {
        homeURL.appendingPathComponent("Applications/DockMiddleQuit Setup.app", isDirectory: true)
    }

    var supportURL: URL {
        homeURL.appendingPathComponent("Library/Application Support/DockMiddleQuit", isDirectory: true)
    }

    var launchAgentURL: URL {
        homeURL.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    var logURL: URL {
        homeURL.appendingPathComponent("Library/Logs/DockMiddleQuit.log")
    }

    var statusURL: URL {
        supportURL.appendingPathComponent("status.json")
    }

    var daemonBinaryURL: URL {
        appURL.appendingPathComponent("Contents/MacOS/DockMiddleQuit")
    }

    var domain: String { "gui/\(getuid())" }
    var domainLabel: String { "\(domain)/\(label)" }

    // MARK: Derived state

    var serviceRunning: Bool { status?.isFresh == true }
    var accessibilityGranted: Bool { status?.accessibility == true }
    var inputMonitoringGranted: Bool { status?.inputMonitoring == true }
    var allRequiredPermissionsGranted: Bool { accessibilityGranted }

    var canContinueFromPermissions: Bool { accessibilityGranted }

    var statusSummary: String {
        if serviceRunning {
            return "Background service running"
        }
        if installed {
            return "Background service stopped"
        }
        return "Not installed yet"
    }

    var permissionStatusDetail: String {
        guard let status else { return "Waiting for the background service to report in." }
        if !status.isFresh {
            return "Last checked \(relativeTime(since: status.updatedAt)). The service is not running right now."
        }
        return "Checked live from the background service."
    }

    var lastQuitDescription: String? {
        status?.lastQuitDescription
    }

    func relativeTime(since date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Lifecycle

    func bootstrap() {
        guard !didBootstrap else {
            refresh()
            return
        }
        didBootstrap = true
        hadLegacyInstall = legacyInstalled
        refreshLegacyLoginItemStatus()
        refresh()
        guard installed else {
            step = .welcome
            return
        }
        if serviceRunning && accessibilityGranted && launchAtLogin {
            step = .done
        } else {
            step = .permissions
        }
    }

    func refresh() {
        installed = fileManager.fileExists(atPath: appURL.path)
        launchAtLogin = fileManager.fileExists(atPath: launchAgentURL.path)
        if let newStatus = DaemonStatus.read(from: statusURL) {
            status = newStatus
            detectPermissionChange(in: newStatus)
        } else if !fileManager.fileExists(atPath: statusURL.path) {
            status = nil
        }
        lastRefresh = Date()

        if requestedPermission == .accessibility && accessibilityGranted {
            requestedPermission = nil
        }
        if requestedPermission == .inputMonitoring && inputMonitoringGranted {
            requestedPermission = nil
        }
    }

    private func detectPermissionChange(in newStatus: DaemonStatus) {
        defer {
            previousAccessibility = newStatus.accessibility
            previousInputMonitoring = newStatus.inputMonitoring
            hasPermissionBaseline = true
        }

        guard hasPermissionBaseline else { return }
        let gainedAccessibility = !previousAccessibility && newStatus.accessibility
        let gainedInputMonitoring = !previousInputMonitoring && newStatus.inputMonitoring
        guard (gainedAccessibility || gainedInputMonitoring), newStatus.isFresh, launchAtLogin, !restartingService else {
            return
        }

        restartingService = true
        infoMessage = "Permission granted. Restarting DockMiddleQuit so it takes effect…"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            restartService(quiet: true)
            restartingService = false
            infoMessage = "Permission applied. You're good to go."
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if infoMessage == "Permission applied. You're good to go." {
                infoMessage = nil
            }
        }
    }

    // MARK: Navigation

    func goNext() {
        switch step {
        case .welcome:
            step = installed ? .permissions : .install
        case .install:
            step = .permissions
        case .permissions:
            step = .login
        case .login:
            step = .done
        case .done:
            NSApp.terminate(nil)
        }
    }

    func goBack() {
        switch step {
        case .welcome:
            break
        case .install:
            step = .welcome
        case .permissions:
            step = .install
        case .login:
            step = .permissions
        case .done:
            step = .login
        }
    }

    // MARK: Install

    func install() async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        infoMessage = nil
        installPhase = .stopping

        do {
            _ = stopService()
            stopRunningDaemons()
            try migrateLegacyInstall()

            installPhase = .copying
            try await Task.sleep(nanoseconds: 180_000_000)
            try copyPayloadApp()
            copySupportFiles()

            installPhase = .registering
            try await Task.sleep(nanoseconds: 180_000_000)
            try writeLaunchAgent()
            copySetupAppIfNeeded()

            installPhase = .starting
            try await Task.sleep(nanoseconds: 180_000_000)
            try startService()
            installPhase = .finished
            installed = true
            launchAtLogin = true
            didJustInstall = true

            await unregisterLegacyLoginItemIfNeeded()
            try await Task.sleep(nanoseconds: 650_000_000)
            refresh()
            await waitForFreshStatus(timeout: 5.0)
            infoMessage = "Installed. Let's get macOS permissions sorted."
            step = .permissions
        } catch {
            installPhase = .idle
            errorMessage = error.localizedDescription
        }

        busy = false
    }

    private func stopRunningDaemons() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: label)
        for app in running {
            _ = app.terminate()
        }
        if !running.isEmpty {
            usleep(350_000)
        }
        for app in running where !app.isTerminated {
            _ = app.forceTerminate()
        }
        // Catch a daemon launched directly from a path LaunchServices doesn't know.
        _ = run("/usr/bin/pkill", ["-x", "DockMiddleQuit"])
        usleep(150_000)
    }

    private func migrateLegacyInstall() throws {
        hadLegacyInstall = legacyInstalled
        guard hadLegacyInstall else { return }
        do {
            try fileManager.trashItem(at: legacyAppURL, resultingItemURL: nil)
        } catch {
            throw InstallerError(message: "An older copy of DockMiddleQuit is in /Applications and couldn't be moved to the Trash. Remove it manually, then try again.\n\n\(error.localizedDescription)")
        }
    }

    private func refreshLegacyLoginItemStatus() {
        guard !isCheckingLegacyLoginItem else { return }
        isCheckingLegacyLoginItem = true
        Task { @MainActor in
            let present = await Task.detached(priority: .utility) {
                Self.legacyLoginItemExists()
            }.value
            self.legacyLoginItemPresent = present
            self.isCheckingLegacyLoginItem = false
        }
    }

    nonisolated private static func legacyLoginItemExists() -> Bool {
        let result = runTool("/usr/bin/sfltool", ["dumpbtm"])
        guard result.status == 0 else { return false }
        let legacyPath = "/Applications/DockMiddleQuit.app"
        return result.output.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Match the BTM app URL or an old launchd entry's executable path.
            // Do not match ~/Applications, which is the current install.
            return line == "URL: \(legacyPath)"
                || line.hasPrefix("URL: \(legacyPath)/")
                || line.hasPrefix("Executable Path: \(legacyPath)/")
        }
    }

    private func unregisterLegacyLoginItemIfNeeded() async {
        guard hadLegacyInstall else { return }
        openDaemon(arguments: ["--unregister-login-item"])
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        refreshLegacyLoginItemStatus()
    }

    private func copyPayloadApp() throws {
        guard let payload = payloadAppURL else {
            throw InstallerError(message: "The installer is missing its DockMiddleQuit.app payload. Rebuild the Setup app with ./build.sh and try again.")
        }
        let applications = appURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: appURL.path) {
            try fileManager.removeItem(at: appURL)
        }
        try fileManager.copyItem(at: payload, to: appURL)
        removeQuarantine(from: appURL)

        guard fileManager.isExecutableFile(atPath: daemonBinaryURL.path) else {
            throw InstallerError(message: "The copied app is missing its executable. Try rebuilding with ./build.sh.")
        }
    }

    private var payloadAppURL: URL? {
        if let bundled = Bundle.main.url(forResource: "DockMiddleQuit", withExtension: "app") {
            return bundled
        }
        // Development fallback: dist/DockMiddleQuit Setup.app -> dist/DockMiddleQuit.app
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("DockMiddleQuit.app", isDirectory: true)
        return fileManager.fileExists(atPath: sibling.path) ? sibling : nil
    }

    private func copySupportFiles() {
        guard let resources = Bundle.main.resourceURL else { return }
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let source = resources.appendingPathComponent("DockMiddleQuit.swift")
        if fileManager.fileExists(atPath: source.path) {
            try? fileManager.removeItem(at: supportURL.appendingPathComponent("DockMiddleQuit.swift"))
            try? fileManager.copyItem(at: source, to: supportURL.appendingPathComponent("DockMiddleQuit.swift"))
        }

        let scripts = resources.appendingPathComponent("scripts", isDirectory: true)
        if fileManager.fileExists(atPath: scripts.path) {
            let contents = (try? fileManager.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil)) ?? []
            for file in contents where !file.hasDirectoryPath {
                let destination = supportURL.appendingPathComponent(file.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: file, to: destination)
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        }
    }

    private func copySetupAppIfNeeded() {
        let runningPath = Bundle.main.bundleURL.standardizedFileURL
        let destination = setupAppURL.standardizedFileURL
        guard runningPath.path != destination.path else { return }

        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try? fileManager.copyItem(at: runningPath, to: destination)
        removeQuarantine(from: destination)
    }

    private func writeLaunchAgent() throws {
        let logDirectory = logURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemonBinaryURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ThrottleInterval": 3,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func startService() throws {
        _ = run("/bin/launchctl", ["bootout", domainLabel])
        var result = run("/bin/launchctl", ["bootstrap", domain, launchAgentURL.path])
        if result.status != 0 {
            // A stopped service can occasionally still be registered for a moment.
            _ = run("/bin/launchctl", ["bootout", domainLabel])
            usleep(250_000)
            result = run("/bin/launchctl", ["bootstrap", domain, launchAgentURL.path])
        }
        guard result.status == 0 else {
            throw InstallerError(message: "macOS could not start the background service.\n\n\(result.output)\n\nTry again, or open the log for details.")
        }
        let kick = run("/bin/launchctl", ["kickstart", "-k", domainLabel])
        guard kick.status == 0 else {
            throw InstallerError(message: "The login item was added, but the service did not start.\n\n\(kick.output)")
        }
    }

    @discardableResult
    private func stopService() -> ProcessResult {
        run("/bin/launchctl", ["bootout", domainLabel])
    }

    func restartService(quiet: Bool = false) {
        guard installed, launchAtLogin else { return }
        restartingService = true
        let result = run("/bin/launchctl", ["kickstart", "-k", domainLabel])
        if result.status != 0 {
            errorMessage = "Could not restart the background service.\n\n\(result.output)"
        } else if !quiet {
            infoMessage = "Background service restarted."
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            restartingService = false
            refresh()
            if infoMessage == "Background service restarted." {
                infoMessage = nil
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        errorMessage = nil
        if enabled {
            do {
                try writeLaunchAgent()
                try startService()
                launchAtLogin = true
                refresh()
                infoMessage = "DockMiddleQuit will start automatically when you log in."
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            _ = stopService()
            try? fileManager.removeItem(at: launchAgentURL)
            launchAtLogin = false
            infoMessage = "DockMiddleQuit won't start at login. You can turn it back on anytime."
        }
    }

    private func waitForFreshStatus(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status?.isFresh == true { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            refresh()
        }
    }

    // MARK: Permissions

    func requestPermission(_ kind: PermissionKind) {
        guard installed else { return }
        // Old installs (or ad-hoc rebuilds) can leave a stale TCC entry behind:
        // System Settings shows DockMiddleQuit switched on, but the current app
        // is not actually trusted. Clear the record so macOS adds the current
        // app and shows a real grant prompt. Only do this while the daemon is
        // reporting live status; with a stopped service the last status could
        // be stale and clearing would revoke a permission that still works.
        if status?.isFresh == true {
            _ = clearPermissionRecord(kind)
        }
        requestedPermission = kind
        infoMessage = nil
        openDaemon(arguments: [kind.requestArgument])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            openSettings(kind.settingsURL)
        }
    }

    func resetPermission(_ kind: PermissionKind) {
        let result = clearPermissionRecord(kind)
        if result.status == 0 {
            requestedPermission = nil
            infoMessage = "Cleared the saved \(kind.displayName) permission. Click Grant Access to request it again."
        } else {
            errorMessage = "Could not reset the \(kind.displayName) permission.\n\n\(result.output)"
        }
        refresh()
    }

    @discardableResult
    private func clearPermissionRecord(_ kind: PermissionKind) -> ProcessResult {
        run("/usr/bin/tccutil", ["reset", kind.tccService, label])
    }

    func openPermissionSettings(_ kind: PermissionKind) {
        openSettings(kind.settingsURL)
    }

    func openLoginItemsSettings() {
        openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    private func openDaemon(arguments: [String]) {
        guard fileManager.fileExists(atPath: appURL.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        let binaryURL = daemonBinaryURL
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if error != nil {
                // Fallback for environments where LaunchServices refuses a second
                // instance. The daemon still receives the same TCC identity.
                let process = Process()
                process.executableURL = binaryURL
                process.arguments = arguments
                try? process.run()
            }
        }
    }

    private func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Misc actions

    func openLog() {
        if !fileManager.fileExists(atPath: logURL.path) {
            try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }

    func revealApp() {
        guard fileManager.fileExists(atPath: appURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    func revealSetupApp() {
        NSWorkspace.shared.activateFileViewerSelecting([setupAppURL])
    }

    // MARK: MiddleClick (trackpad tap) helper

    var middleClickInstalled: Bool {
        middleClickURL != nil
    }

    /// Number of fingers MiddleClick uses for its tap gesture, or nil when the
    /// gesture is disabled. Older builds store `trackpadThreeTap`; newer builds
    /// store the finger count in `fingers`.
    var middleClickFingerCount: Int? {
        guard middleClickInstalled else { return nil }
        let defaults = UserDefaults(suiteName: "art.ginzburg.MiddleClick")
        if let enabled = defaults?.object(forKey: "trackpadThreeTap") as? Bool, !enabled {
            return nil
        }
        let count = defaults?.object(forKey: "fingers") as? Int ?? 3
        return count >= 3 ? count : nil
    }

    var middleClickURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "art.ginzburg.MiddleClick")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.knollsoft.Middle")
    }

    func openMiddleClick() {
        if let url = middleClickURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else if let url = URL(string: "https://github.com/artginzburg/MiddleClick") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Uninstall

    func uninstall() async {
        busy = true
        _ = stopService()
        stopRunningDaemons()
        try? fileManager.removeItem(at: launchAgentURL)
        try? fileManager.removeItem(at: appURL)
        try? fileManager.removeItem(at: supportURL)
        try? fileManager.removeItem(at: logURL)
        _ = run("/usr/bin/tccutil", ["reset", "Accessibility", label])
        _ = run("/usr/bin/tccutil", ["reset", "ListenEvent", label])

        if fileManager.fileExists(atPath: setupAppURL.path) {
            try? fileManager.removeItem(at: setupAppURL)
        }
        installed = false
        launchAtLogin = false
        status = nil
        NSApp.terminate(nil)
    }

    // MARK: Process helpers

    struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) -> ProcessResult {
        Self.runTool(launchPath, arguments)
    }

    nonisolated private static func runTool(_ launchPath: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output)
    }

    private func removeQuarantine(from url: URL) {
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }
}
