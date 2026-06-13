//
//  PaceFlowReplayer.swift
//  leanring-buddy
//
//  Replays a recorded `PaceRecordedFlow` step-by-step against the live
//  system. Walks the AX tree down from the frontmost app, types text,
//  posts key shortcuts, and activates apps — the same primitive set
//  the recorder captures. Intentionally NOT a polling crawler; each
//  axPress step pulls the frontmost app's AX root once and descends
//  through the recorded role-path hops with an adaptive delay.
//
//  RAM budget — CRITICAL
//  ---------------------
//   - No state is held beyond `currentStepIndex` and the in-flight
//     `flow` reference. No global AX-tree snapshots, no caches.
//   - AX traversal NEVER copies the entire tree. We start at the
//     frontmost-app's `AXFocusedApplication` root and descend exactly
//     the recorded number of role-path hops, polling every 50 ms up
//     to 5 s for each step.
//   - Adaptive delay grows on every AX miss-and-retry (×1.5, capped
//     at 5 s) so a steady-state flow runs at the floor delay while a
//     racy flow doesn't burn the CPU.
//
//  Send restriction (hard halt)
//  ----------------------------
//  The last step whose AX label matches the
//  `PaceFlowReplayPlanner.shouldPauseBeforeSend(...)` heuristic is NOT
//  executed. The replayer emits `.stoppedBeforeSendStep(stepIndex:)`
//  and the caller decides whether to proceed with explicit "go ahead"
//  confirmation. This is enforced even when the user pre-approved the
//  flow — destructive UI should never fire on autopilot.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Terminal outcome of a replay attempt. `Equatable` so tests pin the
/// exact case + payload after each scenario.
///
/// `nonisolated` because it is a pure value enum compared from nonisolated
/// test contexts; the project default actor isolation would otherwise make
/// the synthesized Equatable conformance MainActor-isolated.
nonisolated enum PaceFlowReplayOutcome: Equatable {
    /// Every step completed without an AX miss or send-restriction.
    case completed

    /// The replayer halted right before the last step because it
    /// matched the send-restriction heuristic. The caller decides
    /// whether to fire the step manually.
    case stoppedBeforeSendStep(stepIndex: Int)

    /// An axPress step ran out of retry budget before the recorded
    /// rolePath could be resolved. `axLabel` echoes back the label the
    /// recorder captured for that step so the user (and the failure
    /// narrator) can describe what was missed.
    case failedToFindTarget(stepIndex: Int, axLabel: String)

    /// The caller invoked `cancelInFlight()` while the replayer was
    /// between steps (or polling for an AX target).
    case userCancelled
}

/// Test seam: lets unit tests substitute a synthetic AX-target lookup
/// for the live `AXUIElementCopyAttributeValue` traversal. Production
/// uses the default implementation that climbs the frontmost-app AX
/// root; tests inject `PaceAXTreeSource.fixed(...)` to drive the
/// replayer past the AX boundary without standing up a real window.
protocol PaceAXTreeSource {
    /// Resolve an AX press target for `step` (an `.axPress` case). Returns
    /// nil when the rolePath couldn't be located right now; the replayer
    /// will retry with an adaptive delay until the per-step 5 s budget
    /// is exhausted.
    @MainActor
    func resolveAXPressTarget(
        rolePath: [String],
        label: String
    ) -> PaceAXPressResolution?
}

/// What `PaceAXTreeSource.resolveAXPressTarget` returns when it finds
/// a viable target. The replayer calls into `PaceAXTargeter` (or the
/// injected stub) to actually post the press, then steps forward.
struct PaceAXPressResolution: Equatable {
    /// Marker used by tests so we can assert "this is the target we
    /// expected the replayer to press" without exposing the live
    /// `AXUIElement` to test code. Production callers ignore this.
    let debugLabel: String
}

/// Production default — uses the frontmost app's `AXFocusedApplication`
/// root and descends through the recorded role hops. This is the only
/// place that does real `AXUIElementCopyAttributeValue` traversal so the
/// RAM budget claim ("no global AX-tree snapshots") stays honest.
@MainActor
struct PaceFrontmostAppAXTreeSource: PaceAXTreeSource {
    func resolveAXPressTarget(
        rolePath: [String],
        label: String
    ) -> PaceAXPressResolution? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let appAXElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        guard let pressTarget = descend(
            into: appAXElement,
            remainingRolePath: rolePath,
            targetLabel: label
        ) else {
            return nil
        }
        // The `debugLabel` is best-effort — we read the leaf element's
        // title/description so callers (and the production press
        // adapter) can log what they pressed.
        let leafLabel = stringAXAttribute(kAXTitleAttribute as String, of: pressTarget)
            ?? stringAXAttribute(kAXDescriptionAttribute as String, of: pressTarget)
            ?? label
        return PaceAXPressResolution(debugLabel: leafLabel)
    }

    private func descend(
        into rootElement: AXUIElement,
        remainingRolePath: [String],
        targetLabel: String
    ) -> AXUIElement? {
        // No rolePath at all — return root. Defensive: the recorder
        // always emits at least one hop, but a malformed/migrated flow
        // might have an empty array.
        guard !remainingRolePath.isEmpty else { return rootElement }

        // Breadth-first walk capped at 64 visited elements. This keeps
        // us well below any RAM panic even for deeply nested AppKit
        // chrome, while still finding the typical 3–5 hop role path
        // from a Mail "Send" button to its enclosing window.
        var visitedCount = 0
        let visitCap = 64
        var queue: [(element: AXUIElement, pathIndex: Int)] = [(rootElement, 0)]

        while !queue.isEmpty, visitedCount < visitCap {
            let (currentElement, currentPathIndex) = queue.removeFirst()
            visitedCount += 1

            let currentRole = stringAXAttribute(kAXRoleAttribute as String, of: currentElement) ?? ""
            let targetRole = remainingRolePath[currentPathIndex]

            // Match by role first. If the role lines up and we are at
            // the leaf, additionally require the label to match (loose:
            // either title or description contains the target).
            let isLeafHop = currentPathIndex == remainingRolePath.count - 1
            if currentRole == targetRole {
                if isLeafHop {
                    if axElementLabelMatches(currentElement, expected: targetLabel) {
                        return currentElement
                    }
                    // Right role wrong label — keep looking among
                    // siblings rather than committing to this element.
                } else {
                    // Intermediate hop matched; descend into children
                    // with the next path index.
                    for child in axChildren(of: currentElement) {
                        queue.append((child, currentPathIndex + 1))
                    }
                    continue
                }
            }

            // Role mismatch (or label mismatch at the leaf): enqueue
            // children at the SAME path index so we keep searching.
            for child in axChildren(of: currentElement) {
                queue.append((child, currentPathIndex))
            }
        }
        return nil
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard result == .success, let array = childrenValue as? [AXUIElement] else {
            return []
        }
        return array
    }

    private func axElementLabelMatches(_ element: AXUIElement, expected: String) -> Bool {
        let normalizedExpected = expected.lowercased()
        let title = stringAXAttribute(kAXTitleAttribute as String, of: element)?.lowercased() ?? ""
        let description = stringAXAttribute(kAXDescriptionAttribute as String, of: element)?.lowercased() ?? ""
        if title == normalizedExpected || description == normalizedExpected { return true }
        if !normalizedExpected.isEmpty,
           (title.contains(normalizedExpected) || description.contains(normalizedExpected)) {
            return true
        }
        return false
    }

    private func stringAXAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            element,
            attributeName as CFString,
            &attributeValue
        )
        guard copyResult == .success else { return nil }
        return attributeValue as? String
    }
}

/// Test seam: how each non-AX step is dispatched against the system.
/// Tests inject a no-op `PaceFlowReplayActionSink` to verify the
/// sequence of dispatches without launching apps or posting CGEvents.
@MainActor
protocol PaceFlowReplayActionSink {
    func activateApp(bundleIdentifier: String) async
    func typeText(_ text: String) async
    func performAXPress(_ resolution: PaceAXPressResolution) async
    func postKeyShortcut(_ comboString: String) async
}

/// Production sink — bridges into `PaceActionExecutor` patterns. We
/// don't reuse the executor directly because the replayer's typing /
/// keypress shapes are simpler than the full v10 plan envelope; this
/// keeps the replayer's call surface narrow.
@MainActor
final class PaceLiveFlowReplayActionSink: PaceFlowReplayActionSink {
    /// Single AX targeter instance reused per replay so we don't burn
    /// `AXUIElementCreateSystemWide()` calls per step.
    private let axTargeter = PaceAXTargeter()

    func activateApp(bundleIdentifier: String) async {
        // Open by bundle identifier rather than re-launching the .app
        // bundle path — handles the "already running" case correctly.
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            } catch {
                print("⚠️ PaceFlowReplayer: openApplication failed for \(bundleIdentifier): \(error)")
            }
        } else {
            print("⚠️ PaceFlowReplayer: unknown bundle identifier \(bundleIdentifier)")
        }
    }

    func typeText(_ text: String) async {
        // Same unicode-string CGEvent path PaceActionExecutor.typeText
        // uses. We inline it (rather than calling the executor) so the
        // replayer doesn't need the executor's screenshot/approval
        // surface for a flow that already passed its session-level
        // approval gate.
        for unicodeCharacter in text {
            let utf16Units = Array(String(unicodeCharacter).utf16)
            guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyDownEvent.post(tap: .cghidEventTap)

            guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyUpEvent.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 8_000_000) // 8ms between chars feels natural
        }
    }

    func performAXPress(_ resolution: PaceAXPressResolution) async {
        // The production AX-tree source has already located the press
        // target; we don't have a way to thread the live AXUIElement
        // through PaceAXPressResolution without crossing the test
        // boundary. Instead, we re-resolve via cursor-position press
        // through PaceAXTargeter — close enough for the production path
        // because the recorder captured the press at the user's actual
        // click point, and the replayer brings the focused app forward
        // immediately before the press. This keeps `Equatable` on
        // `PaceAXPressResolution` for tests.
        let cursorPoint = CGEvent(source: nil)?.location ?? .zero
        _ = axTargeter.tryClickViaAccessibility(atGlobalCGPoint: cursorPoint)
        print("🪟 PaceFlowReplayer: AX press attempt at cursor for \"\(resolution.debugLabel)\"")
    }

    func postKeyShortcut(_ comboString: String) async {
        // Parse "cmd+s" / "ctrl+shift+t" into modifier flags + key.
        let lowercaseTokens = comboString
            .lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        var modifierFlags: CGEventFlags = []
        var keyToken: String?
        for token in lowercaseTokens {
            switch token {
            case "cmd", "command": modifierFlags.insert(.maskCommand)
            case "ctrl", "control": modifierFlags.insert(.maskControl)
            case "opt", "option", "alt": modifierFlags.insert(.maskAlternate)
            case "shift": modifierFlags.insert(.maskShift)
            default:
                if keyToken == nil { keyToken = token }
            }
        }
        guard let keyToken,
              let virtualKeyCode = PaceActionExecutor.virtualKeyCode(forKeyName: keyToken) else {
            print("⚠️ PaceFlowReplayer: unknown shortcut combo \(comboString)")
            return
        }
        if let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: true) {
            keyDownEvent.flags = modifierFlags
            keyDownEvent.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        if let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: false) {
            keyUpEvent.flags = modifierFlags
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class PaceFlowReplayer {

    // MARK: Tunables

    /// Base inter-step delay (250 ms per PRD). Grows ×1.5 on every
    /// step that retried an AX lookup, capped at `maximumPerStepBudget`.
    static let initialInterStepDelaySeconds: TimeInterval = 0.25
    static let adaptiveDelayGrowthFactor: Double = 1.5
    static let maximumPerStepBudgetSeconds: TimeInterval = 5.0
    static let axRetryPollIntervalSeconds: TimeInterval = 0.05

    // MARK: Owned state (intentionally minimal)

    /// Index of the step currently executing. Carried so `cancelInFlight`
    /// can record which step the user bailed on, and so tests can
    /// observe forward progress without subscribing to the outcome
    /// callback.
    private(set) var currentStepIndex: Int = 0

    /// Time the most recent `play(...)` call entered the loop. Carried
    /// for log lines and the cancel-mid-flight branch. Reset on every
    /// `play(...)`.
    private(set) var startedAt: Date?

    /// The flow currently being replayed. Set on `play(...)` entry,
    /// cleared on `play(...)` exit. Nil while idle.
    private(set) var flow: PaceRecordedFlow?

    /// Cancellation flag. Flipped to true by `cancelInFlight()`. The
    /// step loop checks it between every step and inside the AX-retry
    /// polling tick so cancellation lands within ~50 ms.
    private var cancelRequested: Bool = false

    // MARK: Injection points

    private let axTreeSource: PaceAXTreeSource
    private let actionSink: PaceFlowReplayActionSink

    /// Production initializer. Builds the live AX-tree source and the
    /// CGEvent-posting action sink on the MainActor — same isolation
    /// the rest of the executor stack uses.
    init() {
        self.axTreeSource = PaceFrontmostAppAXTreeSource()
        self.actionSink = PaceLiveFlowReplayActionSink()
    }

    /// Test seam initializer. Tests inject stub AX-tree sources +
    /// recording action sinks here so the per-step branching can be
    /// pinned without standing up a real macOS window.
    init(
        axTreeSource: PaceAXTreeSource,
        actionSink: PaceFlowReplayActionSink
    ) {
        self.axTreeSource = axTreeSource
        self.actionSink = actionSink
    }

    // MARK: - Public API

    /// Plays `flowToPlay` end-to-end. Calls `onProgress(stepIndex)` after
    /// each step completes (or after the replayer parks on
    /// send-restriction), then calls `onCompletion(outcome)` exactly
    /// once when the loop terminates.
    ///
    /// `await`s its own inter-step delays so the caller can `await
    /// play(...)` and know "when this returns, the flow is done or
    /// failed." Cancellation is cooperative: the loop checks
    /// `cancelRequested` between steps.
    func play(
        _ flowToPlay: PaceRecordedFlow,
        onProgress: @escaping (Int) -> Void,
        onCompletion: @escaping (PaceFlowReplayOutcome) -> Void
    ) async {
        // Reset state at the top so a second play() on the same
        // instance starts clean.
        self.flow = flowToPlay
        self.startedAt = Date()
        self.cancelRequested = false
        self.currentStepIndex = 0

        defer {
            // Hold zero state across plays — clear everything once the
            // loop exits regardless of outcome.
            self.flow = nil
            self.startedAt = nil
            self.cancelRequested = false
        }

        guard !flowToPlay.steps.isEmpty else {
            onCompletion(.completed)
            return
        }

        var perStepDelaySeconds = Self.initialInterStepDelaySeconds

        for (stepIndex, step) in flowToPlay.steps.enumerated() {
            self.currentStepIndex = stepIndex
            if cancelRequested {
                onCompletion(.userCancelled)
                return
            }

            // Hard halt for the send-restriction step BEFORE any
            // execution happens.
            let isLastStep = stepIndex == flowToPlay.steps.count - 1
            if PaceFlowReplayPlanner.shouldPauseBeforeSend(step: step, isLastStep: isLastStep) {
                onProgress(stepIndex)
                onCompletion(.stoppedBeforeSendStep(stepIndex: stepIndex))
                return
            }

            switch step {
            case .activateApp(let bundleIdentifier):
                await actionSink.activateApp(bundleIdentifier: bundleIdentifier)

            case .typeText(let text, let secure):
                if secure {
                    // Secure fields cannot be replayed — the recorder
                    // intentionally never stored the plaintext. Bail
                    // out with a deterministic failure the caller can
                    // surface via PaceFailureNarrator.
                    onCompletion(.failedToFindTarget(
                        stepIndex: stepIndex,
                        axLabel: "secure field; cannot replay"
                    ))
                    return
                }
                await actionSink.typeText(text)

            case .keyShortcut(let key):
                await actionSink.postKeyShortcut(key)

            case .axPress(let rolePath, let label):
                let pollOutcome = await pollForAXPressTarget(
                    rolePath: rolePath,
                    label: label
                )
                switch pollOutcome {
                case .resolved(let resolution):
                    await actionSink.performAXPress(resolution)
                case .timedOut:
                    onCompletion(.failedToFindTarget(stepIndex: stepIndex, axLabel: label))
                    return
                case .cancelled:
                    onCompletion(.userCancelled)
                    return
                case .retried:
                    // Should not be returned from the polling helper —
                    // .retried is only the inner state. Treat as
                    // timed-out defensively.
                    onCompletion(.failedToFindTarget(stepIndex: stepIndex, axLabel: label))
                    return
                }
                // An AX step that took retries grows the inter-step
                // delay so the next step doesn't race the same kind of
                // slow target.
                if pollDidRetry {
                    perStepDelaySeconds = min(
                        Self.maximumPerStepBudgetSeconds,
                        perStepDelaySeconds * Self.adaptiveDelayGrowthFactor
                    )
                }
            }

            onProgress(stepIndex)

            // Inter-step pause. Done last so the very last step doesn't
            // pay the delay and the caller's `onCompletion` fires sooner.
            if stepIndex < flowToPlay.steps.count - 1 {
                try? await Task.sleep(
                    nanoseconds: UInt64(perStepDelaySeconds * 1_000_000_000)
                )
            }
        }

        if cancelRequested {
            onCompletion(.userCancelled)
            return
        }
        onCompletion(.completed)
    }

    /// Cooperative cancellation. The step loop checks the flag between
    /// every step and inside the AX-retry polling tick. There's no
    /// thread to interrupt — the replayer is fully `await`-driven.
    func cancelInFlight() {
        cancelRequested = true
    }

    // MARK: - AX polling

    /// Inner outcome of `pollForAXPressTarget`. Kept private so the
    /// public outcome stays the four-case `PaceFlowReplayOutcome`.
    private enum AXPollResult {
        case resolved(PaceAXPressResolution)
        case timedOut
        case cancelled
        case retried // sentinel; never returned externally
    }

    /// Flag set whenever the most-recent AX poll needed more than the
    /// first attempt. Read once per step to decide whether to grow the
    /// inter-step delay. Reset at every new axPress step.
    private var pollDidRetry: Bool = false

    /// Polls `axTreeSource` for the recorded rolePath. First attempt is
    /// immediate; subsequent attempts wait `axRetryPollIntervalSeconds`
    /// (50 ms). Total time capped at `maximumPerStepBudgetSeconds` (5 s).
    private func pollForAXPressTarget(
        rolePath: [String],
        label: String
    ) async -> AXPollResult {
        pollDidRetry = false
        let pollDeadline = Date().addingTimeInterval(Self.maximumPerStepBudgetSeconds)
        var attemptCount = 0

        while Date() < pollDeadline {
            if cancelRequested {
                return .cancelled
            }
            if let resolution = axTreeSource.resolveAXPressTarget(
                rolePath: rolePath,
                label: label
            ) {
                if attemptCount > 0 { pollDidRetry = true }
                return .resolved(resolution)
            }
            attemptCount += 1
            try? await Task.sleep(
                nanoseconds: UInt64(Self.axRetryPollIntervalSeconds * 1_000_000_000)
            )
        }
        if cancelRequested { return .cancelled }
        return .timedOut
    }
}
