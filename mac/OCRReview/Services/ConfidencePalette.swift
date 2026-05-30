import AppKit
import SwiftUI

/// Maps OCR confidence (0–1) to review colors (red → amber → green).
enum ConfidencePalette {
    static func nsColor(for confidence: Float) -> NSColor {
        switch confidence {
        case ..<0.6: return NSColor.systemRed
        case ..<VisionOCRService.lowConfidenceThreshold: return NSColor.systemOrange
        default: return NSColor.systemGreen
        }
    }

    static func color(for confidence: Float) -> Color {
        Color(nsColor: nsColor(for: confidence))
    }
}
