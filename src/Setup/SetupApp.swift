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
        .windowStyle(.hiddenTitleBar)
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
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
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
// with `--snapshot <path>` and optionally `--preview-step <welcome|install|...>`.
enum SnapshotSupport {
    static var outputPath: String? {
        value(after: "--snapshot")
    }

    static var previewStep: SetupModel.Step? {
        guard let name = value(after: "--preview-step")?.lowercased() else { return nil }
        switch name {
        case "welcome": return .welcome
        case "install": return .install
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
        VStack(spacing: 0) {
            HeaderView(model: model)
            StepIndicator(current: model.step)
                .padding(.horizontal, 26)
            Divider()
                .opacity(0.55)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppBackground())
        .frame(width: 780, height: 620)
        .onAppear {
            model.bootstrap()
            if let previewStep = SnapshotSupport.previewStep {
                model.step = previewStep
            }
        }
        .onReceive(timer) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
        case .install:
            InstallView(model: model)
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

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("DockMiddleQuit")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.installed
                     ? "Version \(model.status?.version ?? model.setupVersion) · \(model.statusSummary)"
                     : "Setup Assistant")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.installed {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.serviceRunning ? Brand.green : Brand.amber)
                        .frame(width: 6, height: 6)
                    Text(model.serviceRunning ? "Running" : "Stopped")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(model.serviceRunning ? Brand.green : Brand.amber)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill((model.serviceRunning ? Brand.green : Brand.amber).opacity(0.10))
                }
            }

            Menu {
                Button("Run Setup Again") { model.step = .welcome }
                Button("Reinstall / Update…") { model.step = .install }
                Divider()
                Button("Open Log") { model.openLog() }
                    .disabled(!model.installed)
                Button("Reveal App in Finder") { model.revealApp() }
                    .disabled(!model.installed)
                Button("Reveal Setup in Finder") { model.revealSetupApp() }
                    .disabled(!model.installed)
                Divider()
                Button("Uninstall DockMiddleQuit…") {
                    model.showUninstallConfirmation = true
                }
                .disabled(!model.installed)
                Button("Quit Setup") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(Color.primary.opacity(0.06))
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 88)
        .padding(.trailing, 24)
        .padding(.top, 15)
        .padding(.bottom, 6)
    }
}

// MARK: - Shared footer

struct Footer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Divider().opacity(0.45)
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 21) {
                    HStack(alignment: .center, spacing: 26) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 102, height: 102)
                            .shadow(color: Brand.indigo.opacity(0.28), radius: 18, y: 9)

                        VStack(alignment: .leading, spacing: 9) {
                            Text(model.installed ? "DockMiddleQuit is ready." : "Quit apps straight from the Dock.")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.installed
                                 ? "Check permissions, change what happens at login, or try a middle-click."
                                 : "Middle-click any Dock icon to close its app. No right-click menus, no hunting for windows.")
                                .font(.system(size: 14.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    DockDemo()

                    HStack(spacing: 9) {
                        FeatureChip(icon: "cursorarrow.click.2", text: "Middle-click")
                        FeatureChip(icon: "hand.tap", text: "3-finger tap")
                        FeatureChip(icon: "lock.shield", text: "Stays on your Mac")
                    }

                    HStack(spacing: 0) {
                        NextStep(number: 1, title: "Install", detail: "Copy the app")
                        NextStepArrow()
                        NextStep(number: 2, title: "Allow", detail: "Turn on permissions")
                        NextStepArrow()
                        NextStep(number: 3, title: "Relax", detail: "It starts with your Mac")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            }
                    }

                    if model.installed {
                        Banner(
                            kind: .success,
                            text: "DockMiddleQuit is already installed. Continue to check permissions or reinstall."
                        )
                    }

                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
            }
            .scrollIndicators(.hidden)

            Footer {
                Text("Takes about a minute · No admin password")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.installed ? "Continue" : "Set up DockMiddleQuit") {
                    model.goNext()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

final class PulseModel: ObservableObject {
    @Published var value = false
}

struct DockDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pulse = PulseModel()

    private let apps: [(symbol: String, color: Color)] = [
        ("safari", Color(red: 0.24, green: 0.55, blue: 0.96)),
        ("envelope.fill", Color(red: 0.25, green: 0.72, blue: 0.92)),
        ("message.fill", Color(red: 0.18, green: 0.72, blue: 0.42)),
        ("music.note", Color(red: 0.91, green: 0.31, blue: 0.48)),
        ("photo.fill", Color(red: 0.96, green: 0.61, blue: 0.20)),
        ("terminal.fill", Color(red: 0.35, green: 0.37, blue: 0.41))
    ]
    private let clickedIndex = 3

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 13) {
                ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                    AppTile(symbol: app.symbol, color: app.color)
                        .opacity(index == clickedIndex ? 0.48 : 1)
                        .overlay {
                            if index == clickedIndex {
                                clickOverlay
                                    .offset(y: -18)
                            }
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.79))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.26), radius: 18, y: 10)
            }

            HStack(spacing: 7) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.blue)
                Text("Middle-click to quit")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Brand.softGradient)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.35).repeatForever(autoreverses: false)) {
                pulse.value = true
            }
        }
    }

    private var clickOverlay: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(pulse.value ? 0 : 0.62), lineWidth: 2)
                .frame(width: pulse.value ? 52 : 18, height: pulse.value ? 52 : 18)
            Image(systemName: "cursorarrow")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.42), radius: 4, y: 2)
                .offset(x: 19, y: 16)
        }
    }
}

struct NextStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(Brand.blue.opacity(0.78))
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct NextStepArrow: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.secondary.opacity(0.45))
            .padding(.horizontal, 8)
    }
}

struct AppTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.66)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 52, height: 52)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 6, y: 3)
    }
}

// MARK: - Install

struct InstallView: View {
    @ObservedObject var model: SetupModel

    private var copyDone: Bool {
        switch model.installPhase {
        case .registering, .starting, .finished: return true
        default: return model.installed && !model.busy
        }
    }

    private var registerDone: Bool {
        switch model.installPhase {
        case .starting, .finished: return true
        default: return model.installed && !model.busy
        }
    }

    private var startDone: Bool {
        model.installPhase == .finished || (model.installed && model.serviceRunning && !model.busy)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.installed ? "Update the installation." : "Install in a few seconds.")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("DockMiddleQuit lives in your user folder. No admin password, no system-wide changes.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }

                    if model.legacyInstalled {
                        Banner(
                            kind: .info,
                            text: "Older copy found at /Applications/DockMiddleQuit.app. Setup will move it to the Trash, then install the new version here."
                        )
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 13) {
                                IconBadge(icon: "folder.fill", tint: Brand.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Install location")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(model.appURL.path)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }

                            Divider().opacity(0.5)

                            InstallRow(
                                icon: "app.badge.fill",
                                title: "DockMiddleQuit.app",
                                detail: "The tiny background app. Under 100 KB.",
                                state: copyDone ? .done : (model.installPhase == .copying ? .working : .pending)
                            )
                            InstallRow(
                                icon: "arrow.clockwise.circle.fill",
                                title: "Login item",
                                detail: "A per-user LaunchAgent that starts it at login.",
                                state: registerDone ? .done : (model.installPhase == .registering ? .working : .pending)
                            )
                            InstallRow(
                                icon: "bolt.fill",
                                title: "Background service",
                                detail: "Listens for middle-clicks and restarts if it stops.",
                                state: startDone ? .done : (model.installPhase == .starting ? .working : .pending)
                            )
                        }
                    }

                    HStack(spacing: 10) {
                        InstallFact(icon: "lock.fill", text: "No admin password")
                        InstallFact(icon: "cloud.slash.fill", text: "No account or cloud")
                        InstallFact(icon: "trash.fill", text: "Uninstall anytime")
                    }

                    HStack(spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("The Setup app is copied to ~/Applications so you can reopen it anytime.")
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                    if model.installed {
                        Banner(
                            kind: .warning,
                            text: "Reinstalling replaces the app. macOS may ask you to re-approve Accessibility and Input Monitoring afterwards."
                        )
                    }

                    if model.busy {
                        Banner(kind: .info, text: model.installPhase.label + "…")
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)

            Footer {
                Button("Back") { model.goBack() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.busy)
                Spacer()
                if model.busy {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.installPhase.label + "…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(model.installed ? "Reinstall DockMiddleQuit" : "Install DockMiddleQuit") {
                        Task { await model.install() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct InstallFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.blue)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
                }
        }
    }
}

struct InstallRow: View {
    enum State {
        case pending
        case working
        case done
    }

    let icon: String
    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 28, height: 28)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.green)
                } else if state == .working {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(stateLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(state == .done ? Brand.green : Color.secondary)
        }
    }

    private var stateLabel: String {
        switch state {
        case .pending: return "Waiting"
        case .working: return "Working"
        case .done: return "Done"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .done: return Brand.green.opacity(0.12)
        case .working: return Brand.blue.opacity(0.10)
        case .pending: return Color.primary.opacity(0.05)
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
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Two permissions. One minute.")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("macOS keeps these switches under your control. We'll take you straight to the right place.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !model.serviceRunning {
                        Banner(
                            kind: .warning,
                            text: model.launchAtLogin
                                ? "The background service isn't running right now. Restart it to see live permission status."
                                : "Launch at Login is off, so DockMiddleQuit is stopped. Turn it on to use the app.",
                            actionTitle: model.launchAtLogin ? "Restart" : "Open Login",
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
                        Banner(kind: .success, text: info)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        PermissionCard(
                            title: "Accessibility",
                            icon: "accessibility",
                            tint: Brand.blue,
                            required: true,
                            granted: model.accessibilityGranted,
                            waiting: model.requestedPermission == .accessibility,
                            description: "Lets DockMiddleQuit ask macOS which Dock icon is under your pointer.",
                            steps: [
                                "Click Grant Access",
                                "Turn on DockMiddleQuit in Accessibility",
                                "Come back here — status updates live"
                            ],
                            onGrant: { model.requestPermission(.accessibility) },
                            onOpenSettings: { model.openPermissionSettings(.accessibility) },
                            onReset: { model.resetPermission(.accessibility) }
                        )

                        PermissionCard(
                            title: "Input Monitoring",
                            icon: "keyboard",
                            tint: Brand.indigo,
                            required: false,
                            granted: model.inputMonitoringGranted,
                            waiting: model.requestedPermission == .inputMonitoring,
                            description: "Catches the click before the Dock flashes its menu. Optional, but it feels smoother.",
                            steps: [
                                "Click Grant Access",
                                "Turn on DockMiddleQuit in Input Monitoring",
                                "Come back here — status updates live"
                            ],
                            onGrant: { model.requestPermission(.inputMonitoring) },
                            onOpenSettings: { model.openPermissionSettings(.inputMonitoring) },
                            onReset: { model.resetPermission(.inputMonitoring) }
                        )
                    }

                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(model.permissionStatusDetail)
                            .font(.system(size: 11.5))
                        Spacer()
                        Button("Check Again") { model.refresh() }
                            .buttonStyle(QuietButtonStyle())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)

            Footer {
                Button("Back") { model.goBack() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                if !model.accessibilityGranted {
                    Text("You can grant this later from the Setup app.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Button(model.accessibilityGranted ? "Continue" : "Continue anyway") {
                    model.goNext()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct PermissionCard: View {
    let title: String
    let icon: String
    let tint: Color
    let required: Bool
    let granted: Bool
    let waiting: Bool
    let description: String
    let steps: [String]
    let onGrant: () -> Void
    let onOpenSettings: () -> Void
    let onReset: () -> Void

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 11) {
                    IconBadge(icon: icon, tint: tint, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(required ? "Required" : "Recommended")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(required ? Brand.amber : tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background {
                                Capsule().fill((required ? Brand.amber : tint).opacity(0.11))
                            }
                    }
                    Spacer(minLength: 0)
                }

                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                StatusPill(
                    ok: granted,
                    okText: "Granted",
                    pendingText: waiting ? "Waiting for approval" : "Needs approval"
                )

                if granted {
                    Label("DockMiddleQuit has this permission.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 7) {
                                Text("\(index + 1)")
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(width: 14, height: 14)
                                    .background {
                                        Circle().fill(tint.opacity(0.75))
                                    }
                                Text(step)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if !granted {
                        Button(waiting ? "Waiting…" : "Grant Access", action: onGrant)
                            .buttonStyle(SmallPrimaryButtonStyle())
                            .disabled(waiting)
                    }
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(QuietButtonStyle())
                    if !granted {
                        Button("Reset", action: onReset)
                            .buttonStyle(QuietButtonStyle())
                            .help("Clear a stale macOS permission entry, then click Grant Access again.")
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 238, alignment: .topLeading)
        }
    }
}

struct SmallPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(
                    isEnabled
                        ? AnyShapeStyle(Brand.gradient)
                        : AnyShapeStyle(Color.secondary.opacity(0.28))
                )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Login

struct LoginView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Be ready when you log in.")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("DockMiddleQuit is most useful when it's already running. macOS can start it quietly in the background.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let info = model.infoMessage {
                        Banner(kind: .success, text: info)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 17) {
                            HStack(spacing: 13) {
                                IconBadge(icon: "power", tint: Brand.blue, size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Launch at login")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                    Text("Start DockMiddleQuit automatically and keep it running.")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { model.launchAtLogin },
                                    set: { model.setLaunchAtLogin($0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }

                            Divider().opacity(0.5)

                            HStack(spacing: 8) {
                                FlowStep(icon: "person.crop.circle.fill", label: "You log in")
                                FlowArrow()
                                FlowStep(icon: "gearshape.2.fill", label: "Starts quietly")
                                FlowArrow()
                                FlowStep(icon: "cursorarrow.click.2", label: "Ready to quit")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    HStack(spacing: 12) {
                        StatusTile(
                            icon: "bolt.fill",
                            tint: model.serviceRunning ? Brand.green : Brand.amber,
                            title: "Background service",
                            value: model.serviceRunning ? "Running" : "Stopped"
                        )
                        StatusTile(
                            icon: "clock.arrow.circlepath",
                            tint: Brand.blue,
                            title: "Last quit",
                            value: model.lastQuitDescription ?? "Nothing yet"
                        )
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Per-user LaunchAgent")
                                .font(.system(size: 11, weight: .semibold))
                            Text("~/Library/LaunchAgents/\(model.label).plist")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help("~/Library/LaunchAgents/\(model.label).plist")
                        }
                        Spacer()
                        Button("Login Items") { model.openLoginItemsSettings() }
                            .buttonStyle(QuietButtonStyle())
                        Button("Restart") { model.restartService() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(!model.launchAtLogin)
                        Button("Log") { model.openLog() }
                            .buttonStyle(QuietButtonStyle())
                    }
                    .padding(.horizontal, 4)

                    if !model.launchAtLogin {
                        Banner(
                            kind: .warning,
                            text: "Launch at Login is off. DockMiddleQuit won't be running when you log in until you turn it back on."
                        )
                    }

                    if model.legacyLoginItemPresent {
                        Banner(
                            kind: .warning,
                            text: "macOS still lists the old DockMiddleQuit login item. Remove it in Login Items to avoid a duplicate launch.",
                            actionTitle: "Login Items",
                            action: { model.openLoginItemsSettings() }
                        )
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)

            Footer {
                Button("Back") { model.goBack() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Continue") { model.goNext() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct FlowStep: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.blue)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(Brand.blue.opacity(0.09))
                }
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 92)
    }
}

struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.secondary.opacity(0.6))
    }
}

struct StatusTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(tint.opacity(0.10))
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
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
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(Brand.gradient)
                                .frame(width: 66, height: 66)
                                .shadow(color: Brand.blue.opacity(0.30), radius: 16, y: 7)
                            Image(systemName: "checkmark")
                                .font(.system(size: 27, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("You're ready to quit.")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("Middle-click an app icon in your Dock to close it. Try Calculator or Notes — they're easy to reopen.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !model.accessibilityGranted {
                        Banner(
                            kind: .warning,
                            text: "Accessibility is still off, so DockMiddleQuit can't see Dock icons yet.",
                            actionTitle: "Fix",
                            action: { model.step = .permissions }
                        )
                    } else if !model.serviceRunning {
                        Banner(
                            kind: .warning,
                            text: "The background service is stopped. Turn on Launch at Login or restart it.",
                            actionTitle: "Manage",
                            action: { model.step = .login }
                        )
                    }

                    if model.legacyLoginItemPresent {
                        Banner(
                            kind: .warning,
                            text: "macOS still lists the old DockMiddleQuit login item. Remove it in Login Items to avoid a duplicate launch.",
                            actionTitle: "Login Items",
                            action: { model.openLoginItemsSettings() }
                        )
                    }

                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            SummaryRow(
                                icon: "accessibility",
                                tint: Brand.blue,
                                title: "Accessibility",
                                detail: model.accessibilityGranted ? "Granted" : "Needs approval",
                                ok: model.accessibilityGranted,
                                actionTitle: model.accessibilityGranted ? nil : "Fix",
                                action: { model.step = .permissions }
                            )
                            SummaryDivider()
                            SummaryRow(
                                icon: "keyboard",
                                tint: Brand.indigo,
                                title: "Input Monitoring",
                                detail: model.inputMonitoringGranted ? "Granted" : "Optional — not granted",
                                ok: model.inputMonitoringGranted,
                                actionTitle: model.inputMonitoringGranted ? nil : "Review",
                                action: { model.step = .permissions }
                            )
                            SummaryDivider()
                            SummaryRow(
                                icon: "power",
                                tint: Brand.blue,
                                title: "Launch at login",
                                detail: model.launchAtLogin ? "On" : "Off",
                                ok: model.launchAtLogin,
                                actionTitle: "Manage",
                                action: { model.step = .login }
                            )
                            SummaryDivider()
                            SummaryRow(
                                icon: "bolt.fill",
                                tint: model.serviceRunning ? Brand.green : Brand.amber,
                                title: "Background service",
                                detail: model.serviceRunning ? "Running" : "Stopped",
                                ok: model.serviceRunning,
                                actionTitle: model.serviceRunning ? "Restart" : "Start",
                                action: {
                                    if model.launchAtLogin {
                                        model.restartService()
                                    } else {
                                        model.step = .login
                                    }
                                }
                            )
                        }
                    }

                    if let lastQuit = model.lastQuitDescription {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Brand.green)
                            Text("Last quit: \(lastQuit)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    Card(padding: 16) {
                        HStack(spacing: 13) {
                            IconBadge(icon: "hand.tap.fill", tint: Brand.indigo, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.middleClickInstalled
                                     ? (model.middleClickFingerCount.map { "\($0)-finger tap is ready" } ?? "Finish setting up MiddleClick")
                                     : "Want a 3-finger tap?")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(model.middleClickInstalled
                                     ? (model.middleClickFingerCount.map { "MiddleClick is installed and mapped to a \($0)-finger tap." }
                                        ?? "MiddleClick is installed. Open it to enable its tap gesture.")
                                     : "Install MiddleClick, a free utility that turns a three-finger tap into a middle click.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button(model.middleClickInstalled ? "Open MiddleClick" : "Get MiddleClick") {
                                model.openMiddleClick()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)

            Footer {
                Button("Open Log") { model.openLog() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Run Setup Again") { model.step = .welcome }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Done") { NSApp.terminate(nil) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct SummaryRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let ok: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            IconBadge(icon: icon, tint: tint, size: 30)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ok ? Brand.green : Brand.amber)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ok ? Brand.green : Brand.amber)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }
}

struct SummaryDivider: View {
    var body: some View {
        Divider()
            .opacity(0.45)
            .padding(.leading, 56)
    }
}
