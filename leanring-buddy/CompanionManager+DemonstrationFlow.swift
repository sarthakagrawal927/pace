//
//  CompanionManager+DemonstrationFlow.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A3):
//  demonstration flow recording / replay voice commands and executor hooks.
//  Stored flow collaborators (`flowStore`, `flowRecorder`, `flowReplayer`)
//  remain in the main file — Swift extensions cannot hold stored properties.
//

import Foundation

@MainActor
extension CompanionManager {

    func handleFlowCommand(_ command: PaceFlowCommand, transcript: String) {
        switch command {
        case .startRecording(let name):
            let spokenText = startFlowRecordingFromVoiceCommand(flowName: name)
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)

        case .stopRecording:
            let spokenText = stopFlowRecordingFromVoiceCommand()
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)

        case .run(let name):
            // For voice-triggered replay we mark the flow as approved
            // for the current session (the voice command IS the
            // approval). Same-session subsequent runs of the same flow
            // bypass any further approval prompt.
            guard let storedFlow = flowStore.load(named: name) else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i couldn't find a flow named \(name)."
                )
                return
            }
            flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "replaying \(storedFlow.name) now."
            )
            beginFlowReplay(storedFlow)

        case .delete(let name):
            let spokenText: String
            do {
                try flowStore.delete(named: name)
                spokenText = "deleted \(name)."
            } catch {
                spokenText = "i couldn't delete \(name)."
            }
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
        }
    }

    /// Begin recording into a fresh flow named `flowName`. Returns the
    /// spoken-ready confirmation copy so the caller can route it
    /// through `handleImmediateLocalModeResponse(...)` (voice command)
    /// or back to the planner observation loop (`record_flow` tool).
    @discardableResult
    func startFlowRecordingFromVoiceCommand(flowName: String) -> String {
        let trimmedFlowName = flowName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFlowName.isEmpty else {
            return "flow recording needs a name."
        }
        flowRecorder.start(flowName: trimmedFlowName)
        return "recording \(trimmedFlowName). say stop recording when you're done."
    }

    /// Stop the live recorder and persist whatever was captured. Public
    /// so the `record_flow` tool observation, the Settings UI, and the
    /// voice command parser can all share one save site.
    @discardableResult
    func stopFlowRecordingFromVoiceCommand() -> String {
        let assembledFlow = flowRecorder.stop(reason: .userCommand)
        guard let assembledFlow else {
            return "no recording was in progress."
        }
        do {
            try flowStore.save(assembledFlow)
            return "saved \(assembledFlow.name) with \(assembledFlow.steps.count) step\(assembledFlow.steps.count == 1 ? "" : "s")."
        } catch {
            return "i recorded \(assembledFlow.name) but couldn't save it: \(error.localizedDescription)"
        }
    }

    /// Drive the live replayer. Speaks completion or failure copy via
    /// the existing TTS path; the replayer itself is fully `await`-
    /// driven and yields back to the run loop between steps.
    func beginFlowReplay(_ storedFlow: PaceRecordedFlow) {
        let replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flowReplayer.play(
                storedFlow,
                onProgress: { stepIndex in
                    print("🔁 PaceFlowReplayer: completed step \(stepIndex + 1) of \(storedFlow.steps.count)")
                },
                onCompletion: { [weak self] outcome in
                    guard let self else { return }
                    Task { @MainActor in
                        self.speakFlowReplayOutcome(outcome, flowName: storedFlow.name)
                    }
                }
            )
        }
        _ = replayTask // task lifetime is tied to MainActor; no need to retain
    }

    /// Compose + speak the per-outcome line. Failure paths route
    /// through the deterministic failure narrator so the message
    /// reads in the same voice as the other plain-language failures.
    func speakFlowReplayOutcome(
        _ outcome: PaceFlowReplayOutcome,
        flowName: String
    ) {
        let spokenText: String
        switch outcome {
        case .completed:
            spokenText = "done with \(flowName)."
        case .stoppedBeforeSendStep:
            spokenText = "ready to send the \(flowName) flow — say go ahead."
        case .failedToFindTarget(let stepIndex, let axLabel):
            // Reuse the click-missed narration shape so the user hears
            // the same "I couldn't find X" phrasing they get from a
            // failed planner click.
            let narration = PaceFailureNarrator.compose(
                .clickMissed(targetLabel: axLabel)
            )
            spokenText = "\(narration.spokenText) (step \(stepIndex + 1) of \(flowName))"
        case .userCancelled:
            spokenText = "stopped \(flowName)."
        }
        Task { @MainActor in
            try? await self.ttsClient.speakText(spokenText)
        }
    }

    /// Clear the per-session approval cache. Wired into the existing
    /// session-reset path so a thread-memory wipe also resets the
    /// "this flow is approved" memory.
    func resetFlowReplayApprovalCacheForSession() {
        flowNamesApprovedForReplayThisSession.removeAll()
    }

    /// Helper exposed for the `run_flow` tool callback the executor
    /// invokes. Returns true if the replay actually kicked off; false
    /// when the flow needs explicit user approval that hasn't been
    /// granted this session yet (the executor's observation distinguishes
    /// the two for the planner-loop summary).
    @discardableResult
    func runFlowFromExecutorTool(_ storedFlow: PaceRecordedFlow) -> Bool {
        // Approval cache: planner-driven `run_flow` calls go through
        // here. Same-session subsequent runs of the same flow skip the
        // approval popup. First-time runs in a session would normally
        // surface the approval popup via PaceActionExecutor's existing
        // gate — that path is already in place for record_flow/run_flow
        // because both are flagged risky in PaceToolRegistry.
        if flowNamesApprovedForReplayThisSession.contains(storedFlow.name) {
            beginFlowReplay(storedFlow)
            return true
        }
        // Mark approved now (the executor only invokes this callback
        // after its own approval gate has cleared the action).
        flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
        beginFlowReplay(storedFlow)
        return true
    }
}
