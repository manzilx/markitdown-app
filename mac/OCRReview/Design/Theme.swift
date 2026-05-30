import SwiftUI

/// Design system for OCR Review.
///
/// A refined, layered dark aesthetic. The brand accent is an indigo "iris" — kept
/// deliberately distinct from the red→amber→green confidence palette so "primary
/// action" never reads as "high confidence".
enum Theme {

    // MARK: - Surfaces (deepest → most elevated)

    /// App canvas — the deepest layer.
    static let bg = Color(red: 0.039, green: 0.043, blue: 0.055)
    /// Primary panels (toolbars, strips).
    static let surface = Color(red: 0.070, green: 0.078, blue: 0.098)
    /// Cards, menus, the editor field.
    static let surfaceElevated = Color(red: 0.098, green: 0.110, blue: 0.137)
    /// Popovers, the command palette, hovered rows.
    static let surfaceHigh = Color(red: 0.128, green: 0.143, blue: 0.176)
    /// Legacy alias.
    static let panel = surface

    // MARK: - Borders

    static let border = Color(red: 0.18, green: 0.20, blue: 0.25)
    static let borderStrong = Color(red: 0.27, green: 0.30, blue: 0.37)
    /// Hairline border that reads on any surface.
    static let hairline = Color.white.opacity(0.07)

    // MARK: - Text

    static let text = Color(red: 0.92, green: 0.93, blue: 0.96)
    static let textSecondary = Color(red: 0.66, green: 0.69, blue: 0.77)
    /// Tertiary / muted text. Legacy name kept.
    static let dim = Color(red: 0.47, green: 0.50, blue: 0.58)

    // MARK: - Brand accent (iris / indigo)

    static let accent = Color(red: 0.45, green: 0.44, blue: 0.96)
    static let accentBright = Color(red: 0.58, green: 0.57, blue: 1.0)
    static let accentDeep = Color(red: 0.34, green: 0.32, blue: 0.82)
    /// Soft background tint of the accent.
    static let accentSoft = Color(red: 0.45, green: 0.44, blue: 0.96).opacity(0.16)

    // MARK: - Semantic status (also drives the confidence heatmap)

    static let success = Color(red: 0.30, green: 0.82, blue: 0.60)
    static let warning = Color(red: 0.98, green: 0.74, blue: 0.30)
    static let danger = Color(red: 0.96, green: 0.42, blue: 0.42)
    static let info = Color(red: 0.38, green: 0.66, blue: 0.98)
    /// Legacy alias.
    static let error = danger

    // MARK: - Gradients

    /// Indigo → violet, for primary buttons and brand marks.
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.45, green: 0.44, blue: 0.96), Color(red: 0.64, green: 0.45, blue: 0.95)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Rich multi-stop wash for the welcome hero.
    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.40, green: 0.42, blue: 0.98),
            Color(red: 0.58, green: 0.42, blue: 0.96),
            Color(red: 0.36, green: 0.74, blue: 0.92),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle top-down sheen layered over the canvas.
    static let canvasGradient = LinearGradient(
        colors: [Color(red: 0.075, green: 0.082, blue: 0.108), Color(red: 0.035, green: 0.039, blue: 0.051)],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Spacing scale (4-pt based)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Corner radii

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
        static let xxl: CGFloat = 24
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    enum Motion {
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static let smooth = Animation.easeInOut(duration: 0.22)
        static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
        static let gentle = Animation.easeOut(duration: 0.35)
    }
}

// MARK: - Confidence

extension Theme {
    /// Map OCR confidence (0–1) to the status palette.
    static func confidenceColor(_ confidence: Float) -> Color {
        switch confidence {
        case ..<0.6: return danger
        case ..<VisionOCRService.lowConfidenceThreshold: return warning
        default: return success
        }
    }
}
