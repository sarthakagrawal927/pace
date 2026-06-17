//
//  PaceAnnotationShape.swift
//  leanring-buddy
//
//  Pure value types for the tuition-mode `draw_annotation` tool. The
//  planner emits one or more shapes in the same screenshot-pixel + 1-based
//  screen-number coord space it already uses for [POINT] and `click`; the
//  overlay layer renders them on top of the screen so Pace can teach
//  (box this, arrow to that, polygon around the panel) instead of
//  clicking through the step itself.
//
//  Mirrors the value-type style of `PointingParseResult` in
//  `PaceTagParsers.swift`: pure, `nonisolated`, `Equatable`, no I/O. The
//  drainer (`PaceAnnotationOverlayController.swift`) converts these into
//  AppKit-global geometry before they reach the SwiftUI overlay.
//

import CoreGraphics
import Foundation

/// Named planner-facing colors. Keeping the set small (5) keeps the
/// system-prompt cheap and the planner's choices clear. Unknown / missing
/// colors fall back to `.red` (the default teaching highlight).
nonisolated enum PaceAnnotationColor: String, Equatable {
    case red
    case blue
    case green
    case yellow
    case orange

    static let `default`: PaceAnnotationColor = .red

    /// Parse a planner-supplied lowercase color name; unknown → default.
    static func from(rawValue: String?) -> PaceAnnotationColor {
        guard let normalized = rawValue?.lowercased(),
              let color = PaceAnnotationColor(rawValue: normalized) else {
            return .default
        }
        return color
    }
}

/// Visual styling shared by every annotation shape. The planner can
/// supply any subset; defaults fill in the rest.
nonisolated struct PaceAnnotationStyle: Equatable {
    let color: PaceAnnotationColor
    /// Optional short caption rendered near the shape. Trimmed and
    /// capped to 60 chars at parse time so a runaway label can't paint
    /// the whole screen.
    let label: String?
    /// Stroke width in display points. Clamped to [1.0, 12.0] at parse
    /// time — thinner than 1pt is invisible on retina, thicker than 12pt
    /// stops looking like an annotation.
    let strokeWidth: Double
    /// When true, fill the shape interior with the same color at 18%
    /// opacity in addition to the stroke. No-op for `line`/`arrow`.
    let filled: Bool

    static let `default` = PaceAnnotationStyle(
        color: .default,
        label: nil,
        strokeWidth: 3.0,
        filled: false
    )

    /// Sanitize a planner-supplied label: trim whitespace, treat empty
    /// as nil, cap at 60 chars.
    static func sanitizedLabel(_ rawLabel: String?) -> String? {
        guard let rawLabel else { return nil }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }

    /// Clamp a planner-supplied stroke width into the safe range. nil or
    /// out-of-range → default (3.0).
    static func clampedStrokeWidth(_ rawStrokeWidth: Double?) -> Double {
        guard let rawStrokeWidth else { return 3.0 }
        return max(1.0, min(rawStrokeWidth, 12.0))
    }
}

/// One annotation primitive in screenshot-pixel coords. The drainer
/// (`PaceAnnotationOverlayController`) converts these to AppKit-global
/// before they reach the overlay; the overlay never sees pixel coords.
nonisolated enum PaceAnnotationShape: Equatable {
    case rect(x: Double, y: Double, width: Double, height: Double, style: PaceAnnotationStyle)
    case ellipse(x: Double, y: Double, width: Double, height: Double, style: PaceAnnotationStyle)
    case line(x1: Double, y1: Double, x2: Double, y2: Double, style: PaceAnnotationStyle)
    case arrow(tailX: Double, tailY: Double, headX: Double, headY: Double, style: PaceAnnotationStyle)
    /// Closed polygon — pentagon is `points.count == 5`. Requires ≥3
    /// vertices; enforced at parse time.
    case polygon(points: [CGPoint], style: PaceAnnotationStyle)

    var style: PaceAnnotationStyle {
        switch self {
        case .rect(_, _, _, _, let style): return style
        case .ellipse(_, _, _, _, let style): return style
        case .line(_, _, _, _, let style): return style
        case .arrow(_, _, _, _, let style): return style
        case .polygon(_, let style): return style
        }
    }
}

/// One full `draw_annotation` tool call. Every shape in `shapes` shares
/// the same `screenNumber` (1-based; `nil` → cursor screen at execution
/// time). The planner can pack several shapes into one call to box and
/// arrow related elements together in a single teaching beat.
nonisolated struct PaceAnnotationRequest: Equatable {
    let shapes: [PaceAnnotationShape]
    let screenNumber: Int?

    /// Hard ceiling on shapes per call. Anything beyond this is
    /// truncated at parse time — a 24-shape teaching diagram is already
    /// well past "useful" and we don't want a hung planner to blanket
    /// the screen.
    static let maximumShapeCount = 24
}
