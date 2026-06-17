//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. Voice-state animation now lives in the
// menu-bar/notch surface; this overlay is kept for cursor flight,
// pointing, and response placement.
struct BlueCursorView: View {
    let screenFrame: CGRect
    /// 1-based index in the order `OverlayWindowManager.showOverlay`
    /// walked the screens. Same numbering the planner uses for the
    /// `screen` field in `click` / `draw_annotation` / `[POINT]`, so the
    /// tuition-mode annotation layer can filter to "shapes on THIS
    /// screen only".
    let screenIndex: Int
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var annotationOverlayController: PaceAnnotationOverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(
        screenFrame: CGRect,
        screenIndex: Int,
        isFirstAppearance: Bool,
        companionManager: CompanionManager
    ) {
        self.screenFrame = screenFrame
        self.screenIndex = screenIndex
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.annotationOverlayController = companionManager.annotationOverlayController

        // Seed the cursor position from the avatar's current anchor so the
        // buddy doesn't flash at (0,0) before onAppear fires. If the avatar
        // isn't showing yet, park off-screen and let onAppear reposition.
        if let avatarScreenPoint = companionManager.avatarOverlayManager?.currentAvatarAnchorPoint() {
            let parkInLocalCoords = Self.parkCoordinatesForAvatarScreenPoint(
                avatarScreenPoint,
                onScreenWithFrame: screenFrame
            )
            _cursorPosition = State(initialValue: parkInLocalCoords)
            _isCursorOnThisScreen = State(initialValue: screenFrame.contains(avatarScreenPoint))
        } else {
            _cursorPosition = State(initialValue: CGPoint(x: -200, y: -200))
            _isCursorOnThisScreen = State(initialValue: false)
        }
    }

    /// Computes the SwiftUI-local coordinate where the cursor should park
    /// given the avatar's anchor point in global AppKit (screen) coords.
    /// Static so the init can call it before `self` is fully formed.
    private static func parkCoordinatesForAvatarScreenPoint(
        _ avatarScreenPoint: CGPoint,
        onScreenWithFrame screenFrame: CGRect
    ) -> CGPoint {
        let localX = avatarScreenPoint.x - screenFrame.origin.x
        let localY = screenFrame.height - (avatarScreenPoint.y - screenFrame.origin.y)
        // Offset so the cursor sits visibly above-and-right of the avatar's
        // head, not overlapping the character body.
        return CGPoint(x: localX + 20, y: localY - 16)
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Undo banner state

    /// Mirror of the manager's most-recent reversible-action timestamp,
    /// re-evaluated on every render so the banner can hide itself after
    /// the 5-second visibility window expires without subscribing to a
    /// per-second timer. Driven by `scheduleUndoBannerVisibilityRefresh`.
    @State private var undoBannerShouldRender: Bool = false

    /// Per-banner tick task — sleeps the visibility window then flips
    /// `undoBannerShouldRender` false. Kept as state so repeated
    /// reversible actions can cancel the prior tick and restart fresh.
    @State private var undoBannerHideTask: Task<Void, Never>?

    /// 5-second visibility window from PRD docs/prds/trust-and-failures.md.
    private let undoBannerVisibilityWindowSeconds: TimeInterval = 5

    private let fullWelcomeMessage = "hey! i'm pace"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Tuition-mode annotation layer. Sits BELOW the cursor and
            // bubbles so a teaching rectangle never visually obscures
            // the blue arrow. `.allowsHitTesting(false)` keeps the
            // overlay click-through — drawing a shape over a button
            // never blocks the user clicking that button.
            PaceAnnotationLayerView(
                annotations: annotationOverlayController.activeAnnotations
                    .filter { $0.screenIndex == screenIndex },
                pixelToLocal: { appKitPoint in
                    convertScreenPointToSwiftUICoordinates(appKitPoint)
                }
            )
            .allowsHitTesting(false)

            // Welcome speech bubble (first launch only)
            if companionManager.areCursorAnnotationsEnabled
                && isCursorOnThisScreen
                && showWelcome
                && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if companionManager.areCursorAnnotationsEnabled
                && buddyNavigationMode == .pointingAtTarget
                && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown only while Pace is flying/pointing
            // at a detected screen element. All voice-state animation lives in
            // the notch bar so the conversation never animates beside the
            // mouse cursor.
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            // Codex-style arrow cursor: gradient fill from light cyan through
            // the brand blue, plus a thin top-edge highlight stroke for that
            // beveled, slightly metallic look the Codex CLI pointer has. The
            // overall silhouette is the CodexArrowShape — taller than wide
            // with a concave notch at the base.
            ZStack {
                CodexArrowShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "#7FB8FF"),
                                DS.Colors.overlayCursorBlue,
                                Color(hex: "#2563EB")
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                CodexArrowShape()
                    .stroke(
                        Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round)
                    )
                    .blendMode(.plusLighter)
            }
                .frame(width: 18, height: 22)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.85), radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                .scaleEffect(buddyFlightScale)
                .opacity(arrowShouldBeVisible ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    !reduceMotion && buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(
                    reduceMotion || buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Undo banner — appears for 5 seconds after every reversible
            // mutation Pace executes (note created, mail draft started,
            // reminder added, etc.). Tapping it submits `Undo.last` via
            // the executor. See PRD docs/prds/trust-and-failures.md.
            if let summary = companionManager.mostRecentReversibleActionSummary,
               undoBannerShouldRender,
               isCursorOnThisScreen {
                PaceUndoBanner(
                    summaryText: summary,
                    onUndoTapped: {
                        companionManager.triggerUndoLastMutation()
                    }
                )
                .position(
                    x: cursorPosition.x + 20,
                    y: cursorPosition.y + 44
                )
                .transition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: undoBannerShouldRender)
            }

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onChange(of: companionManager.mostRecentReversibleActionAt) { _, newTimestamp in
            scheduleUndoBannerVisibilityRefresh(triggeredAt: newTimestamp)
        }
        .onAppear {
            // Snap to the avatar's current position immediately, then keep
            // tracking. The cursor stays parked next to the walking character;
            // it no longer follows the user's mouse.
            if let avatarScreenPoint = companionManager.avatarOverlayManager?.currentAvatarAnchorPoint() {
                isCursorOnThisScreen = screenFrame.contains(avatarScreenPoint)
                self.cursorPosition = Self.parkCoordinatesForAvatarScreenPoint(
                    avatarScreenPoint,
                    onScreenWithFrame: screenFrame
                )
            }

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                if reduceMotion {
                    self.cursorOpacity = 1.0
                } else {
                    withAnimation(.easeIn(duration: 2.0)) {
                        self.cursorOpacity = 1.0
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { _, newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    /// Whether the arrow cursor should be rendered right now. Hidden when
    /// nothing's happening so it doesn't hover idly next to the avatar.
    /// Voice-state activity is represented only in the notch bar. The cursor
    /// appears for explicit pointing/navigation, where the user asked Pace to
    /// indicate an on-screen target.
    private var arrowShouldBeVisible: Bool {
        guard buddyIsVisibleOnThisScreen else { return false }
        return buddyNavigationMode != .followingCursor
    }

    /// Flips `undoBannerShouldRender` true when a reversible action
    /// has just fired, then schedules a single async task to flip it
    /// back to false after the 5-second window. Repeated mutations
    /// cancel the prior task and restart the timer.
    private func scheduleUndoBannerVisibilityRefresh(triggeredAt: Date?) {
        guard let triggeredAt else {
            undoBannerShouldRender = false
            undoBannerHideTask?.cancel()
            undoBannerHideTask = nil
            return
        }
        let elapsedSeconds = Date().timeIntervalSince(triggeredAt)
        let remainingSeconds = undoBannerVisibilityWindowSeconds - elapsedSeconds
        guard remainingSeconds > 0 else {
            undoBannerShouldRender = false
            return
        }
        undoBannerShouldRender = true
        undoBannerHideTask?.cancel()
        let hideAfterNanos = UInt64(remainingSeconds * 1_000_000_000)
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hideAfterNanos)
            guard !Task.isCancelled else { return }
            undoBannerShouldRender = false
            companionManager.clearReversibleActionUndoState()
        }
        undoBannerHideTask = task
    }

    private func startTrackingCursor() {
        // Poll the avatar's position 30× per second. The cursor is anchored
        // to the walking avatar (which strolls along the bottom of the
        // screen), so as the avatar moves the cursor moves with it. Mouse
        // position is no longer consulted — the user's pointer can wander
        // anywhere without disturbing pace.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            // The timer is scheduled on the main run loop, so its fire always
            // lands on the main actor. `assumeIsolated` lets the body touch the
            // MainActor-isolated view state without spawning a Task hop (which
            // would jitter the 30 Hz cursor tracking).
            MainActor.assumeIsolated {
                // During any active flight or pointing, the bezier animator owns
                // the cursor position frame-by-frame. Don't fight it.
                if self.buddyNavigationMode != .followingCursor {
                    return
                }

                guard let avatarScreenPoint = self.companionManager.avatarOverlayManager?.currentAvatarAnchorPoint() else {
                    // Avatar isn't visible right now (e.g. user disabled it).
                    // Leave the cursor where it was — opacity is already gated
                    // by voice state so it won't be visible anyway at rest.
                    return
                }

                self.isCursorOnThisScreen = self.screenFrame.contains(avatarScreenPoint)
                self.cursorPosition = Self.parkCoordinatesForAvatarScreenPoint(
                    avatarScreenPoint,
                    onScreenWithFrame: self.screenFrame
                )
            }
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the buddy's launch position. With avatar-following, the
        // return flight always targets the (possibly walked-elsewhere)
        // avatar at the time of return, so this is informational rather
        // than load-bearing for cancel logic.
        cursorPositionWhenNavigationStarted = cursorPosition

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        if reduceMotion {
            navigationAnimationTimer?.invalidate()
            navigationAnimationTimer = nil
            cursorPosition = clampedTarget
            buddyFlightScale = 1.0
            triangleRotationDegrees = -35.0
            startPointingAtElement()
            return
        }

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        if reduceMotion {
            cursorPosition = endPosition
            buddyFlightScale = 1.0
            triangleRotationDegrees = -35.0
            onComplete()
            return
        }

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = reduceMotion ? 1.0 : 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        if reduceMotion {
            navigationBubbleText = pointerPhrase
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                self.startFlyingBackToCursor()
            }
            return
        }

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the avatar's current position after
    /// pointing is done. The cursor's home base is the walking avatar,
    /// not the user's mouse.
    private func startFlyingBackToCursor() {
        let returnDestination: CGPoint = {
            if let avatarScreenPoint = companionManager.avatarOverlayManager?.currentAvatarAnchorPoint() {
                return Self.parkCoordinatesForAvatarScreenPoint(
                    avatarScreenPoint,
                    onScreenWithFrame: screenFrame
                )
            }
            // Avatar not visible — return to wherever the cursor currently
            // sits rather than flying off to (0,0).
            return cursorPosition
        }()

        cursorPositionWhenNavigationStarted = returnDestination

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: returnDestination) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        if reduceMotion {
            bubbleOpacity = 1.0
            welcomeText = fullWelcomeMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.bubbleOpacity = 0.0
                self.showWelcome = false
            }
            return
        }

        withAnimation(.easeIn(duration: 0.4)) {
            bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Whisper Flow-style voice input pill

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    /// When true, the blue cursor companion never shows. Set in mascot mode
    /// so all conversation surfaces live at the top-right perch, never near
    /// the mouse pointer.
    var isSuppressed = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        guard !isSuppressed else { return }
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen. `screenIndex` is the
        // 1-based screen number matching the planner's `screen` field
        // (and the `[POINT]` tag), so the annotation layer can filter
        // its shapes to the right display.
        for (zeroBasedScreenIndex, screen) in screens.enumerated() {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                screenIndex: zeroBasedScreenIndex + 1,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

}

// MARK: - Pace undo banner
//
// Small floating button that appears below the cursor for 5 seconds
// after every reversible mutation Pace executes. Tapping it submits
// `Undo.last` through the executor. Lives inside the existing
// non-activating cursor overlay so it never steals focus.
//
// Visual style is intentionally muted (low-alpha background, no glow)
// so it doesn't compete with the primary cursor pip.

struct PaceUndoBanner: View {
    let summaryText: String
    let onUndoTapped: () -> Void

    var body: some View {
        Button(action: onUndoTapped) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("undo: \(summaryText)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 1)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

// MARK: - Tuition-mode annotation overlay
//
// `PaceAnnotationLayerView` and `PaceAnnotationShapeView` render the
// teaching shapes that the planner's `draw_annotation` tool produces.
// Geometry arrives in AppKit-global coordinates (already converted by
// `PaceAnnotationActionDrainer`); this layer applies the same
// AppKit-to-SwiftUI mapping the cursor uses, paints the shape, and
// optionally renders a small caption pill.

private struct PaceAnnotationLayerView: View {
    let annotations: [PaceRenderedAnnotation]
    /// AppKit-global → SwiftUI-local point conversion. Injected from
    /// `BlueCursorView` so the layer doesn't need its own copy of
    /// `screenFrame` math.
    let pixelToLocal: (CGPoint) -> CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(annotations) { annotation in
                PaceAnnotationShapeView(
                    annotation: annotation,
                    pixelToLocal: pixelToLocal
                )
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        // ID change is the right trigger here: it fires when shapes are
        // added/removed but not when, say, the cursor moves. Mapping
        // through `id` keeps the transition lightweight.
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: annotations.map(\.id)
        )
    }
}

private struct PaceAnnotationShapeView: View {
    let annotation: PaceRenderedAnnotation
    let pixelToLocal: (CGPoint) -> CGPoint

    var body: some View {
        ZStack {
            shapePath
            labelPill
        }
    }

    @ViewBuilder
    private var shapePath: some View {
        let color = swiftUIColor(for: annotation.style.color)
        let strokeWidth = CGFloat(annotation.style.strokeWidth)
        switch annotation.geometry {
        case .rect(let appKitRect):
            // Map both corners of the AppKit-global rect into local
            // SwiftUI coords. The y-axis flip means the rect's max-y
            // corner becomes the SwiftUI rect's MIN-y corner.
            let topLeftLocal = pixelToLocal(CGPoint(x: appKitRect.minX, y: appKitRect.maxY))
            let bottomRightLocal = pixelToLocal(CGPoint(x: appKitRect.maxX, y: appKitRect.minY))
            let localRect = normalizedLocalRect(topLeftLocal: topLeftLocal, bottomRightLocal: bottomRightLocal)
            ZStack {
                if annotation.style.filled {
                    Rectangle()
                        .fill(color.opacity(0.18))
                        .frame(width: localRect.width, height: localRect.height)
                        .position(x: localRect.midX, y: localRect.midY)
                }
                Rectangle()
                    .stroke(color, lineWidth: strokeWidth)
                    .frame(width: localRect.width, height: localRect.height)
                    .position(x: localRect.midX, y: localRect.midY)
            }
        case .ellipse(let appKitRect):
            let topLeftLocal = pixelToLocal(CGPoint(x: appKitRect.minX, y: appKitRect.maxY))
            let bottomRightLocal = pixelToLocal(CGPoint(x: appKitRect.maxX, y: appKitRect.minY))
            let localRect = normalizedLocalRect(topLeftLocal: topLeftLocal, bottomRightLocal: bottomRightLocal)
            ZStack {
                if annotation.style.filled {
                    Ellipse()
                        .fill(color.opacity(0.18))
                        .frame(width: localRect.width, height: localRect.height)
                        .position(x: localRect.midX, y: localRect.midY)
                }
                Ellipse()
                    .stroke(color, lineWidth: strokeWidth)
                    .frame(width: localRect.width, height: localRect.height)
                    .position(x: localRect.midX, y: localRect.midY)
            }
        case .line(let start, let end):
            let startLocal = pixelToLocal(start)
            let endLocal = pixelToLocal(end)
            Path { path in
                path.move(to: startLocal)
                path.addLine(to: endLocal)
            }
            .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        case .arrow(let tail, let head):
            let tailLocal = pixelToLocal(tail)
            let headLocal = pixelToLocal(head)
            Path { path in
                path.move(to: tailLocal)
                path.addLine(to: headLocal)
                // Two head segments at ±20° from the shaft, 14pt long.
                // Drawn from `headLocal` back toward `tailLocal`.
                let shaftAngle = atan2(headLocal.y - tailLocal.y, headLocal.x - tailLocal.x)
                let arrowheadLength: CGFloat = 14
                let arrowheadSpread: CGFloat = .pi / 9
                let leftAngle = shaftAngle + .pi - arrowheadSpread
                let rightAngle = shaftAngle + .pi + arrowheadSpread
                path.move(to: headLocal)
                path.addLine(to: CGPoint(
                    x: headLocal.x + cos(leftAngle) * arrowheadLength,
                    y: headLocal.y + sin(leftAngle) * arrowheadLength
                ))
                path.move(to: headLocal)
                path.addLine(to: CGPoint(
                    x: headLocal.x + cos(rightAngle) * arrowheadLength,
                    y: headLocal.y + sin(rightAngle) * arrowheadLength
                ))
            }
            .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
        case .polygon(let appKitVertices):
            // Parser already rejects polygons with <3 vertices, but a
            // belt-and-braces empty check keeps the SwiftUI body
            // total in case the type ever loosens.
            let localVertices = appKitVertices.map(pixelToLocal)
            if localVertices.isEmpty {
                EmptyView()
            } else {
                ZStack {
                    if annotation.style.filled {
                        Path { path in
                            path.move(to: localVertices[0])
                            for vertex in localVertices.dropFirst() {
                                path.addLine(to: vertex)
                            }
                            path.closeSubpath()
                        }
                        .fill(color.opacity(0.18))
                    }
                    Path { path in
                        path.move(to: localVertices[0])
                        for vertex in localVertices.dropFirst() {
                            path.addLine(to: vertex)
                        }
                        path.closeSubpath()
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    @ViewBuilder
    private var labelPill: some View {
        if let labelText = annotation.style.label {
            let anchorLocal = labelAnchorLocalPoint()
            Text(labelText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(swiftUIColor(for: annotation.style.color).opacity(0.95))
                )
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                .position(x: anchorLocal.x, y: anchorLocal.y)
        }
    }

    /// Where the caption pill sits relative to the shape. Picked
    /// per-kind so the label rarely overlaps the shape itself.
    private func labelAnchorLocalPoint() -> CGPoint {
        switch annotation.geometry {
        case .rect(let appKitRect), .ellipse(let appKitRect):
            // Above the top-left corner, offset up so the pill doesn't
            // sit on the stroke.
            let topLeftLocal = pixelToLocal(CGPoint(x: appKitRect.minX, y: appKitRect.maxY))
            return CGPoint(x: topLeftLocal.x + 22, y: max(8, topLeftLocal.y - 10))
        case .line(let start, let end), .arrow(let start, let end):
            let startLocal = pixelToLocal(start)
            let endLocal = pixelToLocal(end)
            return CGPoint(
                x: (startLocal.x + endLocal.x) / 2,
                y: (startLocal.y + endLocal.y) / 2 - 12
            )
        case .polygon(let appKitVertices):
            let localVertices = appKitVertices.map(pixelToLocal)
            // Topmost vertex (smallest y in SwiftUI coords), label sits
            // above it.
            guard let topmost = localVertices.min(by: { $0.y < $1.y }) else {
                return .zero
            }
            return CGPoint(x: topmost.x, y: max(8, topmost.y - 10))
        }
    }

    /// Map the named planner palette to a concrete SwiftUI color.
    /// Lives here rather than on `PaceAnnotationColor` so the value
    /// type stays AppKit/SwiftUI-free.
    private func swiftUIColor(for color: PaceAnnotationColor) -> Color {
        switch color {
        case .red: return DS.Colors.annotationRed
        case .blue: return DS.Colors.annotationBlue
        case .green: return DS.Colors.annotationGreen
        case .yellow: return DS.Colors.annotationYellow
        case .orange: return DS.Colors.annotationOrange
        }
    }

    /// Compose a SwiftUI-local CGRect from the two AppKit-global
    /// corners passed through `pixelToLocal`. Width/height end up
    /// positive regardless of corner orientation — the y-axis flip
    /// means the AppKit "top-left" is the SwiftUI "top-left" only when
    /// signs line up.
    private func normalizedLocalRect(topLeftLocal: CGPoint, bottomRightLocal: CGPoint) -> CGRect {
        let minX = min(topLeftLocal.x, bottomRightLocal.x)
        let minY = min(topLeftLocal.y, bottomRightLocal.y)
        let width = abs(bottomRightLocal.x - topLeftLocal.x)
        let height = abs(bottomRightLocal.y - topLeftLocal.y)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}

// (Onboarding-video player NSViewRepresentable removed — Pace no longer
// plays an intro video.)
