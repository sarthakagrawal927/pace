//
//  PaceAvatarOverlay.swift
//  leanring-buddy
//
//  A small walking-character avatar that lives in its own NSPanel.
//  The panel is intentionally tiny (just larger than the character)
//  and moves horizontally along the bottom of the cursor's screen, so
//  the user can still click through to whatever is underneath the
//  rest of the screen. Clicking the avatar opens the menu-bar panel
//  so the existing push-to-talk flow is one hotkey away.
//
//  The character is drawn with SwiftUI shapes — no asset pipeline —
//  and matches the project's brand-blue aesthetic. Idle: gentle bob
//  + occasional blinks. Active (when pace is processing / speaking):
//  the mouth animates open and the character stops walking briefly.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Panel lifecycle

@MainActor
final class PaceAvatarOverlayManager {
    private weak var companionManager: CompanionManager?
    private var avatarPanel: NSPanel?
    private var walkController: PaceAvatarWalkController?
    private var positionUpdateTimer: Timer?
    private var voiceStateCancellable: AnyCancellable?

    private let panelSize = CGSize(width: 64, height: 72)
    /// Distance from the bottom of the visible frame the avatar sits.
    /// Keeps it above the Dock without overlapping app content too much.
    private let bottomMargin: CGFloat = 14

    func attach(to companionManager: CompanionManager) {
        self.companionManager = companionManager
        // Mirror pace's voice state into the character so the mouth
        // animates open during listening / processing / responding.
        voiceStateCancellable = companionManager.$voiceState.sink { [weak self] newVoiceState in
            Task { @MainActor in
                self?.walkController?.updateForVoiceState(newVoiceState)
            }
        }
    }

    /// Returns the screen-space midpoint of the avatar's NSPanel — the
    /// anchor point for the response bubble when a turn was started by
    /// clicking the avatar. nil when the avatar isn't currently shown.
    func currentAvatarAnchorPoint() -> CGPoint? {
        guard let avatarPanel else { return nil }
        let frame = avatarPanel.frame
        return CGPoint(x: frame.midX, y: frame.maxY)
    }

    func show() {
        if let avatarPanel {
            avatarPanel.orderFrontRegardless()
            return
        }

        guard let companionManager else { return }

        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let hostScreen = cursorScreen else { return }
        let hostVisibleFrame = hostScreen.visibleFrame

        let initialPanelOrigin = CGPoint(
            x: hostVisibleFrame.midX - panelSize.width / 2,
            y: hostVisibleFrame.minY + bottomMargin
        )
        let initialPanelFrame = NSRect(origin: initialPanelOrigin, size: panelSize)

        let panel = NSPanel(
            contentRect: initialPanelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Interactive: clicks hit this panel and trigger menu-bar reveal.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false

        let controller = PaceAvatarWalkController(
            screenVisibleFrame: hostVisibleFrame,
            panelSize: panelSize,
            bottomMargin: bottomMargin
        )
        self.walkController = controller

        let hostingView = NSHostingView(
            rootView: PaceAvatarHostView(
                walkController: controller,
                onAvatarClicked: { [weak self] in
                    self?.handleAvatarClick()
                }
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hostingView

        avatarPanel = panel
        panel.orderFrontRegardless()

        // Drive panel position from the controller at 30fps. Position
        // changes are CGFloat deltas in the host visible-frame coord
        // space; we add the screen origin to get global panel coords.
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelFromController()
            }
        }

        _ = companionManager // silence unused for future expansion
    }

    func hide() {
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        walkController = nil
        avatarPanel?.orderOut(nil)
        avatarPanel = nil
    }

    private func repositionPanelFromController() {
        guard let avatarPanel, let walkController else { return }
        let nextOrigin = walkController.currentPanelOrigin()
        avatarPanel.setFrameOrigin(nextOrigin)
    }

    private func handleAvatarClick() {
        // Open the menu-bar panel so the user sees the push-to-talk
        // hint and any active state. The existing hotkey flow (Ctrl+
        // Opt) keeps working as the primary voice trigger.
        NotificationCenter.default.post(name: .paceAvatarTapped, object: nil)
    }
}

extension Notification.Name {
    static let paceAvatarTapped = Notification.Name("PaceAvatarTapped")
}

// MARK: - Walk controller (movement state)

@MainActor
final class PaceAvatarWalkController: ObservableObject {
    /// 0 = leftmost panel position, screenVisibleFrame.width - panelSize.width = rightmost.
    @Published private(set) var horizontalPanelOffset: CGFloat = 0
    @Published private(set) var isFacingLeft: Bool = false
    /// True when pace is listening / processing / responding — the
    /// character pauses walking and animates its mouth.
    @Published private(set) var isInActiveConversationState: Bool = false

    private let screenVisibleFrame: CGRect
    private let panelSize: CGSize
    private let bottomMargin: CGFloat
    private let walkSpeedInPointsPerSecond: CGFloat = 36
    private var lastTickDate: Date = Date()
    private var idleUntilDate: Date?

    private var movementTimer: Timer?

    init(screenVisibleFrame: CGRect, panelSize: CGSize, bottomMargin: CGFloat) {
        self.screenVisibleFrame = screenVisibleFrame
        self.panelSize = panelSize
        self.bottomMargin = bottomMargin
        self.horizontalPanelOffset = (screenVisibleFrame.width - panelSize.width) / 2

        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    deinit {
        movementTimer?.invalidate()
    }

    func updateForVoiceState(_ voiceState: CompanionVoiceState) {
        // Walk while idle, pause for everything else.
        switch voiceState {
        case .idle:
            isInActiveConversationState = false
        case .listening, .processing, .responding:
            isInActiveConversationState = true
        }
    }

    func currentPanelOrigin() -> CGPoint {
        return CGPoint(
            x: screenVisibleFrame.origin.x + horizontalPanelOffset,
            y: screenVisibleFrame.origin.y + bottomMargin
        )
    }

    private func tick() {
        let currentDate = Date()
        let secondsSinceLastTick = currentDate.timeIntervalSince(lastTickDate)
        lastTickDate = currentDate

        if isInActiveConversationState {
            // Active = stand still and wait. Don't even count idle time.
            return
        }

        if let idleUntilDate, currentDate < idleUntilDate {
            return
        }
        idleUntilDate = nil

        let stepDelta = walkSpeedInPointsPerSecond * CGFloat(secondsSinceLastTick)
        let leftBound: CGFloat = 0
        let rightBound = screenVisibleFrame.width - panelSize.width

        if isFacingLeft {
            horizontalPanelOffset -= stepDelta
            if horizontalPanelOffset <= leftBound {
                horizontalPanelOffset = leftBound
                isFacingLeft = false
                considerBriefIdle()
            }
        } else {
            horizontalPanelOffset += stepDelta
            if horizontalPanelOffset >= rightBound {
                horizontalPanelOffset = rightBound
                isFacingLeft = true
                considerBriefIdle()
            }
        }
    }

    /// At each wall, ~40% chance of pausing 1.5-4s before walking back.
    /// Keeps the motion feeling organic instead of metronomic.
    private func considerBriefIdle() {
        guard Double.random(in: 0...1) < 0.4 else { return }
        idleUntilDate = Date().addingTimeInterval(Double.random(in: 1.5...4.0))
    }
}

// MARK: - SwiftUI view

private struct PaceAvatarHostView: View {
    @ObservedObject var walkController: PaceAvatarWalkController
    let onAvatarClicked: () -> Void

    @State private var verticalBobOffset: CGFloat = 0
    @State private var eyelidIsClosed: Bool = false

    var body: some View {
        ZStack {
            PaceAvatarCharacterView(
                isFacingLeft: walkController.isFacingLeft,
                eyelidIsClosed: eyelidIsClosed,
                mouthIsOpen: walkController.isInActiveConversationState
            )
            .offset(y: verticalBobOffset)
            // The whole avatar is tappable. Hit-area is the full panel so
            // the user doesn't need surgical aim on the character body.
            .contentShape(Rectangle())
            .onTapGesture(perform: onAvatarClicked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startIdleBobAnimation()
            scheduleNextBlink()
        }
    }

    private func startIdleBobAnimation() {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            verticalBobOffset = -2.5
        }
    }

    private func scheduleNextBlink() {
        // Random blink every 3-6s.
        let delayInSeconds = Double.random(in: 3...6)
        DispatchQueue.main.asyncAfter(deadline: .now() + delayInSeconds) {
            withAnimation(.easeInOut(duration: 0.10)) {
                eyelidIsClosed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.10)) {
                    eyelidIsClosed = false
                }
                scheduleNextBlink()
            }
        }
    }
}

// MARK: - Character drawing

private struct PaceAvatarCharacterView: View {
    let isFacingLeft: Bool
    let eyelidIsClosed: Bool
    let mouthIsOpen: Bool

    var body: some View {
        ZStack {
            // Body — rounded blob with brand-blue gradient, matching the
            // cursor + voice-pill aesthetic.
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#9EC7FF"),
                            DS.Colors.overlayCursorBlue,
                            Color(hex: "#2563EB")
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 36, height: 46)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.55), radius: 8, x: 0, y: 0)
                .shadow(color: Color.black.opacity(0.30), radius: 2, x: 0, y: 2)

            // Eyes
            HStack(spacing: 7) {
                PaceAvatarEyeView(isClosed: eyelidIsClosed, isLookingLeft: isFacingLeft)
                PaceAvatarEyeView(isClosed: eyelidIsClosed, isLookingLeft: isFacingLeft)
            }
            .offset(y: -6)

            // Mouth — small slit when idle, slightly open oval when active.
            mouthShape
                .offset(y: 10)

            // Tiny feet that step in time with the walk — purely visual
            // and only drawn when not idle, so a still character looks
            // grounded rather than mid-stride.
            HStack(spacing: 14) {
                Capsule()
                    .fill(Color(hex: "#1E40AF"))
                    .frame(width: 6, height: 4)
                Capsule()
                    .fill(Color(hex: "#1E40AF"))
                    .frame(width: 6, height: 4)
            }
            .offset(y: 23)
        }
        .scaleEffect(x: isFacingLeft ? -1 : 1, y: 1)
        .animation(.easeInOut(duration: 0.18), value: isFacingLeft)
    }

    @ViewBuilder
    private var mouthShape: some View {
        if mouthIsOpen {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.65))
                .frame(width: 9, height: 5)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .frame(width: 7, height: 1.4)
        }
    }
}

private struct PaceAvatarEyeView: View {
    let isClosed: Bool
    let isLookingLeft: Bool

    var body: some View {
        ZStack {
            // White sclera
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.4)
                )

            // Pupil slid toward the direction of motion so the
            // character "looks where it's going". Subtle, but the
            // whole thing reads more alive with it on.
            Circle()
                .fill(Color.black)
                .frame(width: 4, height: 4)
                .offset(x: isLookingLeft ? -1.2 : 1.2)

            // Closed eyelid — drawn on top, opaque, when blinking.
            if isClosed {
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(Color(hex: "#1E40AF"))
                    .frame(width: 8, height: 1.4)
            }
        }
        .frame(width: 8, height: 8)
    }
}
