//
//  PaceActionExecutor+Mouse.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  click candidates, clipboard, window snap, scroll.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - Mouse

    // MARK: - Mouse

    func clickBestCandidate(
        _ clickCandidateSet: PaceClickCandidateSet,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        let currentGlobalCursorPoint = CGEvent(source: nil)?.location
        let focusedWindowGlobalFrame = PaceClickStateSnapshot.focusedWindowGlobalFrame()
        let orderedCandidates = clickCandidateSet.orderedCandidates(
            currentGlobalCursorPoint: currentGlobalCursorPoint,
            focusedWindowGlobalFrame: focusedWindowGlobalFrame,
            screenCaptures: screenCaptures,
            coordinateConverter: { [weak self] location, captures in
                self?.convertScreenshotPixelToDisplayGlobalPoint(
                    screenshotPixelLocation: location,
                    screenCaptures: captures
                )
            }
        )

        guard !orderedCandidates.isEmpty else {
            print("⚠️ PaceActionExecutor: no click candidates available — skipping")
            return PaceActionExecutionObservation(
                toolName: "click_candidates",
                summary: "Click failed: no click candidates were available."
            )
        }

        let maximumAttempts = min(3, orderedCandidates.count)
        let attemptedCandidates = Array(orderedCandidates.prefix(maximumAttempts))
        for (candidateIndex, candidate) in attemptedCandidates.enumerated() {
            let beforeClickState = actionsAreEnabled && candidate.expectStateChange
                ? PaceClickStateSnapshot.captureCurrent()
                : nil

            let didAttemptClick = await clickCandidate(
                candidate,
                screenCaptures: screenCaptures,
                clickCount: clickCandidateSet.clickCount
            )
            guard didAttemptClick else { continue }

            guard actionsAreEnabled, candidate.expectStateChange else {
                return nil
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            let afterClickState = PaceClickStateSnapshot.captureCurrent()
            if beforeClickState != afterClickState {
                return nil
            }

            let hasAnotherCandidate = candidateIndex < maximumAttempts - 1
            if hasAnotherCandidate {
                print("⚠️ PaceActionExecutor: click candidate produced no observable state change — retrying next candidate")
            } else {
                print("⚠️ PaceActionExecutor: click candidates produced no observable state change")
            }
        }

        let attemptedCandidateSummary = attemptedCandidates
            .map(\.observationDescription)
            .joined(separator: "; ")
        let skippedCandidateCount = max(0, orderedCandidates.count - attemptedCandidates.count)
        let skippedCandidateText = skippedCandidateCount > 0
            ? " \(skippedCandidateCount) lower-ranked candidate\(skippedCandidateCount == 1 ? " was" : "s were") not tried."
            : ""
        // Attach a Set-of-Mark recovery request: the top candidate carries the
        // intended target (its label) and which screen the click aimed at, so
        // the agent loop can render numbered marks and let the VLM visually
        // re-pick. See PRD docs/prds/set-of-mark-click-recovery.md.
        let topCandidate = orderedCandidates.first
        let recoveryRequest = PaceSetOfMarkRecoveryRequest(
            targetDescription: topCandidate?.label ?? "",
            screenNumber: topCandidate?.location?.screenNumber
        )
        return PaceActionExecutionObservation(
            toolName: "click_candidates",
            summary: "Click failed after trying \(attemptedCandidates.count) of \(orderedCandidates.count) candidate\(orderedCandidates.count == 1 ? "" : "s"): \(attemptedCandidateSummary).\(skippedCandidateText)",
            setOfMarkRecovery: recoveryRequest
        )
    }

    /// Re-attempt a single click at a location recovered via Set-of-Mark.
    /// Returns true when the click produces an observable state change (i.e. the
    /// recovery worked). See PRD docs/prds/set-of-mark-click-recovery.md.
    func executeRecoveredClick(
        at location: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture]
    ) async -> Bool {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                PaceClickCandidate(
                    location: location,
                    label: nil,
                    confidence: 1.0,
                    expectStateChange: true
                )
            ],
            clickCount: 1
        )
        // clickBestCandidate returns nil on an observable state change (success)
        // and a failure observation when nothing changed.
        return await clickBestCandidate(candidateSet, screenCaptures: screenCaptures) == nil
    }

    func clickCandidate(
        _ candidate: PaceClickCandidate,
        screenCaptures: [CompanionScreenCapture],
        clickCount: Int
    ) async -> Bool {
        if let location = candidate.location {
            return await clickAtScreenshotLocation(
                location,
                screenCaptures: screenCaptures,
                clickCount: clickCount
            )
        }

        guard let label = candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            print("⚠️ PaceActionExecutor: click candidate has no coordinate or label — skipping")
            return false
        }

        print("🪟 AX label click \"\(label)\" (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else { return true }
        guard clickCount == 1 else {
            print("⚠️ PaceActionExecutor: label-only double-click candidates are not supported — skipping")
            return false
        }

        return PaceAXLabelPressResolver.pressBestMatch(for: candidate)
    }

    @discardableResult
    func clickAtScreenshotLocation(
        _ screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture],
        clickCount: Int
    ) async -> Bool {
        guard let displayGlobalPoint = convertScreenshotPixelToDisplayGlobalPoint(
            screenshotPixelLocation: screenshotPixelLocation,
            screenCaptures: screenCaptures
        ) else {
            print("⚠️ PaceActionExecutor: could not resolve display coordinates for click — skipping")
            return false
        }

        print("🖱️  Click x\(clickCount) at \(Int(displayGlobalPoint.x)),\(Int(displayGlobalPoint.y)) (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else { return true }

        // Try the AX path first for single clicks. If AX finds a
        // pressable element and the press succeeds, we skip the CGEvent
        // path entirely — it's more robust against layout shifts and
        // synthesises a semantically correct activation event.
        // Double-clicks still go through CGEvent because AX has no
        // "double-press" primitive.
        if clickCount == 1, axTargeter.tryClickViaAccessibility(atGlobalCGPoint: displayGlobalPoint) {
            return true
        }

        // Move the system cursor first so the visual position matches the
        // synthetic click and so any hover state (tooltips, menu reveals)
        // settles before the click lands.
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: displayGlobalPoint,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms hover settle

        for clickIndex in 0..<clickCount {
            let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            downEvent?.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms hold

            let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            upEvent?.post(tap: .cghidEventTap)

            if clickIndex < clickCount - 1 {
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms between clicks of a double-click
            }
        }

        return true
    }

    func readClipboardText() -> PaceActionExecutionObservation {
        print("🧰 Clipboard read (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "clipboard_read",
                summary: "Would read clipboard text."
            )
        }

        guard let clipboardText = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "clipboard_read",
                summary: "Clipboard has no text."
            )
        }

        let maximumClipboardPreviewCharacters = 1_200
        let clippedText: String = {
            guard clipboardText.count > maximumClipboardPreviewCharacters else {
                return clipboardText
            }
            return "\(clipboardText.prefix(maximumClipboardPreviewCharacters))..."
        }()

        return PaceActionExecutionObservation(
            toolName: "clipboard_read",
            summary: "Clipboard text: \(clippedText)"
        )
    }

    func snapFocusedWindow(_ request: PaceWindowSnapRequest) -> PaceActionExecutionObservation {
        print("🪟 Window snap \(request.position.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "Would snap focused window: \(request.position.displayName)"
            )
        }

        guard let focusedWindow = focusedWindowElement() else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "No focused window was found."
            )
        }

        guard let currentWindowFrame = axFrame(of: focusedWindow),
              let screenVisibleFrame = axVisibleFrameForScreen(containing: currentWindowFrame) else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "Could not resolve focused window frame."
            )
        }

        let targetFrame = request.position.targetFrame(in: screenVisibleFrame)
        guard setAXWindowFrame(focusedWindow, targetFrame: targetFrame) else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "Focused window could not be moved or resized via Accessibility."
            )
        }

        return PaceActionExecutionObservation(
            toolName: "window_snap",
            summary: "Snapped focused window: \(request.position.displayName)"
        )
    }

    func focusedWindowElement() -> AXUIElement? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedWindowValue as! AXUIElement)
    }

    func axFrame(of windowElement: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        guard positionResult == .success,
              let positionValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else {
            return nil
        }

        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeValue
        )
        guard sizeResult == .success,
              let sizeValue,
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    func axVisibleFrameForScreen(containing axWindowFrame: CGRect) -> CGRect? {
        let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        let primaryHeight = primaryScreen?.frame.height ?? 0
        let windowCenter = CGPoint(x: axWindowFrame.midX, y: axWindowFrame.midY)

        for screen in NSScreen.screens {
            let axScreenFrame = Self.convertCocoaScreenFrameToAXFrame(
                screen.visibleFrame,
                primaryScreenHeight: primaryHeight
            )
            if axScreenFrame.contains(windowCenter) {
                return axScreenFrame
            }
        }

        return NSScreen.main.map {
            Self.convertCocoaScreenFrameToAXFrame(
                $0.visibleFrame,
                primaryScreenHeight: primaryHeight
            )
        }
    }

    static func convertCocoaScreenFrameToAXFrame(
        _ cocoaFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: cocoaFrame.origin.x,
            y: primaryScreenHeight - cocoaFrame.origin.y - cocoaFrame.height,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    func setAXWindowFrame(_ windowElement: AXUIElement, targetFrame: CGRect) -> Bool {
        var targetOrigin = targetFrame.origin
        var targetSize = targetFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &targetOrigin),
              let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeResult = AXUIElementSetAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            sizeValue
        )

        return positionResult == .success && sizeResult == .success
    }

    func scroll(direction: PaceScrollDirection, amountInLines: Int) async {
        print("🖱️  Scroll \(direction) by \(amountInLines) lines (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        let verticalDelta: Int32 = {
            switch direction {
            case .up: return Int32(amountInLines)
            case .down: return -Int32(amountInLines)
            }
        }()

        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: verticalDelta,
            wheel2: 0,
            wheel3: 0
        ) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }
}
