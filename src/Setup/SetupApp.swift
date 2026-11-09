import AppKit
import Combine
import SwiftUI

@main
struct DockMiddleQuitSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            SetupRootView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = SnapshotSupport.appearance {
            NSApp.appearance = appearance
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.title = "DockMiddleQuit Setup"
                window.center()
            }
        }

        if let snapshotPath = SnapshotSupport.outputPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.writeSnapshot(to: snapshotPath)
                NSApp.terminate(nil)
            }
        }
    }

    private func writeSnapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first,
              let view = window.contentView else {
            fputs("No window to snapshot\n", stderr)
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fputs("Could not create snapshot bitmap\n", stderr)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("Could not encode snapshot\n", stderr)
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("Wrote snapshot to \(path)")
        } catch {
            fputs("Could not write snapshot: \(error)\n", stderr)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// Maintainer helper used for visual QA. It is inert unless the app is launched
// with `--snapshot <path>` and optionally `--preview-step <welcome|...>`.
enum SnapshotSupport {
    static var outputPath: String? {
        value(after: "--snapshot")
    }

    static var previewStep: SetupModel.Step? {
        guard let name = value(after: "--preview-step")?.lowercased() else { return nil }
        switch name {
        case "welcome": return .welcome
        case "permissions", "access": return .permissions
        case "login": return .login
        case "done", "ready": return .done
        default: return nil
        }
    }

    static var appearance: NSAppearance? {
        guard let name = value(after: "--appearance")?.lowercased() else { return nil }
        return NSAppearance(named: name == "light" ? .aqua : .darkAqua)
    }

    static var previewPermissionsMissing: Bool {
        value(after: "--preview-permissions")?.lowercased() == "missing"
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.index(after: index) < CommandLine.arguments.endIndex else {
            return nil
        }
        return CommandLine.arguments[CommandLine.arguments.index(after: index)]
    }
}

struct SetupRootView: View {
    @StateObject private var model = SetupModel()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .frame(width: SetupStyle.windowWidth, height: SetupStyle.windowHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Run Setup Again") { model.step = .welcome }
                        if model.installed {
                            Button("Reinstall DockMiddleQuit…") {
                                model.step = .welcome
                                Task { await model.install() }
                            }
                        }
                        Divider()
                        Button("Open Log") { model.openLog() }
                            .disabled(!model.installed)
                        Button("Show DockMiddleQuit in Finder") { model.revealApp() }
                            .disabled(!model.installed)
                        Divider()
                        Button("Uninstall DockMiddleQuit…") {
                            model.showUninstallConfirmation = true
                        }
                        .disabled(!model.installed)
                        Button("Quit Setup") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .disabled(model.busy)
                    .help("DockMiddleQuit options")
                }
            }
            .onAppear {
                model.bootstrap()
                if let previewStep = SnapshotSupport.previewStep {
                    model.step = previewStep
                }
                if SnapshotSupport.previewPermissionsMissing {
                    model.status = DaemonStatus(
                        version: nil,
                        accessibility: false,
                        inputMonitoring: false,
                        eventTapActive: false,
                        middleClickEmulation: false,
                        middleClickEnabled: false,
                        middleClickFingers: 3,
                        updatedAt: Date()
                    )
                }
            }
            .onReceive(timer) { _ in
                guard SnapshotSupport.outputPath == nil else { return }
                model.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard SnapshotSupport.outputPath == nil else { return }
                model.refresh()
            }
            .alert("Uninstall DockMiddleQuit?", isPresented: $model.showUninstallConfirmation) {
                Button("Uninstall", role: .destructive) {
                    Task { await model.uninstall() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the app, the login item, helper files, and its privacy permissions. You can reinstall anytime.")
            }
            .alert("Something went wrong", isPresented: errorBinding) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            WelcomeView(model: model)
        case .permissions:
            PermissionsView(model: model)
        case .login:
            LoginView(model: model)
        case .done:
            DoneView(model: model)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: SetupStyle.iconSize, height: SetupStyle.iconSize)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("DockMiddleQuit")
                                .font(.title.weight(.semibold))
                            Text("Quit Dock apps and close browser tabs with a middle click.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Setup installs a small background service in your user folder and helps you turn on the permissions macOS requires.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Installs in your home folder", systemImage: "folder")
                            Label("Asks for Accessibility and Input Monitoring", systemImage: "lock.shield")
                            Label("Starts automatically when you log in", systemImage: "power")
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }

                    if model.installed {
                        Notice(text: "DockMiddleQuit is already installed. Continue to review its permissions.")
                    } else if model.hadLegacyInstall {
                        Notice(
                            text: "An older copy in /Applications will be moved to the Trash.",
                            kind: .warning
                        )
                    }
                }
                .padding(SetupStyle.padding)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button("Quit") { NSApp.terminate(nil) }
                    .disabled(model.busy)

                Spacer()

                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.installPhase.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(model.installed ? "Continue" : "Install") {
                        if model.installed {
                            model.goNext()
                        } else {
                            Task { await model.install() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StepHeader(
                        title: "Permissions",
                        subtitle: "macOS asks for your approval before DockMiddleQuit can see Dock clicks."
                    )

                    if !model.serviceRunning {
                        Notice(
                            text: model.launchAtLogin
                                ? "The background service isn't running."
                                : "DockMiddleQuit isn't running because Launch at Login is off.",
                            kind: .warning,
                            actionTitle: model.launchAtLogin ? "Restart" : "Login",
                            action: {
                                if model.launchAtLogin {
                                    model.restartService()
                                } else {
                                    model.step = .login
                                }
                            }
                        )
                    }

                    if let info = model.infoMessage {
                        Notice(text: info)
                    }

                    GroupBox {
                        VStack(spacing: 12) {
                            PermissionRow(
                                kind: .accessibility,
                                granted: model.accessibilityGranted,
                                waiting: model.requestedPermission == .accessibility,
                                onGrant: { model.requestPermission(.accessibility) },
                                onOpenSettings: { model.openPermissionSettings(.accessibility) },
                                onReset: { model.resetPermission(.accessibility) }
                            )

                            Divider()

                            PermissionRow(
                                kind: .inputMonitoring,
                                granted: model.inputMonitoringGranted,
                                waiting: model.requestedPermission == .inputMonitoring,
                                onGrant: { model.requestPermission(.inputMonitoring) },
                                onOpenSettings: { model.openPermissionSettings(.inputMonitoring) },
                                onReset: { model.resetPermission(.inputMonitoring) }
                            )
                        }
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 8) {
                        Text("Status updates automatically when you return from System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Again") { model.refresh() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
                .padding(SetupStyle.padding)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button("Back") { model.goBack() }

                Spacer()

                if !model.accessibilityGranted {
                    Text("Accessibility can be granted later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(model.accessibilityGranted ? "Continue" : "Continue Anyway") {
                    model.goNext()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct PermissionRow: View {
    let kind: SetupModel.PermissionKind
    let granted: Bool
    let waiting: Bool
    let onGrant: () -> Void
    let onOpenSettings: () -> Void
    let onReset: () -> Void

    private var statusKind: StatusLabel.Kind {
        if granted { return .granted }
        return kind.isRequired ? .required : .optional
    }

    private var statusText: String {
        if granted { return "Granted" }
        return kind.isRequired ? "Required" : "Optional"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(kind.displayName)
                        .font(.headline)
                    Spacer()
                    StatusLabel(text: statusText, kind: statusKind)
                }

                Text(kind.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !granted {
                    HStack(spacing: 8) {
                        Button(waiting ? "Waiting…" : "Grant Access", action: onGrant)
                            .disabled(waiting)
                        Button("Settings", action: onOpenSettings)
                        Button("Reset", action: onReset)
                            .buttonStyle(.link)
                            .help("Clear a stale macOS permission record, then grant access again.")
                        Spacer()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StepHeader(
                        title: "Launch at Login",
                        subtitle: "DockMiddleQuit needs to keep running to catch middle clicks."
                    )

                    if let info = model.infoMessage {
                        Notice(text: info)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Start DockMiddleQuit when I log in", isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                            .toggleStyle(.checkbox)

                            Text("Runs quietly in the background and restarts if it stops.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Divider()

                            HStack(spacing: 8) {
                                StatusLabel(
                                    text: model.serviceRunning ? "Background service running" : "Background service stopped",
                                    kind: model.serviceRunning ? .granted : .problem
                                )
                                Spacer()
                                Button("Restart") { model.restartService() }
                                    .controlSize(.small)
                                    .disabled(!model.launchAtLogin)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if !model.launchAtLogin {
                        Notice(
                            text: "DockMiddleQuit won't run in the background until you turn this on.",
                            kind: .warning
                        )
                    }

                    if model.middleClickAppRunning {
                        Notice(
                            text: "MiddleClick is still running. Quit it so one three-finger gesture does not send two middle clicks.",
                            kind: .warning,
                            actionTitle: "Quit MiddleClick",
                            action: { model.quitMiddleClick() }
                        )
                    }

                    if model.legacyLoginItemPresent {
                        Notice(
                            text: "macOS still lists the old DockMiddleQuit login item. Remove it in Login Items to avoid a duplicate launch.",
                            kind: .warning,
                            actionTitle: "Login Items",
                            action: { model.openLoginItemsSettings() }
                        )
                    }
                }
                .padding(SetupStyle.padding)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button("Back") { model.goBack() }
                Spacer()
                Button("Continue") { model.goNext() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Done

struct DoneView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        StepHeader(
                            title: "Setup Complete",
                            subtitle: "Middle-click any Dock icon to quit its app. Middle-click a browser tab to close it."
                        )
                    }

                    if !model.accessibilityGranted {
                        Notice(
                            text: "Accessibility is still off, so DockMiddleQuit can't see Dock icons yet.",
                            kind: .warning,
                            actionTitle: "Fix",
                            action: { model.step = .permissions }
                        )
                    } else if !model.serviceRunning {
                        Notice(
                            text: "The background service is stopped.",
                            kind: .warning,
                            actionTitle: "Manage",
                            action: { model.step = .login }
                        )
                    }

                    if model.legacyLoginItemPresent {
                        Notice(
                            text: "macOS still lists the old DockMiddleQuit login item. Remove it in Login Items to avoid a duplicate launch.",
                            kind: .warning,
                            actionTitle: "Login Items",
                            action: { model.openLoginItemsSettings() }
                        )
                    }

                    if model.middleClickAppRunning {
                        Notice(
                            text: "MiddleClick is still running and will add a second middle click to each gesture.",
                            kind: .warning,
                            actionTitle: "Quit MiddleClick",
                            action: { model.quitMiddleClick() }
                        )
                    }

                    GroupBox {
                        VStack(spacing: 10) {
                            SummaryRow(
                                title: "Accessibility",
                                value: model.accessibilityGranted ? "Granted" : "Needs approval",
                                kind: model.accessibilityGranted ? .granted : .required
                            )
                            Divider()
                            SummaryRow(
                                title: "Input Monitoring",
                                value: model.inputMonitoringGranted ? "Granted" : "Not granted",
                                kind: model.inputMonitoringGranted ? .granted : .optional
                            )
                            Divider()
                            SummaryRow(
                                title: "Three-finger middle click",
                                value: model.middleClickEmulationActive
                                    ? "On (\(model.middleClickFingers) fingers)"
                                    : (model.middleClickConfigured ? "Unavailable" : "Off"),
                                kind: model.middleClickEmulationActive ? .granted : .optional
                            )
                            Divider()
                            SummaryRow(
                                title: "Launch at Login",
                                value: model.launchAtLogin ? "On" : "Off",
                                kind: model.launchAtLogin ? .granted : .optional
                            )
                            Divider()
                            SummaryRow(
                                title: "Background Service",
                                value: model.serviceRunning ? "Running" : "Stopped",
                                kind: model.serviceRunning ? .granted : .problem
                            )
                        }
                        .padding(.vertical, 2)
                    }

                    Text("You can reopen DockMiddleQuit Setup from your Applications folder anytime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(SetupStyle.padding)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button("Open Log") { model.openLog() }
                    .disabled(!model.installed)
                Spacer()
                Button("Done") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
