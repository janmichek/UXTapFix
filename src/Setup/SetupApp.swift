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
        .windowResizability(.contentMinSize)
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
                window.titlebarAppearsTransparent = true
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isEnabled = true
                window.collectionBehavior.insert(.fullScreenPrimary)
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
        case "permissions", "access", "login": return .permissions
        case "finish", "try": return .finish
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
            .frame(minWidth: SetupStyle.windowWidth, minHeight: SetupStyle.windowHeight)
            .background(SetupColors.canvas)
            .tint(SetupColors.accent)
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
        case .finish:
            FinishView(model: model)
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

                    Text("Setup installs a small background service and helps you grant the permissions macOS requires. Requires macOS 13+.")
                        .font(SetupFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.installed {
                        Notice(text: "UXTapFix is already installed. Choose Next to review its permissions.")
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
                Button {
                    NSApp.terminate(nil)
                } label: {
                    ActionLabel(title: "Close", systemName: "xmark")
                }
                .buttonStyle(SetupButtonStyle())
                .disabled(model.busy)

                Spacer()

                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.installPhase.label)
                            .font(SetupFont.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        if model.installed {
                            model.goNext()
                        } else {
                            Task { await model.install() }
                        }
                    } label: {
                        ActionLabel(
                            title: model.installed ? "Next" : "Install",
                            systemName: model.installed ? "arrow.right" : "arrow.down.to.line",
                            iconAfter: model.installed
                        )
                    }
                    .buttonStyle(SetupButtonStyle(prominent: true))
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
                VStack(alignment: .leading, spacing: SetupStyle.sectionSpacing) {
                    StepHeader(
                        step: 1,
                        title: "Permissions & Login",
                        subtitle: "macOS asks for Accessibility before UXTapFix can see Dock clicks. Input Monitoring comes with it."
                    )

                    if model.launchAtLogin && !model.serviceRunning {
                        Notice(
                            text: "The background service isn't running.",
                            kind: .warning,
                            actionTitle: "Restart",
                            action: { model.restartService() }
                        )
                    }

                    if let info = model.infoMessage {
                        Notice(text: info)
                    }

                    SetupCard(padding: SetupStyle.cardPadding) {
                        VStack(spacing: 0) {
                            PermissionRow(
                                kind: .accessibility,
                                granted: model.accessibilityGranted,
                                waiting: model.requestedPermission == .accessibility,
                                onGrant: { model.requestPermission(.accessibility) }
                            )

                            Divider()
                                .padding(.leading, SetupStyle.tileSize + SetupStyle.itemSpacing)

                            PermissionRow(
                                kind: .inputMonitoring,
                                granted: model.inputMonitoringGranted,
                                waiting: false,
                                note: model.accessibilityGranted
                                    ? "Included with Accessibility — no separate switch is needed."
                                    : "Grant Accessibility above; macOS includes Input Monitoring with it.",
                                showsAction: false,
                                onGrant: {}
                            )
                        }
                    }

                    SetupCard(padding: SetupStyle.cardPadding) {
                        HStack(spacing: SetupStyle.itemSpacing) {
                            IconTile(systemName: "power", tint: model.launchAtLogin ? SetupColors.accent : .secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Start UXTapFix when I log in")
                                    .font(SetupFont.headline)
                                Text("Runs quietly in the background and restarts if it stops.")
                                    .font(SetupFont.body)
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
                        .frame(minHeight: SetupStyle.rowMinHeight)
                    }

                    if !model.launchAtLogin {
                        Notice(
                            text: "UXTapFix won't keep running in the background until you turn this on.",
                            kind: .warning
                        )
                    }
                }
                .padding(SetupStyle.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            SetupFooter {
                Button {
                    model.goBack()
                } label: {
                    ActionLabel(title: "Back", systemName: "chevron.left")
                }
                .buttonStyle(SetupButtonStyle())

                Spacer()

                Button {
                    model.goNext()
                } label: {
                    ActionLabel(
                        title: model.accessibilityGranted ? "Next" : "Next Anyway",
                        systemName: "arrow.right",
                        iconAfter: true
                    )
                }
                .buttonStyle(SetupButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct PermissionRow: View {
    let kind: SetupModel.PermissionKind
    let granted: Bool
    let waiting: Bool
    var note: String?
    var showsAction = true
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
        HStack(alignment: .center, spacing: SetupStyle.itemSpacing) {
            IconTile(systemName: kind.icon)

            VStack(alignment: .leading, spacing: 6) {
                Text(kind.displayName)
                    .font(SetupFont.headline)

                Text(kind.summary)
                    .font(SetupFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note {
                    Text(note)
                        .font(SetupFont.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(text: statusText, kind: statusKind)

                if !granted && showsAction {
                    Button(action: onGrant) {
                        HStack(spacing: 6) {
                            Image(systemName: waiting ? "clock" : "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .semibold))
                            Text(waiting ? "Waiting for approval…" : "Open System Settings")
                        }
                    }
                    .buttonStyle(SetupButtonStyle())
                    .disabled(waiting)
                }
            }
        }
        .frame(minHeight: SetupStyle.rowMinHeight)
    }
}

// MARK: - Finish

struct FinishView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SetupStyle.sectionSpacing) {
                    StepHeader(
                        step: 2,
                        title: "Try",
                        subtitle: "Everything is set up. Try the gestures below, then click Try to close Setup."
                    )

                    if !model.accessibilityGranted {
                        Notice(
                            text: "Accessibility isn't granted yet, so UXTapFix can't catch Dock clicks.",
                            kind: .warning,
                            actionTitle: "Review",
                            action: { model.step = .permissions }
                        )
                    }

                    if !model.serviceRunning {
                        Notice(
                            text: model.launchAtLogin
                                ? "The background service isn't running."
                                : "Launch at Login is off. UXTapFix will stop when you close Setup.",
                            kind: .warning,
                            actionTitle: model.launchAtLogin ? "Restart" : "Turn On",
                            action: {
                                if model.launchAtLogin {
                                    model.restartService()
                                } else {
                                    model.setLaunchAtLogin(true)
                                }
                            }
                        )
                    }

                    SetupCard(padding: SetupStyle.cardPadding) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: SetupStyle.itemSpacing) {
                                IconTile(systemName: "hand.tap")
                                Text("Try it now")
                                    .font(SetupFont.headline)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                TipRow(symbol: "macwindow", text: "Tap a browser tab with three fingers to close it.")
                                TipRow(symbol: "link", text: "Tap a link with three fingers to open it in a new tab.")
                                TipRow(symbol: "square.grid.2x2", text: "Middle-click a Dock icon to quit the app.")
                                TipRow(symbol: "bolt", text: "Click again to quit the app's background helpers too.")
                                TipRow(symbol: "bolt.fill", text: "Click a third time to force quit immediately.")
                                TipRow(symbol: "terminal", text: "Middle-click in Terminal to paste the selection.")
                            }
                        }
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
                Button {
                    model.goBack()
                } label: {
                    ActionLabel(title: "Back", systemName: "chevron.left")
                }
                .buttonStyle(SetupButtonStyle())
                Spacer()
                Button {
                    model.goNext()
                } label: {
                    ActionLabel(title: "Try", systemName: "checkmark", iconAfter: true)
                }
                .buttonStyle(SetupButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct TipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(text)
                .font(SetupFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
