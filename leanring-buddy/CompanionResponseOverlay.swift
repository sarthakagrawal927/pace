//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Cursor-following overlay that displays streaming AI response text.
//  Uses a non-activating NSPanel so it floats above all apps without
//  stealing focus, and repositions itself near the mouse cursor each frame.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
    /// True while the user is actively recording audio. Drives the
    /// stop-button affordance in the bubble — manual escape hatch since
    /// silence-based auto-end was yanked.
    @Published var isListeningForAudio: Bool = false
    /// Invoked when the user taps the stop button in the bubble.
    /// CompanionManager hands the manager a closure that wires through
    /// to `simulateShortcutReleased`.
    var onStopButtonTapped: (@MainActor () -> Void)?
}

// MARK: - Overlay Manager

/// Where AND how the response bubble pins itself for the duration of
/// a turn. The two cases use different placement geometry:
///
/// - `.belowRightOfCursor`: standard tooltip placement, right + below
///   the mouse. Default for keyboard-triggered turns where the user is
///   looking at their cursor anyway.
///
/// - `.aboveCenterOf(provider:)`: panel sits centered above the
///   provider point. Used for avatar-triggered turns so the bubble
///   floats above the walking character (the avatar is at the bottom
///   of the screen, so "below" placement would push the bubble offscreen
///   or behind the Dock).
enum CompanionResponseOverlayAnchor {
    case belowRightOfCursor
    case aboveCenterOf(provider: @MainActor () -> CGPoint?)
}

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var autoHideWorkItem: DispatchWorkItem?
    private var currentAnchor: CompanionResponseOverlayAnchor = .belowRightOfCursor
    private var annotationsAreEnabled = true

    /// Tracks the global mouse so the bubble actually follows the
    /// cursor while it's visible. Set up once on first show; torn down
    /// on hide. Without this the bubble snaps to where the cursor was
    /// at show-time and then stays there even if the cursor moves —
    /// breaking the "bubble + arrow are one unit" expectation.
    private var globalMouseMovedMonitor: Any?

    /// The horizontal offset from the anchor to the left edge of the overlay panel.
    private let anchorOffsetX: CGFloat = 22
    /// The vertical offset downward from the anchor to the top edge of the overlay panel.
    private let anchorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 340

    /// Set the anchor before calling `showOverlayAndBeginStreaming`. The
    /// anchor is read once on show; subsequent reposition requests use
    /// the same anchor (so the bubble stays pinned to where the turn
    /// started).
    func setAnchor(_ newAnchor: CompanionResponseOverlayAnchor) {
        currentAnchor = newAnchor
    }

    func setAnnotationsEnabled(_ enabled: Bool) {
        annotationsAreEnabled = enabled
        if !enabled {
            hideOverlay()
        }
    }

    /// Toggle the stop button on/off. Called by CompanionManager when
    /// dictation enters / leaves the listening state.
    func setListeningForAudio(_ isListening: Bool) {
        overlayViewModel.isListeningForAudio = isListening
    }

    /// Wire the stop button's tap callback. CompanionManager passes
    /// through to `simulateShortcutReleased`.
    func setStopButtonCallback(_ callback: @escaping @MainActor () -> Void) {
        overlayViewModel.onStopButtonTapped = callback
    }

    func showOverlayAndBeginStreaming() {
        guard annotationsAreEnabled else { return }
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.streamingResponseText = ""
        overlayViewModel.isShowingResponse = true
        createOverlayPanelIfNeeded()
        repositionPanelToAnchor()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
        installCursorTrackingMonitorIfNeeded()
    }

    /// Subscribe to global mouseMoved events so the bubble's NSPanel
    /// follows the cursor while it's visible. Idempotent — only one
    /// monitor is installed at a time. Removed in `hide()`.
    private func installCursorTrackingMonitorIfNeeded() {
        guard globalMouseMovedMonitor == nil else { return }
        globalMouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelToAnchor()
            }
        }
    }

    private func tearDownCursorTrackingMonitor() {
        if let globalMouseMovedMonitor {
            NSEvent.removeMonitor(globalMouseMovedMonitor)
        }
        globalMouseMovedMonitor = nil
    }

    func updateStreamingText(_ accumulatedText: String) {
        guard annotationsAreEnabled else { return }
        overlayViewModel.streamingResponseText = accumulatedText
        resizePanelToFitContent()
    }

    /// Schedules the bubble's fade-out. If `keepVisibleUntil` is
    /// provided, the bubble waits until that async predicate returns
    /// false before fading (e.g. "still TTS playing?"). Otherwise it
    /// falls back to a fixed 6-second timer so it doesn't sit forever.
    func finishStreaming(keepVisibleUntil: (@MainActor @Sendable () async -> Bool)? = nil) {
        guard annotationsAreEnabled else { return }
        autoHideWorkItem?.cancel()

        if let keepVisibleUntil {
            let pollTask = Task { [weak self] in
                // Poll once a second up to 60s. Fades immediately the
                // moment `keepVisibleUntil` reports false.
                for _ in 0..<60 {
                    if await keepVisibleUntil() == false { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                // 800ms grace after the gate clears so the last line
                // of text stays readable past the final spoken word.
                try? await Task.sleep(nanoseconds: 800_000_000)
                await MainActor.run { [weak self] in self?.fadeOutAndHide() }
            }
            // Stash the task in a DispatchWorkItem-shaped wrapper so
            // hideOverlay() can cancel it.
            let cancelWrapper = DispatchWorkItem { pollTask.cancel() }
            autoHideWorkItem = cancelWrapper
        } else {
            let hideWork = DispatchWorkItem { [weak self] in
                self?.fadeOutAndHide()
            }
            autoHideWorkItem = hideWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hideWork)
        }
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
        tearDownCursorTrackingMonitor()
    }

    // MARK: - Private

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 40)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        // The panel needs to accept clicks so the in-bubble Stop button
        // works. Clicks outside the bubble fall through to whatever's
        // underneath because the panel size shrink-wraps the content
        // (no full-screen overlay).
        responseOverlayPanel.ignoresMouseEvents = false
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
                .frame(maxWidth: overlayMaxWidth)
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func repositionPanelToAnchor() {
        guard let overlayPanel else { return }
        let panelSize = overlayPanel.frame.size

        let (anchorScreenPoint, panelOrigin): (CGPoint, CGPoint) = {
            switch currentAnchor {
            case .belowRightOfCursor:
                let mouseLocation = NSEvent.mouseLocation
                let origin = CGPoint(
                    x: mouseLocation.x + anchorOffsetX,
                    y: mouseLocation.y - anchorOffsetY - panelSize.height
                )
                return (mouseLocation, origin)
            case .aboveCenterOf(let provider):
                let anchor = provider() ?? NSEvent.mouseLocation
                let origin = CGPoint(
                    x: anchor.x - panelSize.width / 2,
                    y: anchor.y + anchorOffsetY
                )
                return (anchor, origin)
            }
        }()

        var clampedOrigin = panelOrigin

        if let currentScreen = screenContainingPoint(anchorScreenPoint) {
            let visibleFrame = currentScreen.visibleFrame

            // Standard right/left flip + clamp for the cursor case.
            switch currentAnchor {
            case .belowRightOfCursor:
                if clampedOrigin.x + panelSize.width > visibleFrame.maxX {
                    clampedOrigin.x = anchorScreenPoint.x - anchorOffsetX - panelSize.width
                }
                if clampedOrigin.y < visibleFrame.minY {
                    clampedOrigin.y = anchorScreenPoint.y + anchorOffsetY
                }
            case .aboveCenterOf:
                // The avatar case rarely needs flipping — it lives near
                // the bottom of the visible frame. Just clamp.
                break
            }

            clampedOrigin.x = max(visibleFrame.minX, min(clampedOrigin.x, visibleFrame.maxX - panelSize.width))
            clampedOrigin.y = max(visibleFrame.minY, min(clampedOrigin.y, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(clampedOrigin)
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, overlayMaxWidth)
        let newHeight = fittingSize.height

        // Keep the panel pinned to its anchor while content grows.
        var frame = overlayPanel.frame
        let heightDelta = newHeight - frame.height
        frame.size = CGSize(width: newWidth, height: newHeight)
        // Adjust origin Y so the panel grows upward (toward the cursor), not downward
        frame.origin.y -= heightDelta
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.hideOverlay()
            }
        })
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.isShowingResponse {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.streamingResponseText.isEmpty ? "..." : viewModel.streamingResponseText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)

                // Stop button — only while actively recording audio.
                // Manual escape since silence-based auto-end was yanked.
                if viewModel.isListeningForAudio {
                    Button(action: { viewModel.onStopButtonTapped?() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Stop")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(DS.Colors.overlayCursorBlue.opacity(0.85))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            // Min width keeps the bubble from collapsing into a sliver
            // when text is empty/short ("…"). Max width caps growth so
            // streamed responses wrap predictably.
            .frame(minWidth: 140, maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                    ZStack {
                        // Dark glass fill — slightly translucent so the bubble
                        // feels seated against the screen instead of pasted on.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.7))
                        // Inner brand glow, very faint, only along the top edge
                        // so the bubble reads as the cursor's speech, not just
                        // a random tooltip.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        DS.Colors.overlayCursorBlue.opacity(0.18),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                        // Hairline gradient stroke — matches the voice pill
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.4),
                                        Color.white.opacity(0.05),
                                        DS.Colors.overlayCursorBlue.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.25), radius: 14, x: 0, y: 0)
                    .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
                )
        }
    }
}
