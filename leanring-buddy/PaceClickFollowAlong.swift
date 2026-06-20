//
//  PaceClickFollowAlong.swift
//  leanring-buddy
//
//  Click-verification + auto-advance for Tuition Mode. Pace draws
//  a sequence of "click here" annotations; when the user clicks
//  inside the current step's target bbox, Pace advances to the
//  next step automatically. Matches the teaching loop competitors
//  like Clicky just shipped.
//
//  Architecture:
//
//   • PaceClickFollowAlongStep — one step in the sequence:
//     a screen-label, a screenshot-pixel bbox, the spoken
//     instruction to deliver when this step becomes active.
//   • PaceClickFollowAlongSequence — an ordered list of steps
//     plus the optional completion message.
//   • PaceClickFollowAlongController — @MainActor state machine
//     tracking the active step index. Pure logic, unit-testable
//     against synthetic clicks.
//   • PaceClickFollowAlongMatcher — pure point-in-rect check
//     with a small tolerance margin so a click ~3 px outside the
//     bbox still advances (drawn rectangles are rarely pixel-
//     accurate to the underlying UI element).
//
//  Coordinate systems: steps carry SCREENSHOT-PIXEL bboxes (same
//  space as PaceAnnotationShape bboxes). CGEventTap reports
//  CG-global coordinates (top-left origin, points). The monitor
//  converts the click point through PaceAnnotationCoordinateMapper
//  before handing it to the controller. Tests drive the controller
//  with already-converted screenshot-pixel points so the mapping
//  layer stays out of the unit-test surface.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

// MARK: - Pure value types

nonisolated struct PaceClickFollowAlongStep: Equatable {
    /// Screen label this step targets — must match a label
    /// produced by `CompanionScreenCaptureUtility.captureAllScreensAsJPEG`
    /// (e.g. "primary focus", "screen 2") so the monitor knows
    /// which display to convert against.
    let screenLabel: String

    /// Target click area in screenshot pixel coordinates (top-left
    /// origin). The user's click must land inside this rect
    /// (plus the matcher's tolerance margin) to advance.
    let targetBoundsInScreenshotPixels: CGRect

    /// What Pace speaks when this step becomes active. Stored so
    /// the controller can hand it back through its onAdvance
    /// callback; the controller itself doesn't speak.
    let spokenInstructionForUser: String

    /// Optional free-form ID the caller can use to thread the step
    /// back to the planner output (e.g. which `draw_annotation`
    /// call this came from). Not used internally.
    let stepIdentifier: String
}

nonisolated struct PaceClickFollowAlongSequence: Equatable {
    let steps: [PaceClickFollowAlongStep]

    /// Optional final instruction spoken on completion (e.g. "Done —
    /// nice job"). Skipped when nil.
    let completionMessage: String?

    /// Hard ceiling — keep tuition sequences bounded. 12 steps is
    /// already a long teaching loop; anything past that suggests
    /// the planner is trying to script a whole tutorial in one
    /// turn rather than teaching incrementally.
    static let maximumStepCount = 12
}

// MARK: - State

nonisolated enum PaceClickFollowAlongState: Equatable {
    case idle
    /// Sequence active; index points at the step currently waiting
    /// for the user's click.
    case awaitingClickOnStep(index: Int, totalSteps: Int)
    /// All steps clicked through — completion message has been
    /// delivered (if any). Controller will return to .idle after
    /// the caller acknowledges via `markCompletionAcknowledged()`.
    case completed
}

// MARK: - Matcher (pure point-in-rect check)

nonisolated enum PaceClickFollowAlongMatcher {
    /// Tolerance in screenshot pixels — clicks within this margin
    /// outside the bbox still count. Drawn click-targets are
    /// rarely pixel-accurate to the underlying UI element; a small
    /// margin avoids "I clicked the button but Pace didn't notice"
    /// frustration.
    nonisolated static let toleranceInScreenshotPixels: CGFloat = 6

    /// True when `clickPoint` (screenshot-pixel coords) is inside
    /// `targetBounds` expanded by the tolerance margin.
    nonisolated static func clickMatchesStep(
        clickPointInScreenshotPixels: CGPoint,
        stepTargetBoundsInScreenshotPixels: CGRect
    ) -> Bool {
        let expandedBounds = stepTargetBoundsInScreenshotPixels
            .insetBy(dx: -toleranceInScreenshotPixels, dy: -toleranceInScreenshotPixels)
        return expandedBounds.contains(clickPointInScreenshotPixels)
    }
}

// MARK: - Controller

@MainActor
final class PaceClickFollowAlongController: ObservableObject {

    /// Live state for SwiftUI surfaces that want to render
    /// progress (e.g. a "step 3 of 5" label).
    @Published private(set) var currentState: PaceClickFollowAlongState = .idle

    /// Fired when the controller advances to a new step. Carries
    /// the newly-active step so the caller can draw its annotation
    /// + speak its instruction.
    var onStepActivated: (@MainActor (PaceClickFollowAlongStep) -> Void)?

    /// Fired exactly once when the sequence completes (last step
    /// matched). Carries the optional completion message.
    var onSequenceCompleted: (@MainActor (String?) -> Void)?

    /// Fired when the sequence is cancelled (caller-initiated or
    /// auto-cancel timeout). Includes the reason for the audit log.
    var onSequenceCancelled: (@MainActor (String) -> Void)?

    private var activeSequence: PaceClickFollowAlongSequence?

    /// Begin a new follow-along sequence. If one is already active,
    /// it gets cancelled with reason "superseded" before the new
    /// one starts — keeps the lifecycle deterministic.
    func startSequence(_ sequence: PaceClickFollowAlongSequence) {
        guard !sequence.steps.isEmpty else {
            currentState = .idle
            activeSequence = nil
            return
        }
        if activeSequence != nil {
            onSequenceCancelled?("superseded by new sequence")
        }
        activeSequence = sequence
        currentState = .awaitingClickOnStep(index: 0, totalSteps: sequence.steps.count)
        onStepActivated?(sequence.steps[0])
    }

    /// Feed a global click event into the controller. Caller is
    /// responsible for converting from CG-global to screenshot-
    /// pixel coordinates against the right screen.
    ///
    /// Returns true when the click matched the current step and
    /// the controller advanced (or completed); false otherwise.
    /// Useful for the monitor to know whether to swallow the
    /// click event or let it propagate normally.
    @discardableResult
    func handleGlobalClick(
        clickPointInScreenshotPixels: CGPoint,
        clickedScreenLabel: String
    ) -> Bool {
        guard case .awaitingClickOnStep(let index, let totalSteps) = currentState,
              let sequence = activeSequence,
              index < sequence.steps.count else {
            return false
        }
        let currentStep = sequence.steps[index]
        guard currentStep.screenLabel == clickedScreenLabel else {
            // Click landed on a different screen than the step is
            // targeting — not a match. Don't advance.
            return false
        }
        let matched = PaceClickFollowAlongMatcher.clickMatchesStep(
            clickPointInScreenshotPixels: clickPointInScreenshotPixels,
            stepTargetBoundsInScreenshotPixels: currentStep.targetBoundsInScreenshotPixels
        )
        guard matched else { return false }

        let nextIndex = index + 1
        if nextIndex >= totalSteps {
            currentState = .completed
            onSequenceCompleted?(sequence.completionMessage)
            return true
        }
        currentState = .awaitingClickOnStep(index: nextIndex, totalSteps: totalSteps)
        onStepActivated?(sequence.steps[nextIndex])
        return true
    }

    func cancel(reason: String) {
        guard currentState != .idle else { return }
        activeSequence = nil
        currentState = .idle
        onSequenceCancelled?(reason)
    }

    /// Called by the caller (CompanionManager) once it has acted on
    /// the completion event (e.g. spoken the completion message).
    /// Resets to idle so a new sequence can start.
    func markCompletionAcknowledged() {
        guard currentState == .completed else { return }
        activeSequence = nil
        currentState = .idle
    }

    // MARK: - Test seams

    /// True when a sequence is active and waiting for input.
    /// Convenient for tests; production reads `currentState`.
    var isAwaitingClick: Bool {
        if case .awaitingClickOnStep = currentState { return true }
        return false
    }

    /// Index of the current step. -1 if idle/completed. Tests
    /// assert on this directly.
    var currentStepIndex: Int {
        if case .awaitingClickOnStep(let index, _) = currentState {
            return index
        }
        return -1
    }
}
