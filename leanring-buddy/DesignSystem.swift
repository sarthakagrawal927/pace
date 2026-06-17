//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens
    //
    // Pace's actual UI is minimal — menu-bar panel, overlay cursor, and
    // a few status pills. Only the tokens used by current views are kept
    // here. The earlier full Tailwind palette + Material Design state-
    // layer scaffolding was over-built for what shipped; periphery's
    // dead-code scan confirmed none of the extra tokens were referenced.

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────

        /// The deepest background — used for the main app window fill.
        static let background = Color(hex: "#101211")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#373B39")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#ECEEED")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text on the accent fill (the Blue-600 keystone). White → ~5.1:1
        /// contrast on #2563eb (WCAG AA).
        static let textOnAccent: Color = .white

        // ── Accent ───────────────────────────────────────────────────

        /// The single accent token — solid blue used for primary CTAs,
        /// hover backgrounds, and the overlay cursor's gradient stops.
        static let accent = Color(hex: "#2563eb")

        // ── Semantic ─────────────────────────────────────────────────

        /// Success — checkmarks, granted permission status indicators.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")      // Radix Amber 9

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The blue cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        static let overlayCursorBlue = Color(hex: "#3380FF")

        // ── Tuition-mode annotation palette ──────────────────────────
        //
        // Bright, distinct hues that read clearly over any underlying
        // screen content. Used by `PaceAnnotationShapeView` in
        // OverlayWindow to color rects/ellipses/lines/arrows/polygons
        // drawn by the planner's `draw_annotation` tool. Default is
        // `annotationRed` — same as the planner's default color.
        static let annotationRed    = Color(red: 0.95, green: 0.30, blue: 0.30)
        static let annotationBlue   = Color(red: 0.30, green: 0.55, blue: 0.95)
        static let annotationGreen  = Color(red: 0.30, green: 0.75, blue: 0.45)
        static let annotationYellow = Color(red: 0.95, green: 0.80, blue: 0.30)
        static let annotationOrange = Color(red: 0.95, green: 0.55, blue: 0.25)
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

}
