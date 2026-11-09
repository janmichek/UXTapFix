import SwiftUI

enum Brand {
    static let indigo = Color(red: 0.23, green: 0.30, blue: 0.78)
    static let blue = Color(red: 0.30, green: 0.47, blue: 0.96)
    static let sky = Color(red: 0.49, green: 0.69, blue: 1.00)
    static let green = Color(red: 0.11, green: 0.63, blue: 0.38)
    static let amber = Color(red: 0.86, green: 0.53, blue: 0.10)
    static let red = Color(red: 0.84, green: 0.26, blue: 0.25)
    static let gradient = LinearGradient(
        colors: [indigo, blue, sky],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let softGradient = LinearGradient(
        colors: [blue.opacity(0.13), indigo.opacity(0.06)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Background

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Brand.blue.opacity(0.13),
                    Color.clear,
                    Brand.indigo.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Brand.sky.opacity(0.15))
                .frame(width: 460, height: 460)
                .blur(radius: 110)
                .offset(x: 340, y: -300)
            Circle()
                .fill(Brand.indigo.opacity(0.10))
                .frame(width: 380, height: 380)
                .blur(radius: 100)
                .offset(x: -360, y: 300)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cards and controls

struct Card<Content: View>: View {
    var padding: CGFloat
    let content: Content

    init(padding: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.06), radius: 18, y: 8)
            }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(
                    isEnabled
                        ? AnyShapeStyle(Brand.gradient)
                        : AnyShapeStyle(Color.secondary.opacity(0.28))
                )
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: Brand.blue.opacity(isEnabled ? 0.28 : 0), radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                Capsule().fill(Color.primary.opacity(isEnabled ? 0.07 : 0.03))
            }
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Brand.blue)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct StatusPill: View {
    let ok: Bool
    let okText: String
    let pendingText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Brand.green : Brand.amber)
                .frame(width: 7, height: 7)
            Text(ok ? okText : pendingText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(ok ? Brand.green : Brand.amber)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule().fill((ok ? Brand.green : Brand.amber).opacity(0.12))
        }
    }
}

struct FeatureChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.blue)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(Color.primary.opacity(0.045))
        }
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct IconBadge: View {
    let icon: String
    var tint: Color = Brand.blue
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                            .strokeBorder(tint.opacity(0.16), lineWidth: 1)
                    }
            }
    }
}

enum BannerKind {
    case success
    case info
    case warning

    var color: Color {
        switch self {
        case .success: return Brand.green
        case .info: return Brand.blue
        case .warning: return Brand.amber
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "sparkles"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

struct Banner: View {
    let kind: BannerKind
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.color)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(kind.color.opacity(0.09))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(kind.color.opacity(0.16), lineWidth: 1)
                }
        }
    }
}

// MARK: - Step indicator

struct StepIndicator: View {
    let current: SetupModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupModel.Step.allCases) { step in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(fill(for: step))
                            .frame(width: 18, height: 18)
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Brand.blue)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(step == current ? .white : Color.secondary)
                        }
                    }
                    Text(step.label)
                        .font(.system(size: 10.5, weight: step == current ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(step == current ? Color.primary : Color.secondary)
                }
                if step != .done {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 14, height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 13)
    }

    private func fill(for step: SetupModel.Step) -> Color {
        if step == current { return Brand.blue }
        if step.rawValue < current.rawValue { return Brand.blue.opacity(0.14) }
        return Color.primary.opacity(0.07)
    }
}
