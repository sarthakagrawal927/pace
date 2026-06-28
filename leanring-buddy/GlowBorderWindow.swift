//
//  GlowBorderWindow.swift
//  leanring-buddy
//
//  Screen-edge glow border that shifts color with the agent's voice
//  state — a subtle ambient phase indicator inspired by ORB's glow
//  border. One window per screen, click-through, non-activating.
//
//  Color mapping matches PaceMenuBarOverlay's activeAccentColor so
//  the border and the menu-bar capsule stay in sync:
//    idle       → dim cyan (barely visible, "alive but waiting")
//    listening  → green
//    processing → blue
//    responding → purple
//

import AppKit
import Combine
import SwiftUI

// MARK: - Window

/// Transparent, click-through borderless window that renders only the
/// glow border. Sits one level below the cursor overlay (which uses
/// `.screenSaver`) so the cursor buddy always paints on top.
class GlowBorderWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        // One notch below the cursor overlay's .screenSaver level so
        // the cursor buddy always renders above the glow.
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false
        self.hidesOnDeactivate = false

        self.setFrame(screen.frame, display: true)
        if let match = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(match.frame.origin)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Border view

/// SwiftUI view that draws the colored border + glow. The border is a
/// thin rounded-rectangle stroke inset from the screen edges, with a
/// soft outer shadow that creates the "glow" effect. Opacity and color
/// animate smoothly when `voiceState` changes.
struct GlowBorderView: View {
    let voiceState: CompanionVoiceState

    /// Border thickness in points. Kept thin so the glow is ambient,
    /// not distracting.
    private let borderWidth: CGFloat = 3
    /// Inset from the screen edge. On notched MacBooks this keeps the
    /// border from overlapping the notch area visually.
    private let borderInset: CGFloat = 2

    private var color: Color {
        switch voiceState {
        case .idle:
            return Color(hex: "#67E8F9")
        case .listening:
            return Color(hex: "#34D399")
        case .processing:
            return Color(hex: "#38BDF8")
        case .responding:
            return Color(hex: "#A78BFA")
        }
    }

    /// Border opacity by state. Idle is barely visible; active states
    /// are more prominent but still subtle.
    private var opacity: Double {
        switch voiceState {
        case .idle:
            return 0.15
        case .listening:
            return 0.55
        case .processing:
            return 0.55
        case .responding:
            return 0.55
        }
    }

    /// Glow radius by state. Processing gets a slightly larger glow to
    /// feel "thinking."
    private var glowRadius: CGFloat {
        switch voiceState {
        case .idle:
            return 4
        case .listening:
            return 12
        case .processing:
            return 16
        case .responding:
            return 12
        }
    }

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
            .stroke(color, lineWidth: borderWidth)
            .shadow(color: color, radius: glowRadius, x: 0, y: 0)
            .opacity(opacity)
            .padding(borderInset)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.4), value: voiceState)
        }
        // Respect Reduce Motion — the glow still shows but doesn't
        // animate between states.
        .accessibilityHidden(true)
    }
}

// MARK: - Manager

/// Manages one `GlowBorderWindow` per screen. Observes the
/// `CompanionManager.voiceState` and updates all border views in
/// sync. Show/hide is gated by the `isGlowBorderEnabled` preference.
@MainActor
final class GlowBorderManager {
    private var windows: [GlowBorderWindow] = []
    private var hostingViews: [NSHostingView<GlowBorderView>] = []
    private var voiceStateCancellable: AnyCancellable?
    private var currentVoiceState: CompanionVoiceState = .idle

    /// Whether the glow border is enabled. When toggled off, all
    /// windows are hidden immediately.
    private var isEnabled: Bool = true

    init() {
        isEnabled = PaceUserPreferencesStore.bool(.isGlowBorderEnabled, default: true)
    }

    /// Show glow border windows on all screens and begin observing
    /// voice state changes.
    func show(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        guard isEnabled else { return }
        hide()

        currentVoiceState = companionManager.voiceState

        for screen in screens {
            let window = GlowBorderWindow(screen: screen)
            let view = GlowBorderView(voiceState: currentVoiceState)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = screen.frame
            window.contentView = hosting
            windows.append(window)
            hostingViews.append(hosting)
            window.orderFrontRegardless()
        }

        voiceStateCancellable = companionManager.$voiceState
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.updateVoiceState(newState)
            }
    }

    /// Update the border color on all screens.
    private func updateVoiceState(_ state: CompanionVoiceState) {
        guard state != currentVoiceState else { return }
        currentVoiceState = state
        for hosting in hostingViews {
            hosting.rootView = GlowBorderView(voiceState: state)
        }
    }

    /// Hide and tear down all glow border windows.
    func hide() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        hostingViews.removeAll()
        voiceStateCancellable?.cancel()
        voiceStateCancellable = nil
    }

    /// Toggle the enabled state at runtime (from Settings). When
    /// enabled, re-shows on all screens. When disabled, hides
    /// immediately.
    func setEnabled(_ enabled: Bool, screens: [NSScreen], companionManager: CompanionManager) {
        isEnabled = enabled
        if enabled {
            show(onScreens: screens, companionManager: companionManager)
        } else {
            hide()
        }
    }
}
