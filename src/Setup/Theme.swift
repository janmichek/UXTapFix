import SwiftUI

// MARK: - Design tokens

enum SetupStyle {
    static let windowWidth: CGFloat = 840
    static let windowHeight: CGFloat = 640
    static let contentPadding: CGFloat = 26
    static let sectionSpacing: CGFloat = 22
    static let itemSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    /// Minimum height of a card's content row so settings cards keep the same
    /// rhythm whether they hold a summary, a note, or a trailing control.
    static let rowMinHeight: CGFloat = 74
    static let iconSize: CGFloat = 56
    static let tileSize: CGFloat = 42
    static let cardCornerRadius: CGFloat = 14
    static let innerCornerRadius: CGFloat = 10
    static let previewStageHeight: CGFloat = 175
    static let stepperWidth: CGFloat = 480
}

/// One typographic scale for the whole assistant. System semantic sizes are
/// a little too small for a setup window that is read at a glance, so every
/// label is sized explicitly from these tokens.
enum SetupFont {
    static let display = Font.system(size: 27, weight: .semibold)
    static let hero = Font.system(size: 24, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14)
    static let secondary = Font.system(size: 13)
    static let button = Font.system(size: 14, weight: .semibold)
}

enum SetupColors {
    /// Page canvas. Slightly recessed from the cards in both appearances.
    static var canvas: Color { Color(nsColor: .underPageBackgroundColor) }
    static var card: Color { Color(nsColor: .textBackgroundColor) }
    static var border: Color { Color.primary.opacity(0.08) }
    static var subtleBorder: Color { Color.primary.opacity(0.05) }

    /// The blue at the heart of the app icon's gradient. Every accent in the
    /// assistant comes from this hue so the window and the icon read as one.
    static let brandBlue = Color(red: 0.30, green: 0.47, blue: 0.96)

    /// Small accent text and icons need a little more lift on dark cards, so
    /// the accent brightens in dark mode while keeping the logo's hue.
    static let accent = Color(nsColor: NSColor(name: "SetupAccent") { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.48, green: 0.65, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.30, green: 0.47, blue: 0.96, alpha: 1)
    })

    /// Solid fill for prominent actions. White text stays crisp on it in both
    /// appearances, so buttons keep the exact logo blue.
    static var accentFill: Color { brandBlue }
}

// MARK: - Surfaces

struct SetupCard<Content: View>: View {
    var padding: CGFloat = 16
    private let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SetupStyle.cardCornerRadius, style: .continuous)
                    .fill(SetupColors.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SetupStyle.cardCornerRadius, style: .continuous)
                    .strokeBorder(SetupColors.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.045), radius: 7, y: 2)
    }
}

/// Rounded, tinted square that anchors a row's icon.
struct IconTile: View {
    let systemName: String
    var tint: Color = SetupColors.accent
    var size: CGFloat = SetupStyle.tileSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(tint)
            )
    }
}

// MARK: - Progress

struct StepProgress: View {
    let current: SetupModel.Step

    private let steps: [(SetupModel.Step, String)] = [
        (.welcome, "Welcome"),
        (.install, "Install"),
        (.permissions, "Setup"),
        (.finish, "Finish")
    ]

    var body: some View {
        let currentIndex = steps.firstIndex(where: { $0.0 == current }) ?? 0
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule()
                        .fill(index <= currentIndex ? SetupColors.accent : Color.primary.opacity(0.12))
                        .frame(height: 4)

                    HStack(spacing: 6) {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SetupColors.accent)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(index == currentIndex ? SetupColors.accent : Color.secondary)
                                .frame(width: 17, height: 17)
                                .background(
                                    Circle().fill(
                                        index == currentIndex
                                            ? SetupColors.accent.opacity(0.12)
                                            : Color.primary.opacity(0.05)
                                    )
                                )
                        }

                        Text(step.1)
                            .font(.system(size: 12, weight: index == currentIndex ? .semibold : .regular))
                            .foregroundStyle(index == currentIndex ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: SetupStyle.stepperWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(currentIndex + 1) of \(steps.count): \(steps[currentIndex].1)"))
    }
}

// MARK: - Headers

struct StepHeader: View {
    let step: SetupModel.Step
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepProgress(current: step)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(SetupFont.display)
                Text(subtitle)
                    .font(SetupFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status

/// Compact inline status that sits beside a row's title. Kept text-only so a
/// permission row needs just one trailing control on the right.
struct StatusLabel: View {
    enum Kind {
        case granted
        case required

        var icon: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .required: return "exclamationmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green
            case .required: return .orange
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(kind.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - Notice

struct Notice: View {
    enum Kind {
        case info
        case warning

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return SetupColors.accent
            case .warning: return .orange
            }
        }

        var fills: Bool {
            self == .warning
        }
    }

    let text: String
    var kind: Kind = .info
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.tint)

            Text(text)
                .font(SetupFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: SetupStyle.innerCornerRadius, style: .continuous)
                .fill(kind.tint.opacity(kind.fills ? 0.10 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SetupStyle.innerCornerRadius, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.14), lineWidth: 1)
        )
    }
}

// MARK: - Footer

/// Shared button chrome so actions line up at the same height and width instead
/// of inheriting different system control sizes.
struct SetupButtonStyle: ButtonStyle {
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SetupFont.button)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 20)
            .frame(minWidth: 104, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        prominent ? Color.clear : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if prominent {
            return SetupColors.accentFill.opacity(pressed ? 0.82 : 1)
        }
        return Color.primary.opacity(pressed ? 0.10 : 0.06)
    }
}

struct SetupFooter<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, SetupStyle.contentPadding)
            .padding(.vertical, 15)
        }
        .background(SetupColors.canvas)
    }
}

/// Button title with an SF Symbol placed before or after the text. Used by the
/// footer so Back and Next read the same way on every step.
struct ActionLabel: View {
    let title: String
    let systemName: String
    var iconAfter = false

    var body: some View {
        HStack(spacing: 7) {
            if !iconAfter {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
            if iconAfter {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}
