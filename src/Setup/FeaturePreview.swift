import AppKit
import SwiftUI

// MARK: - Feature previews

/// The gestures the welcome screen demonstrates.
enum FeaturePreviewKind: String, CaseIterable, Identifiable {
    case quitDockApp
    case closeBrowserTab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quitDockApp: return "Quit a Dock app"
        case .closeBrowserTab: return "Close a browser tab"
        }
    }

    var caption: String {
        switch self {
        case .quitDockApp: return "Middle-click a Dock icon and the app quits."
        case .closeBrowserTab: return "Middle-click a browser tab and it closes."
        }
    }

    var hint: String {
        switch self {
        case .quitDockApp: return "Quit"
        case .closeBrowserTab: return "Close"
        }
    }

    var symbol: String {
        switch self {
        case .quitDockApp: return "square.grid.2x2"
        case .closeBrowserTab: return "macwindow"
        }
    }
}

/// Shared, time-based loop so both previews breathe in sync and the drawing
/// stays a pure function of elapsed time instead of scattered timers.
struct FeatureAnimationClock {
    static let loop: TimeInterval = 7.0

    struct Phase {
        var cursor: Double
        var ripple: Double
        var result: Double
    }

    static func phase(at date: Date) -> Phase {
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
        let reset = smoothstep(elapsed, from: loop - 0.8, to: loop)
        return Phase(
            cursor: smoothstep(elapsed, from: 1.6, to: 2.6) * (1 - reset),
            ripple: pulse(elapsed, from: 2.6, to: 3.4),
            result: smoothstep(elapsed, from: 3.1, to: 4.2) * (1 - reset)
        )
    }

    static func progress(_ elapsed: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> Double {
        guard end > start else { return elapsed >= end ? 1 : 0 }
        return min(max((elapsed - start) / (end - start), 0), 1)
    }

    static func smoothstep(_ elapsed: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> Double {
        let t = progress(elapsed, from: start, to: end)
        return t * t * (3 - 2 * t)
    }

    static func pulse(_ elapsed: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> Double {
        sin(progress(elapsed, from: start, to: end) * .pi)
    }
}

// MARK: - Welcome hero

struct WelcomeHero: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: SetupStyle.iconSize, height: SetupStyle.iconSize)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text("DockMiddleQuit")
                    .font(.title.weight(.semibold))
                Text("Middle-click to quit Dock apps and close browser tabs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SetupStyle.heroCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.accentColor.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: SetupStyle.heroCornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: - Preview card

struct FeaturePreviewCard: View {
    let kind: FeaturePreviewKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                Text(kind.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }

            FeatureAnimationStage(kind: kind)
                .frame(height: SetupStyle.previewStageHeight)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: SetupStyle.previewCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SetupStyle.previewCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )

            Text(kind.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SetupStyle.previewCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SetupStyle.previewCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(kind.title). \(kind.caption)"))
    }
}

// MARK: - Animated stage

struct FeatureAnimationStage: View {
    let kind: FeaturePreviewKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if reduceMotion {
                FeatureStillStage(kind: kind)
                    .frame(width: size.width, height: size.height)
            } else {
                TimelineView(.animation) { context in
                    scene(size: size, phase: FeatureAnimationClock.phase(at: context.date))
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(size: CGSize, phase: FeatureAnimationClock.Phase) -> some View {
        switch kind {
        case .quitDockApp:
            DockQuitScene(size: size, phase: phase)
        case .closeBrowserTab:
            BrowserTabScene(size: size, phase: phase)
        }
    }
}

private struct FeatureStillStage: View {
    let kind: FeaturePreviewKind

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: kind.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    )
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: 5, y: -5)
            }

            Text(kind.hint)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Pointer: View {
    let position: CGPoint
    var pressed: Bool = false

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(nsColor: .labelColor))
            .shadow(color: Color(nsColor: .textBackgroundColor).opacity(0.9), radius: 0.5)
            .shadow(color: Color(nsColor: .textBackgroundColor).opacity(0.9), radius: 2)
            .scaleEffect(pressed ? 0.88 : 1)
            .position(x: position.x, y: position.y)
    }
}

// MARK: - Dock preview

private struct DockQuitScene: View {
    let size: CGSize
    let phase: FeatureAnimationClock.Phase

    private let symbols = ["safari", "message.fill", "music.note", "envelope.fill"]
    private let targetIndex = 1

    var body: some View {
        let tile = min(max(size.height * 0.34, 20), 32)
        let gap = max(tile * 0.24, 5)
        let count = CGFloat(symbols.count)
        let stripWidth = count * tile + (count - 1) * gap
        let startX = max((size.width - stripWidth) / 2, gap)
        let stripY = size.height * 0.58
        let target = CGPoint(
            x: startX + CGFloat(targetIndex) * (tile + gap) + tile / 2,
            y: stripY + tile / 2
        )
        let resting = CGPoint(x: size.width * 0.78, y: size.height * 0.94)
        let travel = CGFloat(phase.cursor)
        let ripple = CGFloat(phase.ripple)
        let result = CGFloat(phase.result)
        let cursor = CGPoint(
            x: resting.x + (target.x - resting.x) * travel,
            y: resting.y + (target.y - resting.y) * travel
        )

        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.4, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: stripWidth + gap * 2, height: tile + gap * 1.6)
                .position(x: size.width / 2, y: stripY + tile / 2)

            ForEach(symbols.indices, id: \.self) { index in
                dockTile(
                    symbol: symbols[index],
                    index: index,
                    tile: tile,
                    gap: gap,
                    startX: startX,
                    stripY: stripY
                )
            }

            if phase.ripple > 0.01 {
                Circle()
                    .stroke(Color.accentColor.opacity(0.8 * (1 - phase.ripple)), lineWidth: 1.5)
                    .frame(width: tile + ripple * 26, height: tile + ripple * 26)
                    .position(target)
            }

            if phase.result > 0.01 {
                poofBurst(center: target, radius: 10 + result * 22)
            }

            if phase.result > 0.05 {
                Text("Quit")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .opacity(phase.result)
                    .position(x: target.x, y: max(target.y - tile * 1.7, 12))
            }

            Pointer(position: cursor, pressed: phase.ripple > 0.35 && phase.ripple < 0.8)
        }
        .frame(width: size.width, height: size.height)
    }

    private func dockTile(
        symbol: String,
        index: Int,
        tile: CGFloat,
        gap: CGFloat,
        startX: CGFloat,
        stripY: CGFloat
    ) -> some View {
        let isTarget = index == targetIndex
        let lift = CGFloat(isTarget ? phase.result : 0)
        let x = startX + CGFloat(index) * (tile + gap) + tile / 2

        return RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: tile * 0.5))
                    .foregroundStyle(Color.primary.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .frame(width: tile, height: tile)
            .scaleEffect(1 + lift * 0.3)
            .opacity(1 - lift)
            .position(x: x, y: stripY + tile / 2 - lift * 5)
    }

    private func poofBurst(center: CGPoint, radius: CGFloat) -> some View {
        ForEach(0..<6, id: \.self) { index in
            let angle = Double(index) / 6 * 2 * Double.pi
            Circle()
                .fill(Color.accentColor.opacity(0.6 * (1 - phase.result)))
                .frame(width: 3.5, height: 3.5)
                .position(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
        }
    }
}

// MARK: - Browser preview

private struct BrowserTabScene: View {
    let size: CGSize
    let phase: FeatureAnimationClock.Phase

    private let tabCount = 3
    private let targetIndex = 1
    private let tabGap: CGFloat = 3
    private let tabHeight: CGFloat = 15
    private let lineRatios: [CGFloat] = [0.86, 0.62, 0.74]

    var body: some View {
        let inset: CGFloat = 9
        let window = CGRect(
            x: inset,
            y: max(inset * 0.7, 5),
            width: max(size.width - inset * 2, 1),
            height: max(size.height - inset * 1.5, 1)
        )
        let stripX = window.minX + 8
        let stripY = window.minY + 18
        let stripWidth = max(window.width - 16, 1)
        let layout = tabLayout(stripWidth: stripWidth)
        let tabs = layout.widths
        let target = CGPoint(x: stripX + layout.centers[targetIndex], y: stripY + tabHeight / 2)
        let resting = CGPoint(x: size.width * 0.82, y: size.height * 0.94)
        let travel = CGFloat(phase.cursor)
        let ripple = CGFloat(phase.ripple)
        let cursor = CGPoint(
            x: resting.x + (target.x - resting.x) * travel,
            y: resting.y + (target.y - resting.y) * travel
        )

        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .frame(width: window.width, height: window.height)
                .position(x: window.midX, y: window.midY)

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 4, height: 4)
                }
            }
            .position(x: stripX + 12, y: stripY - 7)

            ForEach(0..<tabCount, id: \.self) { index in
                browserTab(width: tabs[index], isTarget: index == targetIndex)
                    .position(
                        x: stripX + layout.centers[index],
                        y: stripY + tabHeight / 2
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<lineRatios.count, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: (window.width - 32) * lineRatios[index], height: 5)
                }
            }
            .frame(width: window.width - 32, alignment: .leading)
            .position(
                x: window.minX + 16 + (window.width - 32) / 2,
                y: stripY + tabHeight + 18
            )

            if phase.ripple > 0.01 {
                Circle()
                    .stroke(Color.accentColor.opacity(0.8 * (1 - phase.ripple)), lineWidth: 1.5)
                    .frame(width: tabHeight + ripple * 26, height: tabHeight + ripple * 26)
                    .position(target)
            }

            if phase.result > 0.05 {
                Text("Close")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .opacity(phase.result)
                    .position(x: target.x, y: max(target.y + tabHeight * 2.8, 12))
            }

            Pointer(position: cursor, pressed: phase.ripple > 0.35 && phase.ripple < 0.8)
        }
        .frame(width: size.width, height: size.height)
    }

    private func tabLayout(stripWidth: CGFloat) -> (widths: [CGFloat], centers: [CGFloat]) {
        let available = max(stripWidth - CGFloat(tabCount - 1) * tabGap, 1)
        let base = available / CGFloat(tabCount)
        let closed = base * (1 - CGFloat(phase.result))
        let open = (available - closed) / CGFloat(tabCount - 1)
        let widths = [open, closed, open]

        var centers: [CGFloat] = []
        var offset: CGFloat = 0
        for width in widths {
            centers.append(offset + width / 2)
            offset += width + tabGap
        }

        return (widths, centers)
    }

    private func browserTab(width: CGFloat, isTarget: Bool) -> some View {
        let applied = max(width, 0.5)

        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(isTarget ? 0.14 : 0.07))
            .overlay(
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: max(applied * 0.45, 2), height: 2)
            )
            .frame(width: applied, height: tabHeight)
            .opacity(isTarget ? 1 - phase.result : 1)
    }
}
