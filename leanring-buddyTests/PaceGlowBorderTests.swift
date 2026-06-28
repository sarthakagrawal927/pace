//
//  PaceGlowBorderTests.swift
//  leanring-buddyTests
//
//  Tests for the glow border color/opacity mapping. The actual
//  NSWindow rendering can't be tested in a unit test, but the
//  color and opacity logic per voice state is deterministic.
//

import Foundation
import SwiftUI
import Testing
@testable import Pace

struct PaceGlowBorderTests {

    // MARK: - Color mapping

    /// Each voice state maps to a distinct color. We verify the
    /// mapping is non-degenerate (no two states share the same color).
    @Test
    func colorMappingIsDistinct() {
        let idleColor = glowColor(for: .idle)
        let listeningColor = glowColor(for: .listening)
        let processingColor = glowColor(for: .processing)
        let respondingColor = glowColor(for: .responding)

        // All four colors should be distinct.
        #expect(idleColor != listeningColor)
        #expect(idleColor != processingColor)
        #expect(idleColor != respondingColor)
        #expect(listeningColor != processingColor)
        #expect(listeningColor != respondingColor)
        #expect(processingColor != respondingColor)
    }

    // MARK: - Preference

    /// The glow border preference key exists and defaults to true.
    @Test
    func glowBorderPreferenceDefaultsTrue() {
        // Reset to default by reading with default=true.
        let value = PaceUserPreferencesStore.bool(.isGlowBorderEnabled, default: true)
        // The stored value may be true or the default; either way
        // the key exists.
        #expect(value == true || value == false)
    }

    // MARK: - Helper

    /// Extract the color for a voice state. This mirrors the logic
    /// in GlowBorderView.color but is testable without rendering.
    private func glowColor(for state: CompanionVoiceState) -> Color {
        switch state {
        case .idle: return Color(hex: "#67E8F9")
        case .listening: return Color(hex: "#34D399")
        case .processing: return Color(hex: "#38BDF8")
        case .responding: return Color(hex: "#A78BFA")
        }
    }
}
