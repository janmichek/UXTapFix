import AppKit
import SwiftUI

// MARK: - Feature previews

/// The features the welcome screen demonstrates.
enum FeaturePreviewKind: String, CaseIterable, Identifiable {
    case threeFingerTap
    case quitDockApp
    case multiAction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeFingerTap: return "Three-finger tap"
        case .quitDockApp: return "Quit Dock apps"
        case .multiAction: return "Force quit"
        }
    }

    var caption: String {
        switch self {
        case .threeFingerTap:
            return "Three-finger tap and middle click are synced."
        case .quitDockApp:
            return "Middle-click a Dock icon and the app quits."
        case .multiAction:
            return "Click again to stop background helpers, then force quit."
        }
    }

    var hint: String {
        switch self {
        case .threeFingerTap: return "Middle click"
        case .quitDockApp: return "Quit"
        case .multiAction: return "Force quit"
        }
    }

    var symbol: String {
        switch self {
        case .threeFingerTap: return "hand.tap"
        case .quitDockApp: return "square.grid.2x2"
        case .multiAction: return "stop.fill"
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
        HStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: SetupStyle.iconSize, height: SetupStyle.iconSize)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.26))
                        .blur(radius: 18)
                )
                .shadow(color: .black.opacity(0.22), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text("UXTapFix")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.6)

                Text("Sync three tap and middle click controls")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            SyncGlyph()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroBackground)
        .overlay(heroBorder)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("UXTapFix. Sync three tap and middle click controls"))
    }

    private var heroBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SetupStyle.heroCornerRadius, style: .continuous)
                .fill(SetupColors.card)

            RoundedRectangle(cornerRadius: SetupStyle.heroCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.20),
                            Color.accentColor.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: SetupStyle.heroCornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(0.20),
                            Color.accentColor.opacity(0)
                        ],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 190
                    )
                )
        }
    }

    private var heroBorder: some View {
        RoundedRectangle(cornerRadius: SetupStyle.heroCornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.38),
                        Color.accentColor.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

/// Quiet, oversized "in sync" mark that balances the header.
private struct SyncGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1)
                .frame(width: 58, height: 58)

            Circle()
                .strokeBorder(Color.accentColor.opacity(0.09), lineWidth: 1)
                .frame(width: 40, height: 40)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.70))
        }
        .frame(width: 58, height: 58)
        .accessibilityHidden(true)
    }
}

// MARK: - Preview card

struct FeaturePreviewCard: View {
    let kind: FeaturePreviewKind

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(kind.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            FeatureAnimationStage(kind: kind)
                .frame(height: SetupStyle.previewStageHeight)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: SetupStyle.innerCornerRadius, style: .continuous)
                        .fill(SetupColors.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SetupStyle.innerCornerRadius, style: .continuous)
                        .strokeBorder(SetupColors.subtleBorder, lineWidth: 1)
                )

            Text(kind.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SetupStyle.cardCornerRadius, style: .continuous)
                .fill(SetupColors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SetupStyle.cardCornerRadius, style: .continuous)
                .strokeBorder(SetupColors.border, lineWidth: 1)
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
                    let phase = FeatureAnimationClock.phase(at: context.date)
                    scene(size: size, phase: phase, date: context.date)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(size: CGSize, phase: FeatureAnimationClock.Phase, date: Date) -> some View {
        switch kind {
        case .threeFingerTap:
            TrackpadTapScene(size: size, phase: phase)
        case .quitDockApp:
            DockQuitScene(size: size, phase: phase)
        case .multiAction:
            EscalationScene(size: size, date: date)
        }
    }
}

private struct FeatureStillStage: View {
    let kind: FeaturePreviewKind

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SetupColors.canvas)
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

private func poofBurst(center: CGPoint, radius: CGFloat, result: Double) -> some View {
    ForEach(0..<6, id: \.self) { index in
        let angle = Double(index) / 6 * 2 * Double.pi
        Circle()
            .fill(Color.accentColor.opacity(0.6 * (1 - result)))
            .frame(width: 3.5, height: 3.5)
            .position(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
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
                poofBurst(center: target, radius: 10 + result * 22, result: phase.result)
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

}

// MARK: - Three-finger tap preview

/// A simple mouse outline with a lit scroll wheel standing in for the middle button.
private struct MiddleMouseGlyph: View {
    let size: CGFloat
    let active: Bool

    var body: some View {
        let bodyWidth = size * 0.58
        let bodyHeight = size * 0.82

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: bodyWidth * 0.5, style: .continuous)
                .fill(SetupColors.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: bodyWidth * 0.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.32), lineWidth: 1)
                )
                .frame(width: bodyWidth, height: bodyHeight)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: bodyWidth, height: 1)
                .offset(y: bodyHeight * 0.36)

            Capsule()
                .fill(active ? Color.accentColor : Color.primary.opacity(0.40))
                .frame(width: max(size * 0.07, 2.5), height: bodyHeight * 0.22)
                .offset(y: bodyHeight * 0.13)
        }
        .frame(width: bodyWidth, height: bodyHeight)
    }
}

/// The three-finger tap and the middle mouse click shown as one synced action.
private struct TrackpadTapScene: View {
    let size: CGSize
    let phase: FeatureAnimationClock.Phase

    var body: some View {
        let travel = CGFloat(phase.cursor)
        let ripple = CGFloat(phase.ripple)
        let result = CGFloat(phase.result)
        // The three fingers depress while the gesture fires.
        let fingerPress = CGFloat(min(max((travel - 0.5) / 0.45, 0), 1))

        let item = min(size.width * 0.22, 36)
        let gap: CGFloat = max(size.width * 0.15, 26)
        let leftX = size.width / 2 - item / 2 - gap / 2
        let rightX = size.width / 2 + item / 2 + gap / 2
        let centerY = size.height * 0.36
        let fired = result > 0.05

        ZStack {
            // Left: three-finger tap
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .frame(width: item, height: item)
                .position(x: leftX, y: centerY)

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .scaleEffect(1 - fingerPress * 0.4, anchor: .center)
                    .position(
                        x: leftX - item * 0.22 + CGFloat(index) * 8,
                        y: centerY - item * 0.18
                    )
            }

            // Sync mark: the two inputs are the same click.
            Text("=")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor.opacity(fired ? 1 : 0.7))
                .position(x: size.width / 2, y: centerY)

            // Right: middle mouse button
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            fired ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.10),
                            lineWidth: 1
                        )
                )
                .frame(width: item, height: item)
                .position(x: rightX, y: centerY)

            MiddleMouseGlyph(size: item, active: fired)
                .position(x: rightX, y: centerY)

            if ripple > 0.01 {
                Circle()
                    .stroke(Color.accentColor.opacity(0.8 * (1 - ripple)), lineWidth: 1.5)
                    .frame(width: item + ripple * 26, height: item + ripple * 26)
                    .position(x: leftX, y: centerY)

                Circle()
                    .stroke(Color.accentColor.opacity(0.8 * (1 - ripple)), lineWidth: 1.5)
                    .frame(width: item + ripple * 26, height: item + ripple * 26)
                    .position(x: rightX, y: centerY)
            }

            Text("3-finger tap")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .position(x: leftX, y: size.height - 10)

            Text("Middle click")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(fired ? Color.accentColor : Color.secondary)
                .fixedSize()
                .position(x: rightX, y: size.height - 10)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Multi-action preview

/// Repeated middle-clicks on one Dock icon escalate: quit, stop+force, force quit.
private struct EscalationScene: View {
    let size: CGSize
    let date: Date

    private let clickTimes: [TimeInterval] = [1.5, 3.3, 5.1]
    private let stepLabels = [
        "Quit normally",
        "Stop helpers",
        "Force quit now"
    ]

    var body: some View {
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: FeatureAnimationClock.loop)
        let firedCount = clickTimes.filter { elapsed >= $0 }.count
        let active = firedCount > 0 ? min(firedCount - 1, 2) : nil

        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let fired = elapsed >= clickTimes[index]
                let isActive = active == index

                HStack(spacing: 8) {
                    Text("\(index + 1)×")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .frame(width: 16, alignment: .trailing)

                    Text(stepLabels[index])
                        .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)

                    if fired {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.14)
                                : Color.primary.opacity(fired ? 0.05 : 0.025)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                )
                .opacity(fired ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height)
    }
}
