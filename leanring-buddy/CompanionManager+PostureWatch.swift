//
//  CompanionManager+PostureWatch.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A2):
//  the `// MARK: - Posture watch` section plus co-located watch-mode /
//  approval / tool-debug helpers that lived under the same MARK block.
//  Call sites and behavior are unchanged.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Posture watch

    func setPostureWatchEnabled(_ enabled: Bool) {
        guard enabled != isPostureWatchEnabled else { return }
        isPostureWatchEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isPostureWatchEnabled)
        if enabled {
            latestPostureStatus = "Calibrating — sit how you'd like to sit"
            postureMonitor.start()
        } else {
            postureMonitor.stop()
            latestPostureStatus = nil
        }
    }

    func recalibratePostureWatch() {
        guard isPostureWatchEnabled else { return }
        postureMonitor.recalibrate()
        latestPostureStatus = "Calibrating — sit how you'd like to sit"
    }

    func handlePostureEvent(_ postureEvent: PacePostureEvent) {
        switch postureEvent {
        case .calibrated:
            latestPostureStatus = "Watching posture"
            print("📷 Posture watch calibrated")
        case .alert(let assessment):
            latestPostureStatus = "Nudged: \(assessment.displayName)"
            print("📷 Posture alert: \(assessment.displayName)")
            // Speak only when no turn is in flight — a posture nudge should
            // never talk over an answer the user asked for.
            guard voiceState == .idle else { return }
            Task {
                await streamingSentenceTTSPipeline.flushFinal(
                    finalSpokenText: assessment.spokenNudge
                )
            }
        }
    }

    func handleWatchModeEvent(_ event: PaceScreenWatchEvent) async {
        let summary = "\(event.category.displayName): \(event.screenLabel)"
        latestWatchModeSummary = summary
        print("👀 Watch mode: \(summary) meanDelta=\(String(format: "%.2f", event.diff.meanPixelDelta)) changedRatio=\(String(format: "%.3f", event.diff.changedPixelRatio))")

        // Journal before the idle guard — that guard only exists to avoid
        // speaking over an in-flight turn, but history should be captured
        // regardless of what the voice pipeline is doing.
        recordWatchModeEventInJournal(event)

        guard voiceState == .idle else { return }

        responseOverlayManager.showOverlayAndBeginStreaming()
        let spokenWatchModeSummary = "i noticed a \(event.category.displayName)."
        responseOverlayManager.updateStreamingText(spokenWatchModeSummary)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenWatchModeSummary)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    func recordWatchModeEventInJournal(_ event: PaceScreenWatchEvent) {
        // Frontmost app name is a cheap synchronous NSWorkspace read — the
        // same source the ASR contextual-phrase builder uses.
        let frontmostApplicationName = NSWorkspace.shared.frontmostApplication?.localizedName
        // Reuse the per-screen VLM cache only while it is fresh enough to
        // still describe roughly what the user is looking at. Never run the
        // VLM from here — journaling must stay free.
        let freshCachedScreenDescription = screenContextService.cachedDescriptionIfFresh(
            screenLabel: event.screenLabel,
            maxAgeSeconds: 120,
            referenceDate: event.detectedAt
        )
        localRetriever.recordScreenWatchObservation(
            screenLabel: event.screenLabel,
            categoryDisplayName: event.category.displayName,
            frontmostApplicationName: frontmostApplicationName,
            screenDescription: freshCachedScreenDescription,
            now: event.detectedAt
        )
        refreshLocalRetrievalPublishedState()
    }

    func requestUserApprovalForActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue] = [],
        smokeAutoCancelAfter: TimeInterval? = nil
    ) -> Bool {
        let hasBlockingPreflightIssue = preflightIssues.contains { $0.severity == .blocking }
        let shouldRequestApproval = hasBlockingPreflightIssue
            || (
                requiresActionApproval
                    && PaceActionApprovalPolicy.requiresExplicitApproval(
                        for: actionExecutionPlan
                    )
            )
        let approvalRequest = PaceActionApprovalRequest(
            approvalSummary: actionExecutionPlan.approvalSummary,
            preflightSummary: PaceToolPreflightIssue.formatForApproval(preflightIssues),
            requiresActionApproval: shouldRequestApproval
        )
        guard let approvalRequest else {
            return PaceActionApprovalPolicy.shouldExecuteActions(
                request: nil,
                decision: .allowOnce
            )
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = approvalRequest.messageText
        alert.informativeText = approvalRequest.informativeText
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow Once")

        if let smokeAutoCancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + smokeAutoCancelAfter) {
                alert.window.close()
                NSApp.abortModal()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        let approvalDecision: PaceActionApprovalDecision =
            alert.runModal() == .alertSecondButtonReturn ? .allowOnce : .cancel
        return PaceActionApprovalPolicy.shouldExecuteActions(
            request: approvalRequest,
            decision: approvalDecision
        )
    }

    func smokeRequestApprovalForSyntheticActionPlan() -> Bool {
        let syntheticActionPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["smoke@example.com"],
                subject: "Pace approval smoke",
                body: "Synthetic draft used only to verify approval cancellation."
            ))
        ])
        return requestUserApprovalForActionPlan(
            syntheticActionPlan,
            smokeAutoCancelAfter: 0.5
        )
    }

    func smokeShowSyntheticClarification() -> Bool {
        let clarification = PaceIntentClarification(
            question: "Edit selected text or the focused field?",
            options: ["Selected text", "Focused field"]
        )
        pendingIntentClarification = PacePendingIntentClarification(
            originalTranscript: "rewrite that",
            clarification: clarification
        )
        currentTurnHUDState = .clarification(
            question: clarification.question,
            options: clarification.options
        )
        return currentTurnHUDState.status == .needsClarification
    }

    func smokeResolveSyntheticClarification() -> String? {
        guard let pendingIntentClarification else { return nil }
        guard let clarifiedTranscript = PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingIntentClarification,
            selectedOption: "Selected text"
        ) else {
            return nil
        }

        self.pendingIntentClarification = nil
        currentTurnHUDState = .done("clarified")
        return clarifiedTranscript
    }

    func appendActionResult(_ actionResult: PaceActionRunRecord) {
        var updatedActionResults = recentActionResults
        updatedActionResults.insert(actionResult, at: 0)
        if updatedActionResults.count > 8 {
            updatedActionResults.removeLast(updatedActionResults.count - 8)
        }
        recentActionResults = updatedActionResults

        switch actionResult.status {
        case .planned:
            currentTurnHUDState = .acting(actionResult.title)
        case .completed:
            currentTurnHUDState = .done(actionResult.title)
        case .failed, .skipped:
            currentTurnHUDState = .failed(actionResult.detail)
        case .denied:
            currentTurnHUDState = .failed("Action cancelled")
        }
    }

    /// Append one tool-call debug capture for Settings → Debug. Newest
    /// first, capped so the buffer never grows unbounded. Purely an
    /// observability sink — never affects routing, speech, or execution.
    func recordToolCallDebug(_ record: PaceToolCallDebugRecord) {
        var updatedDebugRecords = recentToolCallDebugRecords
        updatedDebugRecords.insert(record, at: 0)
        let maximumRetainedDebugRecords = 25
        if updatedDebugRecords.count > maximumRetainedDebugRecords {
            updatedDebugRecords.removeLast(updatedDebugRecords.count - maximumRetainedDebugRecords)
        }
        recentToolCallDebugRecords = updatedDebugRecords
        // Persist to the JSONL trace file so the history survives restarts
        // and can be inspected outside the app (off the main actor).
        PaceToolCallDebugTrace.append(record)
    }

    /// Clear the Settings → Debug tool-call capture buffer AND the persisted
    /// trace file.
    func clearToolCallDebugRecords() {
        recentToolCallDebugRecords = []
        PaceToolCallDebugTrace.clear()
    }

    /// Seed the in-memory debug list from the persisted trace file so the
    /// Debug tab shows history from previous sessions, not just this one.
    func loadPersistedToolCallDebugRecords() {
        recentToolCallDebugRecords = PaceToolCallDebugTrace.loadRecent(limit: 25)
    }

    /// One line per parsed tool call, e.g. "open_url: Open URL:
    /// https://google.com". "no actions parsed" means the planner produced
    /// only spoken text — which is exactly the "opening the browser menu did
    /// nothing" signature.
    /// True when the streamed planner text is the v10 JSON envelope rather
    /// than free prose. The main (action) planner is decode-constrained to
    /// emit `{spokenText,…}`, so its stream must NOT be spoken raw — the
    /// parsed `spokenText` is flushed at turn end instead. Free prose
    /// (answers, descriptions, the lite race path) never starts with "{".
    nonisolated static func streamedPlannerTextIsStructuredEnvelope(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    static func toolCallDebugSummary(
        for executionPlan: PaceActionExecutionPlan
    ) -> String {
        let parsedActions = executionPlan.flattenedActions
        guard !parsedActions.isEmpty else { return "no actions parsed" }
        return parsedActions
            .map { "\($0.auditOperationName): \($0.approvalDescription)" }
            .joined(separator: "\n")
    }

}
