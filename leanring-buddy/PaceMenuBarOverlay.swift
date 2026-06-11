//
//  PaceMenuBarOverlay.swift
//  leanring-buddy
//
//  Draws the Pace capsule directly over the macOS menu-bar notch area.
//  This is intentionally an overlay panel rather than an NSStatusItem:
//  status items can be reordered or hidden by macOS and third-party menu
//  bar managers, while this surface needs to visually extend the notch.
//

import AppKit
import SwiftUI

private enum PaceMenuBarOverlayMetrics {
    static let width: CGFloat = 292
    static let height: CGFloat = 34
    static let bottomCornerRadius: CGFloat = 16
    static let centerOffsetX: CGFloat = 2
    static let iconSlotWidth: CGFloat = 32
    static let iconSlotHeight: CGFloat = 24
    static let sideClusterWidth: CGFloat = iconSlotWidth
}

private final class PaceMenuBarOverlayPanel: NSPanel {
    var onMouseDown: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            onMouseDown?()
            return
        }
        super.sendEvent(event)
    }
}

private final class PaceMenuBarOverlayHostingView<Content: View>: NSHostingView<Content> {
    var onMouseDown: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

@MainActor
final class PaceMenuBarOverlayManager {
    private weak var companionManager: CompanionManager?
    private var overlayPanel: NSPanel?
    private let onTap: (NSRect) -> Void

    private let overlayWidth: CGFloat = PaceMenuBarOverlayMetrics.width
    private let overlayHeight: CGFloat = PaceMenuBarOverlayMetrics.height

    init(companionManager: CompanionManager, onTap: @escaping (NSRect) -> Void) {
        self.companionManager = companionManager
        self.onTap = onTap

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        if overlayPanel == nil {
            createOverlayPanel()
        }
        positionOverlayPanel()
        overlayPanel?.orderFrontRegardless()
    }

    func hide() {
        overlayPanel?.orderOut(nil)
    }

    private func createOverlayPanel() {
        guard let companionManager else { return }

        let overlayView = PaceMenuBarOverlayView(companionManager: companionManager)
        .frame(width: overlayWidth, height: overlayHeight)

        let hostingView = PaceMenuBarOverlayHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = PaceMenuBarOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.onMouseDown = { [weak self] in
            self?.handleTap()
        }
        panel.contentView = hostingView

        overlayPanel = panel
    }

    private func positionOverlayPanel() {
        guard let panel = overlayPanel else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let overlayOriginX = screen.frame.midX - (overlayWidth / 2) + PaceMenuBarOverlayMetrics.centerOffsetX
        let overlayOriginY = (screen.frame.maxY - overlayHeight).rounded(.down)

        panel.setFrame(
            NSRect(x: overlayOriginX, y: overlayOriginY, width: overlayWidth, height: overlayHeight),
            display: true
        )
    }

    private func handleTap() {
        guard let overlayPanel else { return }
        onTap(overlayPanel.frame)
    }

    @objc private func screenParametersDidChange() {
        positionOverlayPanel()
    }
}

private struct PaceMenuBarOverlayView: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            PaceMenuBarIconCluster {
                PaceMenuBarIconSlot {
                    PaceMenuBarAvatarGlyph(
                        voiceState: companionManager.voiceState,
                        reduceMotion: reduceMotion
                    )
                        .frame(width: 18, height: 18)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.74), value: isConversationActive)

            Spacer(minLength: 0)

            PaceMenuBarIconCluster {
                PaceMenuBarIconSlot {
                    PaceMenuBarSoundGlyph(
                        isConversationActive: isConversationActive,
                        voiceState: companionManager.voiceState,
                        audioPowerLevel: companionManager.currentAudioPowerLevel,
                        reduceMotion: reduceMotion,
                        isCloudBridgeCallActive: companionManager.isCloudBridgeCallActive
                    )
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72), value: isConversationActive)
        }
        .padding(.horizontal, 8)
        .frame(width: PaceMenuBarOverlayMetrics.width, height: PaceMenuBarOverlayMetrics.height)
        .background(
            PaceMenuBarBottomRoundedShape(bottomCornerRadius: PaceMenuBarOverlayMetrics.bottomCornerRadius)
                .fill(Color.black.opacity(0.98))
                .overlay(
                    PaceMenuBarBottomRoundedShape(bottomCornerRadius: PaceMenuBarOverlayMetrics.bottomCornerRadius)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .contentShape(PaceMenuBarBottomRoundedShape(bottomCornerRadius: PaceMenuBarOverlayMetrics.bottomCornerRadius))
        .pointerCursor()
        .accessibilityLabel(statusText)
    }

    private var isConversationActive: Bool {
        companionManager.voiceState != .idle
    }

    private var statusText: String {
        guard companionManager.allPermissionsGranted else {
            return "Setup"
        }

        switch companionManager.voiceState {
        case .idle:
            return companionManager.isLMStudioReachable ? "Pace" : "Local offline"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

}

private struct PaceMenuBarIconCluster<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .frame(
            width: PaceMenuBarOverlayMetrics.sideClusterWidth,
            height: PaceMenuBarOverlayMetrics.iconSlotHeight,
            alignment: .center
        )
    }
}

private struct PaceMenuBarIconSlot<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                )

            content
        }
        .frame(
            width: PaceMenuBarOverlayMetrics.iconSlotWidth,
            height: PaceMenuBarOverlayMetrics.iconSlotHeight
        )
        .shadow(color: Color(hex: "#38BDF8").opacity(0.13), radius: 5, x: 0, y: 0)
    }
}

private struct PaceMenuBarSoundGlyph: View {
    let isConversationActive: Bool
    let voiceState: CompanionVoiceState
    let audioPowerLevel: CGFloat
    let reduceMotion: Bool
    /// When true, tints the right-icon slot amber (#FFB347) to show that a
    /// cloud-bridge call is actively streaming. Makes egress always visible.
    let isCloudBridgeCallActive: Bool

    var body: some View {
        ZStack {
            if isConversationActive {
                PaceMenuBarSoundBars(
                    voiceState: voiceState,
                    audioPowerLevel: audioPowerLevel,
                    reduceMotion: reduceMotion,
                    isCloudBridgeCallActive: isCloudBridgeCallActive
                )
                .transition(reduceMotion ? .identity : .scale(scale: 0.76, anchor: .trailing).combined(with: .opacity))
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12.2, weight: .bold))
                    .foregroundStyle(
                        isCloudBridgeCallActive
                            ? Color(hex: "#FFB347").opacity(0.95)
                            : Color(hex: "#67E8F9").opacity(0.95)
                    )
                    .transition(reduceMotion ? .identity : .scale(scale: 0.82, anchor: .trailing).combined(with: .opacity))
            }
        }
    }
}

private struct PaceMenuBarSoundBars: View {
    let voiceState: CompanionVoiceState
    let audioPowerLevel: CGFloat
    let reduceMotion: Bool
    /// When true, bars render in amber (#FFB347) instead of the default cyan/blue
    /// gradient to signal that a cloud-bridge call is in flight.
    let isCloudBridgeCallActive: Bool

    private let barHeightProfile: [CGFloat] = [0.46, 0.76, 1.0, 0.76, 0.46]

    var body: some View {
        if reduceMotion {
            HStack(spacing: 2.2) {
                ForEach(0..<barHeightProfile.count, id: \.self) { barIndex in
                    soundBar(at: barIndex, height: staticBarHeight(for: barIndex))
                }
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
                HStack(spacing: 2.2) {
                    ForEach(0..<barHeightProfile.count, id: \.self) { barIndex in
                        soundBar(at: barIndex, height: animatedBarHeight(for: barIndex, at: timelineContext.date))
                    }
                }
            }
        }
    }

    private func soundBar(at barIndex: Int, height: CGFloat) -> some View {
        let topBarColor = isCloudBridgeCallActive ? Color(hex: "#FFB347") : activeAccentColor
        let bottomBarColor = isCloudBridgeCallActive ? Color(hex: "#FF8C00") : Color(hex: "#67E8F9")
        return RoundedRectangle(cornerRadius: 1.1, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [topBarColor, bottomBarColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 2.3, height: height)
            .shadow(color: topBarColor.opacity(reduceMotion ? 0.22 : 0.42), radius: reduceMotion ? 1.5 : 3, x: 0, y: 0)
    }

    private func animatedBarHeight(for barIndex: Int, at date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * waveSpeed) + CGFloat(barIndex) * 0.68
        let normalizedAudioPower = max(audioPowerLevel - 0.008, 0)
        let reactiveHeight = pow(min(normalizedAudioPower * 3.2, 1), 0.7) * 8 * barHeightProfile[barIndex]
        let idlePulse = (sin(phase) + 1) * 3.2 * barHeightProfile[barIndex]
        return 5 + reactiveHeight + idlePulse
    }

    private func staticBarHeight(for barIndex: Int) -> CGFloat {
        switch voiceState {
        case .idle:
            return 5 + 3 * barHeightProfile[barIndex]
        case .listening:
            return 6 + 7 * barHeightProfile[barIndex]
        case .processing:
            return 8 + 5 * barHeightProfile[barIndex]
        case .responding:
            return 6 + 6 * barHeightProfile[barIndex]
        }
    }

    private var waveSpeed: Double {
        switch voiceState {
        case .idle: return 3.0
        case .listening: return 4.2
        case .processing: return 5.0
        case .responding: return 3.6
        }
    }

    private var activeAccentColor: Color {
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
}

private struct PaceMenuBarBottomRoundedShape: Shape {
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomCornerRadius, rect.width / 2, rect.height)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

private struct PaceMenuBarAvatarGlyph: View {
    let voiceState: CompanionVoiceState
    let reduceMotion: Bool
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(avatarGlowColor.opacity(0.32), lineWidth: 1.5)
                    .scaleEffect(reduceMotion ? 1.02 : (isPulsing ? 1.15 : 0.96))
                    .opacity(reduceMotion ? 0.22 : (isPulsing ? 0.08 : 0.42))
            }

            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: avatarGradientColors,
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .stroke(Color.white.opacity(0.30), lineWidth: 0.7)
                )
                .shadow(color: avatarGlowColor.opacity(0.34), radius: 4.5, x: 0, y: 0)

            VStack(spacing: 2.4) {
                HStack(spacing: 3.2) {
                    Capsule()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 3.2, height: eyeHeight)

                    Capsule()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 3.2, height: trailingEyeHeight)
                }

                Capsule()
                    .fill(Color.white.opacity(isActive ? 0.58 : 0.36))
                    .frame(width: isActive ? 8.2 : 6.8, height: 1.5)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: voiceState)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.62), value: isPulsing)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            if reduceMotion {
                isPulsing = false
            } else {
                withAnimation(.easeInOut(duration: 0.86).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

    private var eyeHeight: CGFloat {
        if reduceMotion {
            return voiceState == .idle ? 3.5 : 4.8
        }

        switch voiceState {
        case .idle:
            return 3.5
        case .listening:
            return isPulsing ? 6.2 : 3.8
        case .processing:
            return isPulsing ? 4.6 : 5.8
        case .responding:
            return isPulsing ? 5.6 : 3.8
        }
    }

    private var trailingEyeHeight: CGFloat {
        if reduceMotion {
            return voiceState == .idle ? 3.5 : 4.8
        }

        switch voiceState {
        case .idle:
            return 3.5
        case .listening:
            return isPulsing ? 4.0 : 6.0
        case .processing:
            return isPulsing ? 5.8 : 4.6
        case .responding:
            return isPulsing ? 3.8 : 5.6
        }
    }

    private var avatarGradientColors: [Color] {
        switch voiceState {
        case .idle:
            return [Color(hex: "#0369A1"), Color(hex: "#22D3EE")]
        case .listening:
            return [Color(hex: "#047857"), Color(hex: "#34D399")]
        case .processing:
            return [Color(hex: "#2563EB"), Color(hex: "#A78BFA")]
        case .responding:
            return [Color(hex: "#7C3AED"), Color(hex: "#22D3EE")]
        }
    }

    private var avatarGlowColor: Color {
        switch voiceState {
        case .idle:
            return Color(hex: "#38BDF8")
        case .listening:
            return Color(hex: "#34D399")
        case .processing:
            return Color(hex: "#60A5FA")
        case .responding:
            return Color(hex: "#A78BFA")
        }
    }

    private var isActive: Bool {
        voiceState != .idle
    }
}
