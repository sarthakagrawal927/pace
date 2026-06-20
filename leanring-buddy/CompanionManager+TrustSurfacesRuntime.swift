//
//  CompanionManager+TrustSurfacesRuntime.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A7):
//  undo banner, reply replay, and failure-narration trust surfaces.
//  Published trust state fields remain in the main file header section.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Trust surfaces (undo banner + reply replay)

    /// Returns the first click candidate's text label (if known) from
    /// the supplied plan, used to make the click-missed narration
    /// concrete ("I couldn't find a save button…"). Falls back to nil
    /// for coordinate-only clicks; the narrator then emits generic
    /// copy.
    static func firstClickCandidateLabel(
        in actionExecutionPlan: PaceActionExecutionPlan
    ) -> String? {
        for action in actionExecutionPlan.flattenedActions {
            if case .clickCandidates(let candidateSet) = action {
                for candidate in candidateSet.candidates {
                    if let label = candidate.label?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !label.isEmpty {
                        return label
                    }
                }
            }
        }
        return nil
    }

    /// Records that a reversible action just executed. Called from the
    /// post-action site in the agent loop / fast-action path. The
    /// cursor overlay observes the published fields and shows the
    /// undo banner for the next 5 seconds.
    func noteReversibleActionExecuted(
        in actionExecutionPlan: PaceActionExecutionPlan
    ) {
        guard PaceActionApprovalPolicy.planContainsReversibleMutation(actionExecutionPlan) else {
            return
        }
        let summary = PaceActionApprovalPolicy.firstReversibleSummary(actionExecutionPlan)
            ?? "Last action"
        mostRecentReversibleActionSummary = summary
        mostRecentReversibleActionAt = Date()
    }

    /// Test-friendly entry point that lets unit tests assert the
    /// undo-banner flags after a synthetic plan. Has the same effect
    /// as `noteReversibleActionExecuted` when called with a plan that
    /// contains a reversible mutation.
    func notePostActionExecutionForTrustSurface(
        actionExecutionPlan: PaceActionExecutionPlan
    ) {
        noteReversibleActionExecuted(in: actionExecutionPlan)
    }

    /// Clears the undo-banner state. Called by the cursor overlay
    /// after the 5-second window expires, or after the user taps
    /// "undo" so the banner doesn't linger.
    func clearReversibleActionUndoState() {
        mostRecentReversibleActionAt = nil
        mostRecentReversibleActionSummary = nil
    }

    /// Submits an `Undo.last` action through the executor. Called
    /// from the cursor overlay's undo button. Runs out-of-band of the
    /// planner loop because the user explicitly asked for undo.
    func triggerUndoLastMutation() {
        clearReversibleActionUndoState()
        Task { @MainActor in
            let undoPlan = PaceActionExecutionPlan.serial(actions: [.undoLastMutation])
            let observations = await actionExecutor.executeActionPlan(
                undoPlan,
                screenCaptures: []
            )
            if !observations.isEmpty {
                appendActionResult(.completed(observations: observations))
            }
        }
    }

    /// Notes that an assistant turn just finished speaking, so the
    /// notch panel can render the reply-replay button for the next 30
    /// seconds. The text passed in is the already-post-processed
    /// spoken text (think blocks + action tags stripped), so replay
    /// speaks the same syllables the user just missed.
    func noteLastSpokenReply(_ spokenText: String) {
        let trimmedSpokenText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpokenText.isEmpty else { return }
        lastSpokenReplyText = trimmedSpokenText
        lastSpokenReplyAt = Date()
    }

    /// Clears the replay state. Called when a new turn begins so the
    /// button never lingers past the next push-to-talk press.
    func clearLastSpokenReplyState() {
        lastSpokenReplyText = nil
        lastSpokenReplyAt = nil
    }

    /// Replays the most recent spoken reply through TTS. Wired to the
    /// notch panel's replay button. Reuses the SAME text that already
    /// went through TTS — doesn't re-stream the planner.
    func replayLastSpokenReply() {
        guard let textToReplay = lastSpokenReplyText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !textToReplay.isEmpty else {
            return
        }
        Task { @MainActor in
            do {
                try await ttsClient.speakText(textToReplay)
            } catch {
                print("⚠️ Replay TTS failed: \(error.localizedDescription)")
            }
        }
    }

    /// Composes and speaks a plain-language failure message for one of
    /// the documented `PaceFailureKind` cases. Flows through
    /// `PaceRestraintGate.decide(...)` so failure speech respects
    /// active-call mute and the proactive cooldown.
    ///
    /// `context` is a free-form short string used only as a debug
    /// breadcrumb (e.g. "agent loop step 3") — never spoken.
    func speakPlainLanguageFailure(
        _ kind: PaceFailureKind,
        context: String? = nil
    ) {
        let narration = PaceFailureNarrator.compose(kind)
        lastFailureNarration = narration

        let restraintDecision = PaceRestraintGate.decide(
            buildFailureRestraintContext(forNow: Date())
        )
        switch restraintDecision {
        case .speak:
            print("⚠️ Failure narration (\(context ?? "no-context")): \(narration.spokenText)")
            Task { @MainActor in
                do {
                    try await ttsClient.speakText(narration.spokenText)
                } catch {
                    print("⚠️ Failure narration TTS failed: \(error.localizedDescription)")
                }
            }
        case .stayQuiet(let reason):
            print("🔇 Suppressed failure narration (\(reason)): \(narration.spokenText)")
        case .queueUntilIdle(let reason):
            // First-class queueing isn't wired for failure narration in
            // v1 — failures should be loud when they happen, and if the
            // user is mid-input the panel still shows lastFailureNarration.
            print("⏳ Skipping queued failure narration (\(reason)): \(narration.spokenText)")
        }

        // Write a paceHistory breadcrumb so "what did you tell me
        // about earlier?" can recall the failure event later.
        localRetriever.recordPaceHistory(
            userTranscript: "(system) failure event",
            assistantResponse: "Pace surfaced a failure: \(narration.spokenText)"
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Builds the gate context for a failure narration. Failures
    /// inherit the `watchNudge` semantics — they're proactive speech
    /// the user didn't directly request, so the gate applies the
    /// active-call check.
    func buildFailureRestraintContext(forNow now: Date) -> PaceRestraintContext {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: userInputActivityMonitor.lastUserInputAt,
            frontmostAppBundleIdentifier: frontmostBundleIdentifier,
            isOnActiveCall: activeCallDetector.isOnActiveCall,
            wakeWordConfidence: nil,
            // Failures are always meaningful intent for the gate's
            // confidence check; the active-call gate is the real
            // filter we care about here.
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: proactivityProfile,
            isInUserFocusMode: focusModeMonitor.isCurrentlyInUserFocus
        )
    }

    /// Maps a blocking preflight issue onto a failure narration. Used
    /// by the agent loop when actions auto-execute (no approval popup)
    /// and a preflight issue blocks the path silently.
    func speakFailureForBlockingPreflightIfApplicable(
        preflightIssues: [PaceToolPreflightIssue]
    ) {
        guard let blockingKind = PaceToolPreflight
            .firstBlockingIssueKind(in: preflightIssues) else {
            return
        }
        switch blockingKind {
        case .actionsDisabled:
            // EnableActions=false is an Info.plist condition; the user
            // already saw the panel banner. Don't speak.
            return
        case .accessibilityPermissionMissing:
            speakPlainLanguageFailure(
                .missingPermission(permission: .accessibility),
                context: "preflight"
            )
        case .calendarPermissionMissing:
            speakPlainLanguageFailure(
                .missingPermission(permission: .calendar),
                context: "preflight"
            )
        case .remindersPermissionMissing:
            speakPlainLanguageFailure(
                .missingPermission(permission: .reminders),
                context: "preflight"
            )
        case .mcpServerNotConfigured(let serverName):
            speakPlainLanguageFailure(
                .mcpServerNotConfigured(name: serverName),
                context: "preflight"
            )
        }
    }

    /// Inspects post-execution observations for the all-click-fail
    /// signal and, if found, speaks the templated click-missed message.
    /// The observation's `summary` already documents "Click failed:" in
    /// `clickBestCandidate`, so we match on that prefix.
    func speakFailureForClickMissedIfApplicable(
        observations: [PaceActionExecutionObservation],
        clickTargetLabel: String?
    ) {
        let hasClickAllFail = observations.contains { observation in
            observation.summary.lowercased().contains("click failed")
        }
        guard hasClickAllFail else { return }
        speakPlainLanguageFailure(
            .clickMissed(targetLabel: clickTargetLabel),
            context: "click-all-fail"
        )
    }

    /// Sidecar-TTS-offline narration. Fired by the agent loop on the
    /// FIRST turn after the sidecar starts failing, then suppressed
    /// for `sidecarTTSOfflineCooldown` so the user doesn't hear the
    /// memo every sentence.
    func speakSidecarTTSFallbackMemoIfNeeded(
        isSidecarUnreachable: Bool,
        now: Date = Date()
    ) {
        guard isSidecarUnreachable else {
            // Sidecar recovered — clear the cooldown so a future
            // outage will speak again.
            lastSidecarTTSOfflineNarratedAt = nil
            return
        }
        let sidecarTTSOfflineCooldown: TimeInterval = 30 * 60
        if let lastNarratedAt = lastSidecarTTSOfflineNarratedAt,
           now.timeIntervalSince(lastNarratedAt) < sidecarTTSOfflineCooldown {
            return
        }
        lastSidecarTTSOfflineNarratedAt = now
        speakPlainLanguageFailure(.sidecarTTSOffline, context: "tts-fallback")
    }

}
