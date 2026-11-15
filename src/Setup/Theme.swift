import SwiftUI

enum SetupStyle {
    static let windowWidth: CGFloat = 560
    static let windowHeight: CGFloat = 460
    static let padding: CGFloat = 20
    static let iconSize: CGFloat = 64
    static let heroCornerRadius: CGFloat = 12
    static let previewCornerRadius: CGFloat = 10
    static let previewStageHeight: CGFloat = 78
}

struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusLabel: View {
    enum Kind {
        case granted
        case required
        case optional
        case problem

        var icon: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .required, .problem: return "exclamationmark.triangle.fill"
            case .optional: return "minus.circle"
            }
        }

        var color: Color {
            switch self {
            case .granted: return .green
            case .required, .problem: return .orange
            case .optional: return .secondary
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        Label(text, systemImage: kind.icon)
            .font(.callout)
            .foregroundStyle(kind.color)
            .labelStyle(.titleAndIcon)
    }
}

struct Notice: View {
    enum Kind {
        case info
        case warning
    }

    let text: String
    var kind: Kind = .info
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .warning ? Color.orange : Color.accentColor)
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
    }
}

struct SetupFooter<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, SetupStyle.padding)
            .padding(.vertical, 12)
        }
    }
}

struct SummaryRow: View {
    let title: String
    let value: String
    let kind: StatusLabel.Kind
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            StatusLabel(text: value, kind: kind)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}
