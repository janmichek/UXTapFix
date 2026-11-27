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
        case .threeFingerTap: return "Sync the controls"
        case .quitDockApp: return "Quit Dock apps"
        case .multiAction: return "Force quit"
        }
    }

    var caption: String {
        switch self {
        case .threeFingerTap:
            return "Close tabs and open links in a new tab with a 3-finger tap."
        case .quitDockApp:
            return "Tap a Dock icon with three fingers to quit the app."
        case .multiAction:
            return "Click/tap once to quit, or three times to force quit."
        }
    }

    var hint: String {
        switch self {
        case .threeFingerTap: return "Tap"
        case .quitDockApp: return "Quit"
        case .multiAction: return "Force quit"
        }
    }

    var symbol: String {
        switch self {
        case .threeFingerTap: return "hand.tap"
        case .quitDockApp: return "square.grid.2x2"
        case .multiAction: return "bolt.fill"
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

    static func phase(at date: Date, speed: Double = 1) -> Phase {
        let base = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
        let elapsed = (base * speed).truncatingRemainder(dividingBy: loop)
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
    private let subtitle = "Close tabs, open links, quit Dock apps, close Mission Control windows, and delete Calendar events with a three-finger tap."

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: SetupStyle.iconSize, height: SetupStyle.iconSize)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("UXTapFix")
                    .font(SetupFont.hero)
                    .tracking(-0.3)

                Text(subtitle)
                    .font(SetupFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SetupStyle.cardCornerRadius, style: .continuous)
                .fill(SetupColors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SetupStyle.cardCornerRadius, style: .continuous)
                .strokeBorder(SetupColors.border, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("UXTapFix. \(subtitle)"))
    }
}

// MARK: - Preview card

struct FeaturePreviewCard: View {
    let kind: FeaturePreviewKind
    /// When set, the card renders this moment instead of animating. Used by
    /// `tools/export-previews.swift` to record the README previews.
    var date: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(kind.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            FeatureAnimationStage(kind: kind, date: date)
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
                .font(SetupFont.secondary)
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
    /// A fixed moment for offscreen rendering; `nil` follows the live clock.
    var date: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if reduceMotion {
                FeatureStillStage(kind: kind)
                    .frame(width: size.width, height: size.height)
            } else if let date {
                scene(size: size, date: date)
            } else {
                TimelineView(.animation) { context in
                    scene(size: size, date: context.date)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(size: CGSize, date: Date) -> some View {
        switch kind {
        case .threeFingerTap:
            // This card has no ripple or cursor to pace the gesture, so it
            // plays at double speed to keep the color change feeling snappy.
            TrackpadTapScene(size: size, phase: FeatureAnimationClock.phase(at: date, speed: 2))
        case .quitDockApp:
            DockQuitScene(size: size, phase: FeatureAnimationClock.phase(at: date))
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
                            .font(.system(size: 16))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    )
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SetupColors.accent)
                    .offset(x: 5, y: -5)
            }

            Text(kind.hint)
                .font(.system(size: 12, weight: .semibold))
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
            .fill(SetupColors.accent.opacity(0.6 * (1 - result)))
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
        let tile = min(max(size.height * 0.40, 22), 42)
        let gap = max(tile * 0.24, 5)
        let count = CGFloat(symbols.count)
        let stripWidth = count * tile + (count - 1) * gap
        let startX = max((size.width - stripWidth) / 2, gap)
        let stripY = max((size.height - tile) / 2 - 4, 0)
        let target = CGPoint(
            x: startX + CGFloat(targetIndex) * (tile + gap) + tile / 2,
            y: stripY + tile / 2
        )
        let resting = CGPoint(x: size.width * 0.78, y: size.height * 0.90)
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
                    .stroke(SetupColors.accent.opacity(0.8 * (1 - phase.ripple)), lineWidth: 1.5)
                    .frame(width: tile + ripple * 26, height: tile + ripple * 26)
                    .position(target)
            }

            if phase.result > 0.01 {
                poofBurst(center: target, radius: 10 + result * 22, result: phase.result)
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

        let wheelTop = bodyHeight * 0.11
        let wheelHeight = bodyHeight * 0.30
        // Keep the button split clear of the scroll wheel: anchor it to the
        // wheel's bottom edge so resizing the wheel can never leave the line
        // showing through it.
        let dividerY = wheelTop + wheelHeight + max(bodyHeight * 0.06, 2)
        let outline = Color.primary.opacity(0.32)

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: bodyWidth * 0.5, style: .continuous)
                .fill(SetupColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: bodyWidth * 0.5, style: .continuous)
                        .strokeBorder(outline, lineWidth: 1)
                )
                .frame(width: bodyWidth, height: bodyHeight)

            Rectangle()
                .fill(Color.primary.opacity(0.16))
                .frame(width: bodyWidth, height: 1)
                .offset(y: dividerY)

            Capsule()
                .fill(active ? SetupColors.accent : outline)
                .frame(width: max(size * 0.11, 3.5), height: wheelHeight)
                .offset(y: wheelTop)
        }
        .frame(width: bodyWidth, height: bodyHeight)
    }
}

/// The three-finger tap and the middle mouse click shown as one synced action.
private struct TrackpadTapScene: View {
    let size: CGSize
    let phase: FeatureAnimationClock.Phase

    var body: some View {
        let result = CGFloat(phase.result)

        let item = min(size.width * 0.28, 64)
        let gap: CGFloat = max(size.width * 0.20, 34)
        let mouseX = size.width / 2 - item / 2 - gap / 2
        let trackpadX = size.width / 2 + item / 2 + gap / 2
        let centerY = size.height * 0.40
        let fired = result > 0.05

        ZStack {
            // Right: three-finger tap
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .frame(width: item, height: item)
                .position(x: trackpadX, y: centerY)

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(fired ? SetupColors.accent : Color.primary.opacity(0.5))
                    .frame(width: 10, height: 10)
                    .position(
                        x: trackpadX - 14 + CGFloat(index) * 14,
                        y: centerY - item * 0.16
                    )
            }

            // Sync mark: the two inputs are the same click.
            Text("=")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(SetupColors.accent.opacity(fired ? 1 : 0.7))
                .position(x: size.width / 2, y: centerY)

            // Left: middle mouse button
            MiddleMouseGlyph(size: item, active: fired)
                .position(x: mouseX, y: centerY)

            Text("Tap")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fired ? SetupColors.accent : Color.secondary)
                .fixedSize()
                .position(x: mouseX, y: size.height - 48)

            Text("3-finger tap")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fired ? SetupColors.accent : Color.secondary)
                .fixedSize()
                .position(x: trackpadX, y: size.height - 48)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Multi-action preview

/// A normal middle-click quits; a triple-click force-quits.
private struct EscalationScene: View {
    let size: CGSize
    let date: Date

    private let clickTimes: [TimeInterval] = [1.5, 4.5]
    private let stepLabels = [
        "Quit",
        "Force quit now"
    ]
    private let stepCounts = [
        "1×",
        "3×"
    ]

    var body: some View {
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: FeatureAnimationClock.loop)
        let firedCount = clickTimes.filter { elapsed >= $0 }.count
        let active = firedCount > 0 ? min(firedCount - 1, 1) : nil

        VStack(spacing: 6) {
            ForEach(0..<clickTimes.count, id: \.self) { index in
                let fired = elapsed >= clickTimes[index]
                let isActive = active == index

                HStack(spacing: 9) {
                    Text(stepCounts[index])
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(isActive ? SetupColors.accent : Color.secondary)
                        .frame(width: 20, alignment: .trailing)

                    Text(stepLabels[index])
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)

                    if fired {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SetupColors.accent)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isActive
                                ? SetupColors.accent.opacity(0.14)
                                : Color.primary.opacity(fired ? 0.05 : 0.025)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isActive ? SetupColors.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                )
                .opacity(fired ? 1 : 0.55)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height)
    }
}
