import AppKit
import Combine
import Darwin
import Foundation

/// Tracks work that must not be interrupted by closing the Setup window.
@MainActor
final class SetupActivity {
    static let shared = SetupActivity()

    private var workCount = 0
    var isBusy: Bool { workCount > 0 }

    func begin() { workCount += 1 }
    func end() { workCount = max(0, workCount - 1) }
}

// MARK: - Status file written by the daemon

struct DaemonStatus {
    let accessibility: Bool
    let inputMonitoring: Bool
    let updatedAt: Date
    let pid: pid_t?

    var isFresh: Bool {
        Date().timeIntervalSince(updatedAt) < 8
    }

    var isAlive: Bool {
        guard let pid, pid > 0 else { return false }
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
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
            accessibility: (object["accessibility"] as? Bool) ?? false,
            inputMonitoring: (object["inputMonitoring"] as? Bool) ?? false,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            pid: (object["pid"] as? NSNumber)?.int32Value
        )
    }
}

// MARK: - Installer model

@MainActor
final class SetupModel: ObservableObject {
    enum Step: CaseIterable, Equatable {
        case welcome
        case install
        case permissions
        case finish
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
            case .copying: return "Copying UXTapFix.app"
            case .registering: return "Adding the login item"
            case .starting: return "Starting the background service"
            case .finished: return "Installed"
            }
        }
    }

    enum PermissionKind {
        case accessibility

        var settingsURL: String {
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }

        var requestArgument: String { "--request-accessibility" }

        var displayName: String { "Accessibility" }

        /// Service name accepted by `tccutil reset`. Accessibility only.
        /// ListenEvent is never reset: an ad-hoc build cannot add itself back.
        var tccService: String { "Accessibility" }

        var icon: String { "accessibility" }

        var summary: String { "See the Dock icon, Mission Control window, or Calendar event under the pointer." }
    }

    struct InstallerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published var step: Step = .welcome
    @Published var installed = false
    @Published var launchAtLogin = false
    @Published var status: DaemonStatus?
    @Published var busy = false
    @Published var installPhase: InstallPhase = .idle
    @Published var installFailed = false
    @Published var errorMessage: String?
    /// True only while System Settings is being opened. It does not stay on
    /// until macOS reports a grant, so a stale switch can be cleared again.
    @Published var permissionRequestBusy = false
    @Published var restartingService = false
    /// True while the launch-at-login toggle is writing the login item and
    /// starting or stopping the service. The toggle shows a spinner meanwhile.
    @Published var launchAtLoginBusy = false
    @Published var hadLegacyInstall = false
    @Published var legacyLoginItemPresent = false
    @Published var middleClickAppRunning = false

    private let fileManager = FileManager.default
    private var didBootstrap = false
    private var hasPermissionBaseline = false
    private var previousAccessibility = false
    private var previousInputMonitoring = false
    private var isCheckingLegacyLoginItem = false
    private var legacyRetirement: Task<Void, Never>?

    let label = "com.user.uxtapfix"

    // MARK: Previous install cleanup
    //
    // The utility shipped under a different name before. Remove that install
    // during setup so two background services never run side by side. These
    // identifiers are used for cleanup only and are never shown in the UI.

    private let previousBundleIdentifier = "com.user.dockmiddlequit"
    private let previousAppName = "DockMiddleQuit"

    private var previousInstallURLs: [URL] {
        [
            URL(fileURLWithPath: "/Applications/\(previousAppName).app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/\(previousAppName) Setup.app", isDirectory: true),
            homeURL.appendingPathComponent("Applications/\(previousAppName).app", isDirectory: true),
            homeURL.appendingPathComponent("Applications/\(previousAppName) Setup.app", isDirectory: true),
            homeURL.appendingPathComponent("Library/LaunchAgents/\(previousBundleIdentifier).plist")
        ]
    }

    // MARK: Paths

    var homeURL: URL { fileManager.homeDirectoryForCurrentUser }

    var appURL: URL {
        homeURL.appendingPathComponent("Applications/UXTapFix.app", isDirectory: true)
    }

    var legacyAppURL: URL {
        URL(fileURLWithPath: "/Applications/UXTapFix.app", isDirectory: true)
    }

    var legacyInstalled: Bool {
        fileManager.fileExists(atPath: legacyAppURL.path)
    }

    var setupAppURL: URL {
        homeURL.appendingPathComponent("Applications/UXTapFix Setup.app", isDirectory: true)
    }

    var supportURL: URL {
        homeURL.appendingPathComponent("Library/Application Support/UXTapFix", isDirectory: true)
    }

    var launchAgentURL: URL {
        homeURL.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    var logURL: URL {
        homeURL.appendingPathComponent("Library/Logs/UXTapFix.log")
    }

    var statusURL: URL {
        supportURL.appendingPathComponent("status.json")
    }

    var daemonBinaryURL: URL {
        appURL.appendingPathComponent("Contents/MacOS/UXTapFix")
    }

    var domain: String { "gui/\(getuid())" }
    var domainLabel: String { "\(domain)/\(label)" }

    // MARK: Derived state

    var serviceRunning: Bool { status?.isFresh == true && status?.isAlive == true }
    var accessibilityGranted: Bool { status?.accessibility == true }

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
        if installed && legacyInstalled {
            Task { await retireLegacySystemCopy() }
        }
        guard installed else {
            step = .welcome
            return
        }
        step = .permissions
    }

    /// Moves a leftover `/Applications/UXTapFix.app` to the Trash without
    /// reinstalling the per-user copy. Safe to call more than once.
    func retireLegacySystemCopy() async {
        SetupActivity.shared.begin()
        defer { SetupActivity.shared.end() }
        if let existing = legacyRetirement {
            await existing.value
        }
        guard legacyInstalled else { return }
        let task = Task { @MainActor in
            await self.performLegacyRetirement()
        }
        legacyRetirement = task
        await task.value
    }

    func refresh() {
        installed = fileManager.fileExists(atPath: appURL.path)
        launchAtLogin = fileManager.fileExists(atPath: launchAgentURL.path)
        middleClickAppRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "art.ginzburg.MiddleClick")
            .isEmpty
        if let newStatus = DaemonStatus.read(from: statusURL) {
            status = newStatus
            detectPermissionChange(in: newStatus)
        } else if !fileManager.fileExists(atPath: statusURL.path) {
            status = nil
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
        guard (gainedAccessibility || gainedInputMonitoring), newStatus.isFresh, newStatus.isAlive, launchAtLogin, !restartingService else {
            return
        }

        restartingService = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = restartService()
            restartingService = false
        }
    }

    // MARK: Navigation

    func goNext() {
        switch step {
        case .welcome:
            beginInstall()
        case .install:
            step = .permissions
        case .permissions:
            // The footer button is disabled until macOS reports the grant;
            // guard here too so no other path can skip the permission.
            guard accessibilityGranted else { return }
            step = .finish
        case .finish:
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
        case .finish:
            step = .permissions
        }
    }

    // MARK: Install

    /// Shows the Install step and starts copying right away, so the checklist
    /// is what the user sees on the second screen.
    func beginInstall() {
        guard !busy else { return }
        installFailed = false
        installPhase = .copying
        step = .install
        Task { await install() }
    }

    func install() async {
        guard !busy else { return }
        busy = true
        SetupActivity.shared.begin()
        defer {
            busy = false
            SetupActivity.shared.end()
        }
        errorMessage = nil
        installFailed = false
        installPhase = .copying

        do {
            try rejectDowngrade()
            removePreviousInstall()
            try migrateLegacyInstall()

            // Build and verify the replacement while the old service keeps
            // running. Only the short stop/replace/start window is destructive.
            try await Task.sleep(nanoseconds: 180_000_000)
            let staged = try stagePayloadApp()
            defer { try? fileManager.removeItem(at: staged) }
            copySupportFiles()

            installPhase = .registering
            try await Task.sleep(nanoseconds: 180_000_000)
            try writeLaunchAgent()
            copySetupAppIfNeeded()

            installPhase = .stopping
            try await Task.sleep(nanoseconds: 180_000_000)
            _ = stopService()
            stopRunningDaemons()
            try installStagedApp(staged)

            installPhase = .starting
            try await Task.sleep(nanoseconds: 180_000_000)
            try startService()
            installPhase = .finished
            installed = true
            launchAtLogin = true

            await unregisterLegacyLoginItemIfNeeded()
            try await Task.sleep(nanoseconds: 650_000_000)
            refresh()
            _ = await waitForFreshStatus(timeout: 5.0)
            step = .permissions
        } catch {
            installPhase = .idle
            installFailed = true
            errorMessage = error.localizedDescription
            // Best effort: if the old app is still intact and launchd stopped
            // it, bring it back rather than leaving the user with no service.
            if fileManager.isExecutableFile(atPath: daemonBinaryURL.path) {
                try? startService()
            }
        }
    }

    private func rejectDowngrade() throws {
        guard let payloadURL = payloadAppURL,
              let payloadVersion = bundleVersion(at: payloadURL) else { return }
        for url in [appURL, legacyAppURL] {
            guard fileManager.fileExists(atPath: url.path),
                  let installedVersion = bundleVersion(at: url),
                  Self.isVersion(installedVersion, newerThan: payloadVersion) else { continue }
            throw InstallerError(message: "A newer copy of UXTapFix (\(installedVersion)) is already installed at \(url.path). This installer is version \(payloadVersion). Use the newer installer, or remove that copy first.")
        }
    }

    private func bundleVersion(at url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    nonisolated private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
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
        _ = run("/usr/bin/pkill", ["-x", "UXTapFix"])
        usleep(150_000)
    }

    private func removePreviousInstall() {
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(previousBundleIdentifier)"])
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: previousBundleIdentifier) {
            _ = app.terminate()
        }
        _ = run("/usr/bin/pkill", ["-x", previousAppName])

        for url in previousInstallURLs where fileManager.fileExists(atPath: url.path) {
            try? fileManager.trashItem(at: url, resultingItemURL: nil)
        }
        let previousSupportURL = homeURL
            .appendingPathComponent("Library/Application Support/\(previousAppName)", isDirectory: true)
        try? fileManager.removeItem(at: previousSupportURL)
        try? fileManager.removeItem(at: URL(fileURLWithPath: "/tmp/dock-middle-quit.log"))
    }

    private func migrateLegacyInstall() throws {
        hadLegacyInstall = legacyInstalled
        guard hadLegacyInstall else { return }
        stopProcesses(at: legacyAppURL)
        do {
            try fileManager.trashItem(at: legacyAppURL, resultingItemURL: nil)
        } catch {
            throw InstallerError(message: "An older copy of UXTapFix is in /Applications and couldn't be moved to the Trash. Remove it manually, then try again.\n\n\(error.localizedDescription)")
        }
    }

    private func performLegacyRetirement() async {
        guard legacyInstalled else { return }
        let repointAgent = launchAgentPointsAtLegacy()
            && fileManager.isExecutableFile(atPath: daemonBinaryURL.path)
        // KeepAlive would relaunch the copy we are about to trash.
        if repointAgent {
            _ = stopService()
        }
        do {
            try migrateLegacyInstall()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if repointAgent {
            do {
                try writeLaunchAgent()
                try startService()
                launchAtLogin = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await unregisterLegacyLoginItemIfNeeded()
        hadLegacyInstall = legacyInstalled
        refreshLegacyLoginItemStatus()
        refresh()
    }

    private func stopProcesses(at bundleURL: URL) {
        let legacyPath = bundleURL.standardizedFileURL.path
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: label)
        var stopped = false
        for app in running {
            let path = app.bundleURL?.standardizedFileURL.path ?? ""
            if path == legacyPath || path.hasPrefix(legacyPath + "/") {
                _ = app.terminate()
                stopped = true
            }
        }
        if stopped {
            usleep(350_000)
        }
    }

    private func launchAgentPointsAtLegacy() -> Bool {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let program = args.first else { return false }
        let legacyPath = legacyAppURL.standardizedFileURL.path
        return program == legacyPath || program.hasPrefix(legacyPath + "/")
    }

    private func refreshLegacyLoginItemStatus() {
        guard !isCheckingLegacyLoginItem else { return }
        // Skip the sfltool check when there is no legacy /Applications copy
        // to migrate — otherwise the macOS confirmation returns on every launch.
        guard fileManager.fileExists(atPath: legacyAppURL.path) else {
            legacyLoginItemPresent = false
            return
        }
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
        let legacyPath = "/Applications/UXTapFix.app"
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

    /// Copies and verifies the payload next to the installed app. The old app
    /// keeps running until `installStagedApp` performs the short swap.
    private func stagePayloadApp() throws -> URL {
        guard let payload = payloadAppURL else {
            throw InstallerError(message: "The installer is missing its UXTapFix.app payload. Rebuild the Setup app with ./build.sh and try again.")
        }
        let applications = appURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        if let leftovers = try? fileManager.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) {
            for leftover in leftovers where leftover.lastPathComponent.hasPrefix(".UXTapFix.app.staging-") {
                try? fileManager.removeItem(at: leftover)
            }
        }
        let staged = applications.appendingPathComponent(".UXTapFix.app.staging-\(UUID().uuidString)", isDirectory: true)

        do {
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.copyItem(at: payload, to: staged)
            removeQuarantine(from: staged)

            let executable = staged.appendingPathComponent("Contents/MacOS/UXTapFix")
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw InstallerError(message: "The copied app is missing its executable. Try rebuilding with ./build.sh.")
            }
            let verification = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            guard verification.status == 0 else {
                throw InstallerError(message: "The copied app failed code-signature verification.\n\n\(verification.output)")
            }
            return staged
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private func installStagedApp(_ staged: URL) throws {
        if fileManager.fileExists(atPath: appURL.path) {
            _ = try fileManager.replaceItemAt(appURL, withItemAt: staged, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: staged, to: appURL)
        }
        removeQuarantine(from: appURL)
        guard fileManager.isExecutableFile(atPath: daemonBinaryURL.path) else {
            throw InstallerError(message: "The installed app is missing its executable. Try again with a fresh build.")
        }
    }

    private var payloadAppURL: URL? {
        if let bundled = Bundle.main.url(forResource: "UXTapFix", withExtension: "app") {
            return bundled
        }
        // Development fallback: dist/UXTapFix Setup.app -> dist/UXTapFix.app
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("UXTapFix.app", isDirectory: true)
        return fileManager.fileExists(atPath: sibling.path) ? sibling : nil
    }

    private func copySupportFiles() {
        guard let resources = Bundle.main.resourceURL else { return }
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let source = resources.appendingPathComponent("UXTapFix.swift")
        if fileManager.fileExists(atPath: source.path) {
            try? fileManager.removeItem(at: supportURL.appendingPathComponent("UXTapFix.swift"))
            try? fileManager.copyItem(at: source, to: supportURL.appendingPathComponent("UXTapFix.swift"))
        }

        let headerSource = resources.appendingPathComponent("MultitouchSupport", isDirectory: true)
        if fileManager.fileExists(atPath: headerSource.path) {
            let destination = supportURL.appendingPathComponent("MultitouchSupport", isDirectory: true)
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: headerSource, to: destination)
        }

        let scripts = resources.appendingPathComponent("scripts", isDirectory: true)
        if fileManager.fileExists(atPath: scripts.path) {
            let contents = (try? fileManager.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil)) ?? []
            for file in contents where !file.hasDirectoryPath {
                let destination = supportURL.appendingPathComponent(file.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: file, to: destination)
                let permissions: Int = file.pathExtension == "sh" ? 0o755 : 0o644
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            }
        }
    }

    private func copySetupAppIfNeeded() {
        let runningPath = Bundle.main.bundleURL.standardizedFileURL
        let destination = setupAppURL.standardizedFileURL
        guard runningPath.path != destination.path else { return }
        if let installed = bundleVersion(at: destination),
           let running = bundleVersion(at: runningPath),
           Self.isVersion(installed, newerThan: running) {
            // Running an older DMG must not overwrite a newer installed Setup.
            return
        }

        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try? fileManager.copyItem(at: runningPath, to: destination)
        removeQuarantine(from: destination)
    }

    private func writeLaunchAgent() throws {
        try Self.writeLaunchAgent(
            label: label,
            launchAgentURL: launchAgentURL,
            logURL: logURL,
            daemonBinaryURL: daemonBinaryURL
        )
    }

    nonisolated private static func writeLaunchAgent(
        label: String,
        launchAgentURL: URL,
        logURL: URL,
        daemonBinaryURL: URL
    ) throws {
        let fileManager = FileManager.default
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
        try Self.startService(domain: domain, domainLabel: domainLabel, launchAgentURL: launchAgentURL)
    }

    nonisolated private static func startService(
        domain: String,
        domainLabel: String,
        launchAgentURL: URL
    ) throws {
        _ = runTool("/bin/launchctl", ["bootout", domainLabel])
        var result = runTool("/bin/launchctl", ["bootstrap", domain, launchAgentURL.path])
        if result.status != 0 {
            // A stopped service can occasionally still be registered for a moment.
            _ = runTool("/bin/launchctl", ["bootout", domainLabel])
            usleep(250_000)
            result = runTool("/bin/launchctl", ["bootstrap", domain, launchAgentURL.path])
        }
        guard result.status == 0 else {
            throw InstallerError(message: "macOS could not start the background service.\n\n\(result.output)\n\nTry again, or open the log for details.")
        }
        let kick = runTool("/bin/launchctl", ["kickstart", "-k", domainLabel])
        guard kick.status == 0 else {
            throw InstallerError(message: "The login item was added, but the service did not start.\n\n\(kick.output)")
        }
    }

    @discardableResult
    private func stopService() -> ProcessResult {
        run("/bin/launchctl", ["bootout", domainLabel])
    }

    @discardableResult
    func restartService() -> Bool {
        guard installed else { return false }
        do {
            if !fileManager.fileExists(atPath: launchAgentURL.path) {
                try writeLaunchAgent()
            }
            restartingService = true
            try startService()
            launchAtLogin = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                restartingService = false
                refresh()
            }
            return true
        } catch {
            restartingService = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func quitMiddleClick() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "art.ginzburg.MiddleClick")
        guard !running.isEmpty else {
            middleClickAppRunning = false
            return
        }
        for app in running {
            _ = app.terminate()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            refresh()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !launchAtLoginBusy else { return }
        errorMessage = nil
        launchAtLoginBusy = true
        SetupActivity.shared.begin()

        let label = label
        let domain = domain
        let domainLabel = domainLabel
        let launchAgentURL = launchAgentURL
        let logURL = logURL
        let daemonBinaryURL = daemonBinaryURL

        // launchctl can block for a moment, so keep it off the main thread and
        // let the toggle show a spinner until the login item is settled.
        Task.detached(priority: .userInitiated) {
            var failure: String?
            if enabled {
                do {
                    try Self.writeLaunchAgent(
                        label: label,
                        launchAgentURL: launchAgentURL,
                        logURL: logURL,
                        daemonBinaryURL: daemonBinaryURL
                    )
                    try Self.startService(
                        domain: domain,
                        domainLabel: domainLabel,
                        launchAgentURL: launchAgentURL
                    )
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                _ = Self.runTool("/bin/launchctl", ["bootout", domainLabel])
                try? FileManager.default.removeItem(at: launchAgentURL)
            }

            let failureMessage = failure
            await MainActor.run {
                if let failureMessage {
                    self.errorMessage = failureMessage
                }
                self.launchAtLogin = enabled
                self.refresh()
                self.launchAtLoginBusy = false
                SetupActivity.shared.end()
            }
        }
    }

    @discardableResult
    private func waitForFreshStatus(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status?.isFresh == true && status?.isAlive == true { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
            refresh()
        }
        return status?.isFresh == true && status?.isAlive == true
    }

    // MARK: Permissions

    func requestPermission(_ kind: PermissionKind) {
        guard installed, !permissionRequestBusy else { return }

        // Old installs (or ad-hoc rebuilds) can leave a stale TCC entry behind:
        // System Settings shows UXTapFix switched on, but the current app is
        // not actually trusted. Clear only the Accessibility record so macOS
        // adds the current app and shows a real grant prompt. Never reset
        // ListenEvent: that removes UXTapFix from the Input Monitoring pane,
        // and an ad-hoc build cannot reliably add itself back.
        //
        // The button is locked only while Settings is opening. It becomes
        // clickable again even if the grant has not landed, so this reset can
        // be repeated when the switch looks on but status stays off.
        if status?.isFresh == true && status?.isAlive == true {
            _ = run("/usr/bin/tccutil", ["reset", kind.tccService, label])
        }
        permissionRequestBusy = true
        openDaemon(arguments: [kind.requestArgument])
        let settingsURL = kind.settingsURL
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            openSettings(settingsURL)
            permissionRequestBusy = false
        }
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
        let appPath = appURL.path
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if error != nil {
                // Fallback for environments where the first launch request is
                // refused. Use LaunchServices (`open -n`) rather than executing
                // the binary directly, so TCC still sees the app bundle identity.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", appPath, "--args"] + arguments
                try? process.run()
            }
        }
    }

    private func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
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
        // Never let a stuck launchctl/sfltool/xattr hang Setup forever.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output)
    }

    private func removeQuarantine(from url: URL) {
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }
}
