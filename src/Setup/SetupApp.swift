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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = SnapshotSupport.appearance {
            NSApp.appearance = appearance
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.delegate = self
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !SetupActivity.shared.isBusy else {
            NSSound.beep()
            return .terminateCancel
        }
        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !SetupActivity.shared.isBusy else {
            NSSound.beep()
            return false
        }
        return true
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
        case "install": return .install
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
                        updatedAt: Date(),
                        pid: nil
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
        case .install:
            InstallView(model: model)
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
                    StepProgress(current: .welcome)

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

                    if model.hadLegacyInstall {
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
                Spacer()

                Button {
                    model.beginInstall()
                } label: {
                    ActionLabel(title: "Install", systemName: "arrow.down.to.line")
                }
                .buttonStyle(SetupButtonStyle(prominent: true))
                .disabled(model.busy)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Install

struct InstallView: View {
    @ObservedObject var model: SetupModel

    /// A revisited Install step shows a completed checklist even when this
    /// launch skipped the progress because UXTapFix was already installed.
    private var displayedPhase: SetupModel.InstallPhase {
        model.installed && !model.busy ? .finished : model.installPhase
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SetupStyle.sectionSpacing) {
                    StepHeader(
                        step: .install,
                        title: "Install",
                        subtitle: "UXTapFix is copied to your user Applications folder and started automatically when you log in. No admin password is required."
                    )

                    InstallProgressCard(phase: displayedPhase)

                    if model.installFailed && !model.busy {
                        Notice(
                            text: "UXTapFix wasn't installed. Try again to retry the installation.",
                            kind: .warning
                        )
                    }

                    if model.hadLegacyInstall {
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
                    model.goBack()
                } label: {
                    ActionLabel(title: "Back", systemName: "chevron.left")
                }
                .buttonStyle(SetupButtonStyle())
                .disabled(model.busy)

                Spacer()

                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing…")
                            .font(SetupFont.body)
                            .foregroundStyle(.secondary)
                    }
                } else if model.installed {
                    Button {
                        model.goNext()
                    } label: {
                        ActionLabel(title: "Next", systemName: "arrow.right", iconAfter: true)
                    }
                    .buttonStyle(SetupButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        model.beginInstall()
                    } label: {
                        ActionLabel(
                            title: model.installFailed ? "Try Again" : "Install",
                            systemName: "arrow.down.to.line"
                        )
                    }
                    .buttonStyle(SetupButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Install progress

private let installSteps: [SetupModel.InstallPhase] = [
    .copying,
    .registering,
    .stopping,
    .starting,
    .finished
]

private struct InstallProgressCard: View {
    let phase: SetupModel.InstallPhase

    private var activeIndex: Int {
        installSteps.firstIndex(of: phase) ?? installSteps.count
    }

    var body: some View {
        SetupCard(padding: SetupStyle.cardPadding) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Installing UXTapFix")
                    .font(SetupFont.headline)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(installSteps.indices, id: \.self) { index in
                        InstallProgressRow(
                            title: installSteps[index].label,
                            state: state(for: index)
                        )
                    }
                }
            }
            .frame(minHeight: SetupStyle.previewStageHeight + 20, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Installation progress"))
    }

    private func state(for index: Int) -> InstallProgressRow.State {
        if phase == .finished { return .done }
        if index < activeIndex { return .done }
        if index == activeIndex { return .current }
        return .pending
    }
}

private struct InstallProgressRow: View {
    enum State {
        case done
        case current
        case pending

        var icon: String {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .current: return "circle.inset.filled"
            case .pending: return "circle"
            }
        }

        var tint: Color {
            switch self {
            case .done, .current: return SetupColors.accent
            case .pending: return Color.secondary.opacity(0.5)
            }
        }
    }

    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: state.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.tint)
                .frame(width: 16)

            Text(state == .current ? "\(title)…" : title)
                .font(state == .current ? .system(size: 14, weight: .semibold) : SetupFont.body)
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        switch state {
        case .done: return "\(title), done"
        case .current: return "\(title), in progress"
        case .pending: return "\(title), waiting"
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
                        step: .permissions,
                        title: "Setup",
                        subtitle: "macOS asks for Accessibility before UXTapFix can see Dock clicks. Setup can't continue until it is granted."
                    )

                    if model.launchAtLogin && !model.serviceRunning {
                        Notice(
                            text: "The background service isn't running.",
                            kind: .warning,
                            actionTitle: "Restart",
                            action: { model.restartService() }
                        )
                    }

                    if model.middleClickAppRunning {
                        Notice(
                            text: "MiddleClick is still running. Quit it so one three-finger tap does not fire twice.",
                            kind: .warning,
                            actionTitle: "Quit MiddleClick",
                            action: { model.quitMiddleClick() }
                        )
                    }

                    SetupCard(
                        padding: SetupStyle.cardPadding,
                        tint: model.accessibilityGranted ? nil : .orange
                    ) {
                        PermissionRow(
                            kind: .accessibility,
                            granted: model.accessibilityGranted,
                            waiting: model.permissionRequestBusy,
                            onGrant: { model.requestPermission(.accessibility) }
                        )
                    }

                    SetupCard(padding: SetupStyle.cardPadding) {
                        HStack(spacing: SetupStyle.itemSpacing) {
                            IconTile(systemName: "power", tint: model.launchAtLogin ? SetupColors.accent : .secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("Start UXTapFix when I log in")
                                        .font(SetupFont.headline)

                                    if model.launchAtLogin {
                                        StatusLabel(text: "Opens on login", kind: .granted)
                                            .transition(.opacity)
                                    }
                                }
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
                            .opacity(model.launchAtLoginBusy ? 0 : 1)
                            .disabled(model.launchAtLoginBusy)
                            .overlay {
                                if model.launchAtLoginBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                        .allowsHitTesting(false)
                                        .accessibilityLabel("Updating launch at login")
                                }
                            }
                        }
                        .frame(minHeight: SetupStyle.rowMinHeight)
                        .animation(.easeInOut(duration: 0.18), value: model.launchAtLogin)
                        .animation(.easeInOut(duration: 0.15), value: model.launchAtLoginBusy)
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

                if !model.accessibilityGranted {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Grant Accessibility to continue")
                            .font(SetupFont.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }

                Button {
                    model.goNext()
                } label: {
                    ActionLabel(title: "Next", systemName: "arrow.right", iconAfter: true)
                }
                .buttonStyle(SetupButtonStyle(prominent: true))
                .disabled(!model.accessibilityGranted)
                .help(model.accessibilityGranted ? "" : "Grant Accessibility access to continue.")
                .keyboardShortcut(.defaultAction)
            }
            .animation(.easeInOut(duration: 0.18), value: model.accessibilityGranted)
        }
    }
}

struct PermissionRow: View {
    let kind: SetupModel.PermissionKind
    let granted: Bool
    let waiting: Bool
    let onGrant: () -> Void

    private var statusKind: StatusLabel.Kind {
        granted ? .granted : .required
    }

    private var statusText: String {
        granted ? "Granted" : "Required"
    }

    private var tint: Color {
        granted ? SetupColors.accent : .orange
    }

    var body: some View {
        HStack(alignment: .center, spacing: SetupStyle.itemSpacing) {
            IconTile(systemName: kind.icon, tint: tint)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(kind.displayName)
                        .font(SetupFont.headline)

                    StatusLabel(text: statusText, kind: statusKind)
                }

                Text(kind.summary)
                    .font(SetupFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !granted {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint)
                        Text("In System Settings, turn on UXTapFix under Privacy & Security → Accessibility.")
                            .font(SetupFont.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 12)

            if !granted {
                Button(action: onGrant) {
                    HStack(spacing: 6) {
                        Image(systemName: waiting ? "clock" : "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .semibold))
                        Text(waiting ? "Waiting for approval…" : "Open System Settings")
                    }
                }
                .buttonStyle(SetupButtonStyle(prominent: true))
                .disabled(waiting)
            }
        }
        .frame(minHeight: SetupStyle.rowMinHeight)
        .animation(.easeInOut(duration: 0.18), value: granted)
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
                        step: .finish,
                        title: "Finish",
                        subtitle: "Everything is set up. Try the gestures below, then click Finish to close Setup."
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
                                TipRow(symbol: "square.grid.2x2", text: "Tap a Dock icon with three fingers to quit the app.")
                                TipRow(symbol: "bolt.fill", text: "Triple-click/tap to force quit immediately.")
                                TipRow(symbol: "terminal", text: "Tap in Terminal with three fingers to paste the selection.")
                            }
                        }
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
                    ActionLabel(title: "Finish", systemName: "checkmark", iconAfter: true)
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
