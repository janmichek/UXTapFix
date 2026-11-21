import SwiftUI

// MARK: - Design tokens

enum SetupStyle {
    static let windowWidth: CGFloat = 600
    static let windowHeight: CGFloat = 580
    static let contentPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 12
    static let iconSize: CGFloat = 72
    static let tileSize: CGFloat = 36
    static let cardCornerRadius: CGFloat = 14
    static let innerCornerRadius: CGFloat = 10
    static let heroCornerRadius: CGFloat = 18
    static let previewStageHeight: CGFloat = 84
}

enum SetupColors {
    /// Page canvas. Slightly recessed from the cards in both appearances.
    static var canvas: Color { Color(nsColor: .underPageBackgroundColor) }
    static var card: Color { Color(nsColor: .textBackgroundColor) }
    static var border: Color { Color.primary.opacity(0.08) }
    static var subtleBorder: Color { Color.primary.opacity(0.05) }
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
    var tint: Color = .accentColor
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
    let current: Int

    private let steps = ["Install", "Permissions", "Launch at Login"]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(steps.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    Capsule()
                        .fill(index <= current ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 3)

                    HStack(spacing: 5) {
                        if index < current {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(index == current ? Color.accentColor : Color.secondary)
                                .frame(width: 14, height: 14)
                                .background(
                                    Circle().fill(
                                        index == current
                                            ? Color.accentColor.opacity(0.12)
                                            : Color.primary.opacity(0.05)
                                    )
                                )
                        }

                        Text(steps[index])
                            .font(.caption2.weight(index == current ? .semibold : .regular))
                            .foregroundStyle(index == current ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(current + 1) of \(steps.count): \(steps[current])"))
    }
}

// MARK: - Headers

struct StepHeader: View {
    let step: Int
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepProgress(current: step)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 23, weight: .semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status

struct StatusPill: View {
    enum Kind {
        case granted
        case required
        case optional

        var icon: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .required: return "exclamationmark.circle.fill"
            case .optional: return "minus.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green
            case .required: return .orange
            case .optional: return .secondary
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(kind.color.opacity(0.12)))
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
            case .info: return .accentColor
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
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            .padding(.vertical, 14)
        }
        .background(SetupColors.canvas)
    }
}
