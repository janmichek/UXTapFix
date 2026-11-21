import AppKit
import Combine
import SwiftUI

@main
struct UXTapFixSetupApp: App {
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
                window.title = "UXTapFix Setup"
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
            .background(SetupColors.canvas)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .keyboardShortcut("q")
                    .help("Quit Setup")
                }
            }
            .onAppear {
                model.bootstrap()
                if let previewStep = SnapshotSupport.previewStep {
                    model.step = previewStep
                }
                if SnapshotSupport.previewPermissionsMissing {
                    model.status = DaemonStatus(
                        accessibility: false,
                        inputMonitoring: false,
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
                VStack(alignment: .leading, spacing: SetupStyle.sectionSpacing) {
                    StepProgress(current: 0)

                    WelcomeHero()

                    HStack(alignment: .top, spacing: SetupStyle.itemSpacing) {
                        ForEach(FeaturePreviewKind.allCases) { kind in
                            FeaturePreviewCard(kind: kind)
                        }
                    }

                    Text("Setup installs a small background service in your user folder and helps you turn on the permissions macOS requires.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.installed {
                        Notice(text: "UXTapFix is already installed. Continue to review its permissions.")
                    } else if model.hadLegacyInstall {
                        Notice(
                            text: "An older copy in /Applications will be moved to the Trash.",
                            kind: .warning
                        )
                    }
                }
                .padding(SetupStyle.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .controlSize(.large)
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

    private var grantedCount: Int {
        [model.accessibilityGranted, model.inputMonitoringGranted].filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SetupStyle.sectionSpacing) {
                    StepHeader(
                        step: 1,
                        title: "Permissions",
                        subtitle: "macOS asks for your approval before UXTapFix can see Dock clicks."
                    )

                    if !model.serviceRunning {
                        Notice(
                            text: model.launchAtLogin
                                ? "The background service isn't running."
                                : "UXTapFix isn't running because Launch at Login is off.",
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

                    VStack(spacing: SetupStyle.itemSpacing) {
                        PermissionRow(
                            kind: .accessibility,
                            granted: model.accessibilityGranted,
                            waiting: model.requestedPermission == .accessibility,
                            onGrant: { model.requestPermission(.accessibility) }
                        )

                        PermissionRow(
                            kind: .inputMonitoring,
                            granted: model.inputMonitoringGranted,
                            waiting: model.requestedPermission == .inputMonitoring,
                            onGrant: { model.requestPermission(.inputMonitoring) }
                        )
                    }

                    Text("Status updates automatically when you return from System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(SetupStyle.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button("Back") { model.goBack() }

                Spacer()

                Text("\(grantedCount) of 2 granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)

                Button(model.accessibilityGranted ? "Continue" : "Continue Anyway") {
                    model.goNext()
                }
                .controlSize(.large)
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

    private var statusKind: StatusPill.Kind {
        if granted { return .granted }
        return kind.isRequired ? .required : .optional
    }

    private var statusText: String {
        if granted { return "Granted" }
        return kind.isRequired ? "Required" : "Optional"
    }

    var body: some View {
        SetupCard(padding: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: kind.icon)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(kind.displayName)
                            .font(.headline)
                        Spacer(minLength: 8)
                        StatusPill(text: statusText, kind: statusKind)
                    }

                    Text(kind.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !granted {
                        Button(action: onGrant) {
                            HStack(spacing: 5) {
                                Image(systemName: waiting ? "clock" : "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(waiting ? "Waiting for approval…" : "Open System Settings")
                            }
                        }
                        .controlSize(.small)
                        .disabled(waiting)
                        .padding(.top, 3)
                    }
                }
            }
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @ObservedObject var model: SetupModel

    private var grantedCount: Int {
        [model.accessibilityGranted, model.inputMonitoringGranted].filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SetupStyle.sectionSpacing) {
                    StepHeader(
                        step: 2,
                        title: "Launch at Login",
                        subtitle: "UXTapFix needs to keep running to catch middle clicks."
                    )

                    if let info = model.infoMessage {
                        Notice(text: info)
                    }

                    SetupCard(padding: 16) {
                        HStack(spacing: 14) {
                            IconTile(systemName: "power", tint: model.launchAtLogin ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Start UXTapFix when I log in")
                                    .font(.headline)
                                Text("Runs quietly in the background and restarts if it stops.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 12)

                            Toggle("Start UXTapFix when I log in", isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }

                    SetupCard(padding: 20) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                IconTile(systemName: "hand.tap", size: 30)
                                Text("Try it now")
                                    .font(.title3.weight(.semibold))
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                TipRow(symbol: "macwindow", text: "Tap a browser tab with three fingers to close it.")
                                TipRow(symbol: "square.grid.2x2", text: "Middle-click a Dock icon to quit the app.")
                                TipRow(symbol: "bolt", text: "Click the same icon again to force quit.")
                            }
                        }
                    }

                    if !model.launchAtLogin {
                        Notice(
                            text: "UXTapFix won't run in the background until you turn this on.",
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
                            text: "macOS still lists the old UXTapFix login item. Remove it in Login Items to avoid a duplicate launch.",
                            kind: .warning,
                            actionTitle: "Login Items",
                            action: { model.openLoginItemsSettings() }
                        )
                    }
                }
                .padding(SetupStyle.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button("Back") { model.goBack() }
                Spacer()
                Button("Finish") { model.goNext() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct TipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
