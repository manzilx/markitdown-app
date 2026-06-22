import SwiftUI

// MARK: - Surface modifiers

extension View {
    /// Standard elevated panel: fill + hairline border + clipped continuous corners.
    func panelBackground(
        radius: CGFloat = Theme.Radius.lg,
        fill: Color = Theme.surfaceElevated,
        stroke: Color = Theme.hairline,
        shadow: Bool = false
    ) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(ConditionalShadow(enabled: shadow))
    }

    /// Lift slightly on hover.
    func hoverLift(_ scale: CGFloat = 1.015) -> some View {
        modifier(HoverLift(scale: scale))
    }
}

private struct ConditionalShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: .black.opacity(0.38), radius: 20, x: 0, y: 12)
        } else {
            content
        }
    }
}

private struct HoverLift: ViewModifier {
    let scale: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .animation(Theme.Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Pills & badges

struct Pill: View {
    let text: String
    var systemImage: String?
    var color: Color = Theme.accent
    var filled: Bool = false

    init(_ text: String, systemImage: String? = nil, color: Color = Theme.accent, filled: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.filled = filled
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(filled ? .white : color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.16)))
        )
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(filled ? 0 : 0.35), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(Theme.dim)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 4)
                    .scaleEffect(animate ? 2.2 : 1)
                    .opacity(animate ? 0 : 0.8)
            )
            .shadow(color: color.opacity(0.7), radius: 4)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

struct NoticeBanner: View {
    enum Tone {
        case info
        case warning
        case error

        var color: Color {
            switch self {
            case .info: Theme.info
            case .warning: Theme.warning
            case .error: Theme.danger
            }
        }

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    let title: String
    let message: String
    var tone: Tone = .error
    var actionTitle: String?
    var onAction: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: tone.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.md)

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(SoftButtonStyle(tint: tone.color))
                    .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(Theme.Spacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(tone.color.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// A small keyboard-shortcut keycap, e.g. ⌘K.
struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surfaceHigh))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.brandGradient)
                        .brightness(hovering ? 0.05 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Theme.accent.opacity(hovering ? 0.5 : 0.3), radius: hovering ? 16 : 9, y: 4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.92 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.snappy, value: hovering)
                .animation(Theme.Motion.snappy, value: configuration.isPressed)
        }
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(tint.opacity(hovering ? 0.24 : 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.snappy, value: hovering)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.surfaceHigh.opacity(hovering ? 1 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.snappy, value: hovering)
        }
    }
}

/// Square icon button for toolbars.
struct ToolbarIconButtonStyle: ButtonStyle {
    var active: Bool = false
    var tint: Color = Theme.textSecondary
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, active: active, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let tint: Color
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Theme.accentBright : (hovering ? Theme.text : tint))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(active ? Theme.accentSoft : Theme.surfaceHigh.opacity(hovering ? 1 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(active ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.snappy, value: hovering)
                .animation(Theme.Motion.snappy, value: active)
        }
    }
}
