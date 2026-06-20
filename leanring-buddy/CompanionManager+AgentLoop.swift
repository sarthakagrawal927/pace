//
//  CompanionManager+AgentLoop.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  AI response pipeline — plan-act-observe loop, fast paths, clarification, and main planner dispatch.
//

import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
extension CompanionManager {

    // MARK: - AI Response Pipeline (plan-act-observe loop)

    func routeHUDDetail(for intentPrediction: PaceIntentPrediction) -> String {
        switch intentPrediction.route {
        case .chitchatFastPath:
            return "quick reply"
        case .answerDirectly:
            return "answering without screen"
        case .readScreen:
            return "reading screen"
        case .executeTool:
            return "planning local action"
        case .phoneLargeModel:
            return "local-only fallback"
        case .research:
            return "researching"
        case .fullPipeline:
            return "checking screen and tools"
        }
    }
    func handleChitchatFastPath(transcript: String) {
        handleTextOnlyPlannerFastPath(transcript: transcript)
    }

    func handleClarificationTurn(
        transcript: String,
        clarification: PaceIntentClarification
    ) {
        let optionsText = clarification.options.isEmpty
            ? ""
            : " \(clarification.options.joined(separator: " or "))?"
        let clarificationText = clarification.question.hasSuffix("?")
            ? clarification.question
            : clarification.question + optionsText

        pendingIntentClarification = PacePendingIntentClarification(
            originalTranscript: transcript,
            clarification: clarification
        )
        currentTurnHUDState = .clarification(
            question: clarification.question,
            options: clarification.options
        )
        recordConversationTurn(
            userTranscript: transcript,
            assistantResponse: clarificationText
        )

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(clarificationText)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: clarificationText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    func resolveClarification(option: String) {
        // A pending click-target clarification carries an exact target the
        // user just chose, so it takes precedence over the transcript-rewrite
        // path: resolving it clicks the chosen candidate directly instead of
        // re-running the planner (which could re-rank into a different set).
        if pendingClickTargetClarification != nil {
            resolveClickTargetClarification(selectedOptionLabel: option)
            return
        }

        guard let pendingIntentClarification else {
            currentTurnHUDState = .failed("Clarification expired")
            return
        }

        guard let clarifiedTranscript = PaceIntentClarificationResolver.clarifiedTranscript(
            for: pendingIntentClarification,
            selectedOption: option
        ) else {
            currentTurnHUDState = .failed("Unknown clarification option")
            return
        }

        self.pendingIntentClarification = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        ttsClient.stopPlayback()
        streamingSentenceTTSPipeline.resetForNewTurn()
        clearLastSpokenReplyState()
        responseOverlayManager.finishStreaming()
        currentTurnHUDState = .understanding("using \(option.lowercased())")
        sendTranscriptToPlannerWithScreenshot(transcript: clarifiedTranscript)
    }

    /// Visual-target ambiguity raise (PRD
    /// docs/prds/hud-intent-disambiguator.md). When the parsed plan is a
    /// single click whose candidate set has near-tied distinguishable
    /// labels, set the HUD into the same clarification state the
    /// edit/destructive path uses (so the panel renders option chips with
    /// no new view code), store the candidate set + screen captures, and
    /// return true to tell the agent loop to pause. Returns false when
    /// there's a clear winner — the common, zero-friction case.
    ///
    /// Only fires for genuine click-candidate plans. Coordinate-only
    /// `[CLICK:x,y]` planner output never reaches here because it parses
    /// to `.click`, not `.clickCandidates` — when the planner gives exact
    /// coordinates we trust them.
    func raiseClickTargetClarificationIfAmbiguous(
        actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) -> Bool {
        // Only a single, lone click-candidates action qualifies. A
        // multi-action plan (e.g. click then type) is the planner driving a
        // sequence — interrupting it mid-stream would strand the rest.
        let flattenedActions = actionExecutionPlan.flattenedActions
        guard flattenedActions.count == 1,
              case .clickCandidates(let clickCandidateSet) = flattenedActions[0] else {
            return false
        }

        guard let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(clickCandidateSet),
              let clarification = PaceClickTargetClarificationBuilder.makeClarification(
                  offeredCandidates: offeredCandidates,
                  in: clickCandidateSet
              ) else {
            return false
        }

        let optionLabels = clarification.options.map(\.label)
        pendingClickTargetClarification = PacePendingClickTargetClarification(
            prompt: clarification.prompt,
            options: clarification.options,
            candidateSet: clickCandidateSet,
            screenCaptures: screenCaptures
        )
        currentTurnHUDState = .clarification(
            question: clarification.prompt,
            options: optionLabels
        )
        appendActionResult(PaceActionRunRecord(
            status: .skipped,
            title: "Which target?",
            detail: optionLabels.joined(separator: " / ")
        ))
        print("❔ Click-target clarification: \(optionLabels.joined(separator: " / "))")
        return true
    }

    /// Set-of-Mark click recovery: for any observation flagged as an all-fail
    /// click, render numbered marks on the same screenshot the click was planned
    /// against, ask the VLM which mark is the intended element, and re-click. On
    /// success the failure observation is replaced with a recovery success; on
    /// failure the original observation stands and the planner re-plans as
    /// before. Only fires on a miss — the happy path is untouched. See PRD
    /// docs/prds/set-of-mark-click-recovery.md.
    func attemptSetOfMarkClickRecovery(
        observations: [PaceActionExecutionObservation],
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        guard PaceUserPreferencesStore.boolWithInfoPlistSeed(
            .enableSetOfMarkClickRecovery,
            infoPlistKey: "EnableSetOfMarkClickRecovery"
        ) else {
            return observations
        }
        guard !screenCaptures.isEmpty else { return observations }

        var updatedObservations = observations
        for (observationIndex, observation) in observations.enumerated() {
            guard let recoveryRequest = observation.setOfMarkRecovery else { continue }

            // Pick the capture the failed click targeted: its screen number,
            // else the cursor screen, else the first capture.
            let targetCapture: CompanionScreenCapture
            if let screenNumber = recoveryRequest.screenNumber,
               screenNumber >= 1, screenNumber <= screenCaptures.count {
                targetCapture = screenCaptures[screenNumber - 1]
            } else if let cursorCapture = screenCaptures.first(where: { $0.isCursorScreen }) {
                targetCapture = cursorCapture
            } else {
                targetCapture = screenCaptures[0]
            }

            // Reuse the element map built for the failed click; if it has aged
            // out, skip recovery and let the original failure stand.
            guard let cachedAnalysis = screenContextService.cachedAnalysisIfFresh(
                screenLabel: targetCapture.label
            ) else {
                continue
            }

            let targetDescription = recoveryRequest.targetDescription.isEmpty
                ? "the element the user asked to click"
                : recoveryRequest.targetDescription

            let resolvedLocation = await PaceSetOfMarkClickRecovery.resolve(
                inputs: PaceSetOfMarkClickRecovery.Inputs(
                    screenshotImageData: targetCapture.imageData,
                    elements: cachedAnalysis.elements,
                    targetDescription: targetDescription,
                    screenNumber: recoveryRequest.screenNumber
                ),
                renderMarks: { imageData, boxes in
                    PaceSetOfMarkRenderer.drawMarks(onJPEG: imageData, boxes: boxes)
                },
                groundMark: { [weak self] markedImageData, target, markCount in
                    await self?.screenContextService.groundMarkedClickTarget(
                        markedImageData: markedImageData,
                        targetDescription: target,
                        markCount: markCount
                    ) ?? nil
                }
            )

            guard let resolvedLocation else { continue }

            let didRecover = await actionExecutor.executeRecoveredClick(
                at: resolvedLocation,
                screenCaptures: screenCaptures
            )
            if didRecover {
                print("🎯 Set-of-Mark recovery succeeded for \"\(targetDescription)\"")
                updatedObservations[observationIndex] = PaceActionExecutionObservation(
                    toolName: "click_candidates",
                    summary: "Recovered the missed click via on-screen marks: clicked \"\(targetDescription)\"."
                )
            }
        }
        return updatedObservations
    }

    /// Resolves a pending click-target clarification by clicking the
    /// candidate the user tapped. Executes the chosen target directly via
    /// a one-candidate plan — does NOT re-run the planner. Falls back to
    /// the executor's existing top-candidate auto-click when the option
    /// can't be matched, so a stray tap never strands the turn.
    func resolveClickTargetClarification(selectedOptionLabel: String) {
        guard let pendingClickTargetClarification else {
            currentTurnHUDState = .failed("Clarification expired")
            return
        }
        self.pendingClickTargetClarification = nil

        let screenCaptures = pendingClickTargetClarification.screenCaptures
        let chosenCandidate = pendingClickTargetClarification
            .candidate(forSelectedOptionLabel: selectedOptionLabel)

        // The chosen candidate becomes the sole candidate of a fresh
        // single-target plan. When the option can't be matched, fall back
        // to the full original set so the executor's top-candidate
        // auto-click still runs — never strand the turn.
        let resolvedCandidateSet: PaceClickCandidateSet
        if let chosenCandidate {
            resolvedCandidateSet = PaceClickCandidateSet(
                candidates: [chosenCandidate],
                clickCount: pendingClickTargetClarification.candidateSet.clickCount
            )
        } else {
            resolvedCandidateSet = pendingClickTargetClarification.candidateSet
        }

        currentTurnHUDState = .acting("clicking \(selectedOptionLabel)")
        let clickPlan = PaceActionExecutionPlan.serial(
            actions: [.clickCandidates(resolvedCandidateSet)]
        )

        currentResponseTask = Task { @MainActor in
            let toolObservations = await actionExecutor.executeActionPlan(
                clickPlan,
                screenCaptures: screenCaptures
            )
            guard !Task.isCancelled else { return }
            if !toolObservations.isEmpty {
                appendActionResult(.completed(observations: toolObservations))
                speakFailureForClickMissedIfApplicable(
                    observations: toolObservations,
                    clickTargetLabel: selectedOptionLabel
                )
            }
            if currentTurnHUDState.status == .acting {
                currentTurnHUDState = .done("clicked \(selectedOptionLabel)")
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    /// Falls back to the executor's existing top-candidate auto-click when
    /// a pending click-target clarification is dismissed or times out
    /// without a choice, so an unanswered question never strands the turn.
    /// Wired to outside-click dismissal / a new turn beginning.
    func dismissPendingClickTargetClarificationWithAutoClick() {
        guard let pendingClickTargetClarification else { return }
        self.pendingClickTargetClarification = nil

        let screenCaptures = pendingClickTargetClarification.screenCaptures
        let originalCandidateSet = pendingClickTargetClarification.candidateSet
        currentTurnHUDState = .acting("clicking best match")
        let clickPlan = PaceActionExecutionPlan.serial(
            actions: [.clickCandidates(originalCandidateSet)]
        )
        currentResponseTask = Task { @MainActor in
            let toolObservations = await actionExecutor.executeActionPlan(
                clickPlan,
                screenCaptures: screenCaptures
            )
            guard !Task.isCancelled else { return }
            if !toolObservations.isEmpty {
                appendActionResult(.completed(observations: toolObservations))
            }
            if currentTurnHUDState.status == .acting {
                currentTurnHUDState = .done("turn finished")
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    func handleUnsupportedTurn(
        transcript: String,
        unsupportedResponse: PaceIntentUnsupportedResponse
    ) {
        currentTurnHUDState = .unsupported(unsupportedResponse.reason)
        recordConversationTurn(
            userTranscript: transcript,
            assistantResponse: unsupportedResponse.spokenText
        )

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(unsupportedResponse.spokenText)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: unsupportedResponse.spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    /// Fast path for pure knowledge questions. Skips screenshot capture,
    /// AX, OCR, VLM, and agent-mode tool docs. Uses the dedicated
    /// text-only planner so short answers can ride Apple Foundation
    /// Models when available while action/screen turns stay on the
    /// larger local planner.
    func handleTextOnlyPlannerFastPath(transcript: String) {
        currentTurnHUDState = .understanding("answering without screen")
        responseOverlayManager.showOverlayAndBeginStreaming()

        // Capture self weakly so this matches the weak capture in the nested
        // eager-filler task below and never extends the manager's lifetime.
        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            voiceState = .processing

            do {
                let plannerForTextOnlyTurn = textOnlyPlannerClient
                plannerForTextOnlyTurn.resetForNewTurn()
                print("🧠 Text-only planner: using \(plannerForTextOnlyTurn.displayName)")

                let historyForPlanner = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let userPromptForPlanner = await appendLocalRetrievalContext(
                    to: transcript,
                    query: transcript,
                    route: .answerDirectly
                )

                let threadSummaryInjectionForTurn = threadMemory.injectionPrefix()

                let plannerStartedAt = Date()

                let (fullResponseText, _) = try await plannerForTextOnlyTurn.generateResponseStreaming(
                    images: [],
                    systemPrompt: CompanionSystemPrompt.buildTextOnly(
                        threadSummaryInjection: threadSummaryInjectionForTurn
                    ),
                    conversationHistory: historyForPlanner,
                    userPrompt: userPromptForPlanner,
                    onTextChunk: { [weak self] accumulatedPlannerText in
                        self?.responseOverlayManager.updateStreamingText(accumulatedPlannerText)
                        Task { @MainActor [weak self] in
                            await self?.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedPlannerText)
                        }
                    }
                )
                guard !Task.isCancelled else { return }

                let actionParseResult = PaceActionTagParser.parseActions(from: fullResponseText)
                let (_, textAfterDoneStrip) = PaceTagParsers.parseAndStripDoneSignal(from: actionParseResult.spokenText)
                let pointingParseResult = PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip)
                let spokenText = pointingParseResult.spokenText

                // Settings → Debug capture: pure-knowledge turns never run a
                // screenshot/VLM and never execute actions here — surfaced so
                // a misrouted action command (answered instead of acted) is
                // visible as a text-only row.
                recordToolCallDebug(PaceToolCallDebugRecord(
                    transcript: transcript,
                    lane: .textOnly,
                    routingDetail: "pureKnowledge · text-only planner (no screen)",
                    plannerPathDetail: plannerForTextOnlyTurn.displayName,
                    rawPlannerOutput: fullResponseText,
                    spokenText: spokenText,
                    parsedActionsSummary: Self.toolCallDebugSummary(
                        for: actionParseResult.executionPlan
                    ),
                    dispatchSummary: "spoken-only — the text-only path does not execute actions",
                    plannerLatencyMs: Int(Date().timeIntervalSince(plannerStartedAt) * 1000),
                    totalTurnLatencyMs: Int(Date().timeIntervalSince(plannerStartedAt) * 1000),
                    userPrompt: userPromptForPlanner
                ))

                recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)

                responseOverlayManager.updateStreamingText(spokenText)
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
                    voiceState = .responding
                }

                while ttsClient.isPlaying {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }

                responseOverlayManager.finishStreaming()
                voiceState = .idle
                currentTurnHUDState = .done("answered")
                if isWalkingAvatarEnabled {
                    avatarOverlayManager?.show()
                }
            } catch {
                print("⚠️ Text-only planner fast path failed: \(error.localizedDescription)")
                responseOverlayManager.updateStreamingText("i hit a local planner issue.")
                responseOverlayManager.finishStreaming()
                voiceState = .idle
                currentTurnHUDState = .failed("Local planner issue")
            }
        }
    }

    /// Fast path for deterministic local actions that do not need screen
    /// perception or planner reasoning. This keeps "open Raycast" /
    /// "volume down" in the sub-second local-control lane while preserving
    /// the same approval, preflight, result, and TTS surfaces as planner
    /// generated actions.
    func handleFastLocalActionPath(
        transcript: String,
        fastActionParseResult: PaceFastActionParseResult
    ) {
        let spokenText = fastActionParseResult.spokenText
        currentTurnHUDState = .acting(fastActionParseResult.executionPlan.approvalSummary)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)

        currentResponseTask = Task {
            let turnStartedAt = Date()
            voiceState = .responding
            let shouldSpeakInitialFastActionText = !actionExecutor.actionsAreEnabled
                || !PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                    for: fastActionParseResult.executionPlan
                )

            if shouldSpeakInitialFastActionText,
               !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            }

            let preflightIssues = PaceToolPreflight.evaluate(
                actionExecutionPlan: fastActionParseResult.executionPlan,
                environment: currentToolPreflightEnvironment()
            )
            appendActionResult(.planned(
                actionExecutionPlan: fastActionParseResult.executionPlan,
                preflightIssues: preflightIssues
            ))

            var fastPathDispatchSummaryForDebug = "executed"
            if actionExecutor.actionsAreEnabled {
                if requestUserApprovalForActionPlan(
                    fastActionParseResult.executionPlan,
                    preflightIssues: preflightIssues
                ) {
                    let toolObservations = await actionExecutor.executeActionPlan(
                        fastActionParseResult.executionPlan,
                        screenCaptures: []
                    )
                    fastPathDispatchSummaryForDebug = toolObservations.isEmpty
                        ? "executed — no observations returned"
                        : PaceActionExecutionObservation.formatForPlanner(toolObservations)
                    if !toolObservations.isEmpty {
                        appendActionResult(.completed(observations: toolObservations))
                        noteReversibleActionExecuted(
                            in: fastActionParseResult.executionPlan
                        )
                        speakFailureForClickMissedIfApplicable(
                            observations: toolObservations,
                            clickTargetLabel: Self.firstClickCandidateLabel(
                                in: fastActionParseResult.executionPlan
                            )
                        )
                    }
                    speakFailureForBlockingPreflightIfApplicable(
                        preflightIssues: preflightIssues
                    )
                    if let userFeedbackText = PaceActionExecutionObservation
                        .formatForUserFeedback(toolObservations) {
                        responseOverlayManager.updateStreamingText(userFeedbackText)
                        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: userFeedbackText)
                    }
                } else {
                    fastPathDispatchSummaryForDebug = "denied by user"
                    appendActionResult(PaceActionRunRecord(
                        status: .denied,
                        title: "Action denied",
                        detail: fastActionParseResult.executionPlan.approvalSummary
                    ))
                    print("🛑 Fast local action approval denied")
                }
            } else {
                fastPathDispatchSummaryForDebug = "EnableActions=false — not executed"
                appendActionResult(PaceActionRunRecord(
                    status: .skipped,
                    title: "Actions disabled",
                    detail: "Parsed local fast action, but EnableActions is false."
                ))
                print("🤖 Fast local action parsed but EnableActions is false")
            }

            // Settings → Debug capture: the fast path matched before any
            // planner ran, so this row proves a command stayed local and
            // shows exactly what it parsed to.
            recordToolCallDebug(PaceToolCallDebugRecord(
                transcript: transcript,
                lane: .fastPath,
                routingDetail: "fast local parser matched (no screenshot, VLM, or planner)",
                rawPlannerOutput: "",
                spokenText: spokenText,
                parsedActionsSummary: Self.toolCallDebugSummary(
                    for: fastActionParseResult.executionPlan
                ),
                dispatchSummary: fastPathDispatchSummaryForDebug,
                totalTurnLatencyMs: Int(Date().timeIntervalSince(turnStartedAt) * 1000),
                userPrompt: transcript
            ))

            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if self.currentTurnHUDState.status == .acting {
                self.currentTurnHUDState = .done("local action finished")
            }
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
            currentDictationTrigger = .keyboard
            scheduleTransientHideIfNeeded()
        }
    }

    /// Explicit voice control for the watch loop. This runs before intent
    /// classification because starting/stopping watch mode is a local mode
    /// switch, not a planner task.
    func handleWatchModeCommand(_ command: PaceWatchModeCommand, transcript: String) {
        let enabled: Bool
        let spokenText: String

        switch command {
        case .start:
            enabled = true
            spokenText = isWatchModeEnabled ? "watch mode is already on" : "watch mode is on"
        case .stop:
            enabled = false
            spokenText = isWatchModeEnabled ? "watch mode is off" : "watch mode is already off"
        }

        setWatchModeEnabled(enabled)
        currentTurnHUDState = .done(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)

        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            if isWalkingAvatarEnabled {
                avatarOverlayManager?.show()
            }
        }
    }

    /// Multi-step agent loop: capture screens → optional local VLM →
    /// planner → execute actions → re-screenshot → repeat. Each step is
    /// at most one planner round-trip and one action sequence. The loop
    /// exits when the planner emits `[DONE]`, when no action tags are
    /// emitted (it's a pure conversational answer), or when the per-task
    /// step budget is hit.
    ///
    /// The user's spoken transcript becomes the first turn's prompt;
    /// subsequent turns get a fixed "continue the task" prompt so the
    /// planner re-anchors on the conversation history rather than a
    /// repeated user statement.
    func sendTranscriptToPlannerWithScreenshot(transcript: String) {
        Task { @MainActor in
            await sendTranscriptToPlannerWithScreenshotAsync(transcript: transcript)
        }
    }

    func sendTranscriptToPlannerWithScreenshotAsync(transcript: String) async {
        currentResponseTask?.cancel()
        ttsClient.stopPlayback()
        pendingIntentClarification = nil
        // A new turn supersedes any unanswered click-target question —
        // drop it silently rather than auto-clicking, because the user
        // chose to keep talking instead of answering.
        pendingClickTargetClarification = nil
        // Tuition-mode annotations live until the next user turn or the
        // 30 s auto-fade. PTT-release IS the next user turn, so wipe
        // them here BEFORE any routing branch — every fast path
        // (watch-mode, recipe, memory, fast-action) clears them too.
        annotationOverlayController.clearOnNextUserTurn()

        // Idle gate: if the thread sat quiet past the configured
        // threshold, drop the verbatim window + summary and journal
        // a "session ended" line. The next turn starts a fresh
        // session. Runs synchronously here AND from a low-frequency
        // sweep timer so the menu-bar surface drops "session live"
        // indicators without needing a new turn.
        evaluateThreadIdleAndResetIfNeeded(now: Date())

        // Tell the planner this is a fresh user turn. Stateful conformers
        // (Apple Foundation Models) wipe their cross-call session state
        // here so the next turn doesn't drag in 7 prior agent-loop steps
        // and bust the 4K context window. Stateless conformers (LocalPlanner)
        // no-op.
        plannerClient.resetForNewTurn()

        if let watchModeCommand = PaceWatchModeCommandParser.parse(transcript) {
            print("👀 Watch mode voice command: \(watchModeCommand)")
            handleWatchModeCommand(watchModeCommand, transcript: transcript)
            return
        }

        // Tuition-mode "clear annotations" fast path: never burn a
        // planner round-trip on a pure overlay-clear command. Runs
        // after watch-mode (which has its own start/stop verbs that
        // would tie a "stop drawing" phrase) but before every other
        // routing branch.
        if PaceClearAnnotationsCommandParser.parse(transcript) != nil {
            print("🧽 Clear-annotations voice command")
            // clearOnNextUserTurn() at the top of this function has
            // already wiped the layer; this second call is a safe
            // no-op and serves as the user-feedback log line.
            annotationOverlayController.clear(reason: "voice command")
            voiceState = .idle
            return
        }

        // Research-cancel fast path: when a research turn is in flight,
        // "stop researching" / "cancel research" cancels the running
        // task without burning a planner round-trip. When NO research
        // turn is active, the parse still matches but the cancel is a
        // safe no-op — same shape as the clear-annotations fast path.
        if PaceResearchCancelCommandParser.parse(transcript) != nil {
            print("🛑 Research-cancel voice command")
            currentResponseTask?.cancel()
            currentResponseTask = nil
            isOffDeviceTurnInFlight = false
            voiceState = .idle
            currentTurnHUDState = .done("stopped researching")
            Task { [weak self] in
                try? await self?.ttsClient.speakText("Stopped.")
            }
            return
        }

        if let alwaysListeningCommand = PaceAlwaysListeningCommandParser.parse(transcript) {
            print("🎙️ Always-listening voice command: \(alwaysListeningCommand)")
            handleAlwaysListeningCommand(alwaysListeningCommand, transcript: transcript)
            return
        }

        if let localMemoryCommand = PaceLocalMemoryCommandParser.parse(transcript) {
            print("🧠 Local memory command: \(localMemoryCommand)")
            handleLocalMemoryCommand(localMemoryCommand)
            return
        }

        if let recipeCommand = PaceRecipeCommandParser.parse(transcript) {
            print("📦 Recipe voice command: \(recipeCommand)")
            handleRecipeCommand(recipeCommand, transcript: transcript)
            return
        }

        if let flowCommand = PaceFlowCommandParser.parse(transcript) {
            print("🔁 Flow voice command: \(flowCommand)")
            handleFlowCommand(flowCommand, transcript: transcript)
            return
        }

        // "remember this as the cloudflare dashboard" — capture the current
        // tab URL under a user-chosen name (Tier 1 × Tier 3).
        if let rememberSiteCommand = PaceRememberSiteCommandParser.parse(transcript: transcript) {
            print("🔖 Remember-site command: \(rememberSiteCommand)")
            handleRememberSiteCommand(rememberSiteCommand, transcript: transcript)
            return
        }

        // "open the cloudflare dashboard" — recall a user-taught destination
        // on the fast path (no VLM, no planner). Only matches names the user
        // actually saved, so non-matching opens fall through below.
        if let destination = PaceNamedDestinationStore.shared.recall(matching: transcript) {
            print("🔖 Opening user-named destination: \(destination.displayName)")
            handleFastLocalActionPath(
                transcript: transcript,
                fastActionParseResult: PaceFastActionParseResult(
                    spokenText: "opening \(destination.displayName).",
                    executionPlan: .serial(actions: [.openURL(destination.url)])
                )
            )
            return
        }

        // Fast-path chitchat ("hi pace", "thanks") with a canned response
        // — skips VLM + planner + agent loop entirely. ~2200ms → ~50ms.
        // Conservative: only fires when the classifier is confident
        // enough to return .chitchat (not .unknown). Anything ambiguous
        // falls through to the full pipeline.
        let intentPrediction = await intentClassifier.classify(transcript)
        lastIntentRouteForEpisodicExtraction = intentPrediction.intent
        currentTurnHUDState = .understanding(routeHUDDetail(for: intentPrediction))
        if let clarification = PaceIntentClarifier.clarification(for: transcript) {
            print("❔ Intent clarification: \(clarification.question)")
            handleClarificationTurn(transcript: transcript, clarification: clarification)
            return
        }
        // Research escalation route — "research X" / "look into Y" /
        // "compare A vs B" type turns. Per-turn planner override
        // pulled from PaceResearchTierStore (CLI bridge to Claude
        // Code, OR Direct API to Anthropic Opus, OR off → fall
        // through to the .phoneLargeModel route below). The override
        // lives in `researchTurnPlannerOverride` (declared just before
        // the agent loop so the loop picks it up). When the user
        // hasn't configured a research tier yet, downgrade the route
        // to .phoneLargeModel so the existing cloud-bridge path still
        // works. Setting researchTurnMaxAgentSteps higher than
        // AgentMaxSteps gives the research loop room to fetch + read
        // + synthesize across MCP tool calls.
        var researchTurnPlannerOverride: (any BuddyPlannerClient)?
        var researchTurnMaxAgentSteps: Int?
        var researchTurnConfiguration: PaceResearchTierConfiguration?
        var mutableIntentPrediction = intentPrediction
        if mutableIntentPrediction.route == .research {
            let loadedResearchConfiguration = PaceResearchTierStore.loadConfiguration()
            researchTurnConfiguration = loadedResearchConfiguration
            switch loadedResearchConfiguration.tier {
            case .off:
                print("🔬 Research intent but tier is OFF — falling back to phoneLargeModel route")
                mutableIntentPrediction = PaceIntentPrediction(
                    intent: .phoneLargeModel,
                    confidence: intentPrediction.confidence
                )
            case .cliBridge:
                // Direct-spawn the local CLI — no Node bridge needed.
                // Maps `claude`/`codex` upstream choices to the
                // direct-spawn planner; the deprecated `.gemini`
                // upstream falls back to the legacy Node bridge
                // because gemini-cli's headless contract is too
                // different to port (see PaceLocalCLIPlannerClient).
                let directSpawnUpstream: PaceLocalCLIUpstream?
                switch loadedResearchConfiguration.cliBridgeUpstream {
                case .claude:
                    directSpawnUpstream = .claude
                case .codex:
                    directSpawnUpstream = .codex
                case .gemini:
                    directSpawnUpstream = nil
                }
                if let directSpawnUpstream {
                    researchTurnPlannerOverride = PaceLocalCLIPlannerClient(
                        upstream: directSpawnUpstream,
                        modelIdentifier: loadedResearchConfiguration.cliBridgeModel
                    )
                    print("🔬 Routing research turn to local CLI (\(directSpawnUpstream.displayLabel)/\(loadedResearchConfiguration.cliBridgeModel))")
                } else {
                    // Legacy bridge fallback for gemini-cli only.
                    let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
                    researchTurnPlannerOverride = CloudBridgePlannerClient(
                        bridgeBaseURL: bridgeConfiguration.baseURL,
                        upstreamProvider: loadedResearchConfiguration.cliBridgeUpstream,
                        modelIdentifier: loadedResearchConfiguration.cliBridgeModel
                    )
                    PaceCloudBridgeConsent.markFirstUsedIfUnset(now: Date())
                    print("🔬 Routing research turn to legacy Node bridge (gemini fallback)")
                }
                researchTurnMaxAgentSteps = loadedResearchConfiguration.maximumAgentSteps
                isOffDeviceTurnInFlight = true
                let upstreamLabel = loadedResearchConfiguration.cliBridgeUpstream.displayLabel.lowercased()
                currentTurnHUDState = .understanding("researching with \(upstreamLabel) \(loadedResearchConfiguration.cliBridgeModel.lowercased())…")
                Task { [weak self] in
                    try? await self?.ttsClient.speakText(
                        "Researching that — give me a minute."
                    )
                }
            case .directAPI:
                let resolvedEndpointURLString = PaceResearchTierStore
                    .resolvedDirectAPIEndpointURLString(for: loadedResearchConfiguration)
                if let resolvedEndpointURL = URL(string: resolvedEndpointURLString),
                   !resolvedEndpointURLString.isEmpty {
                    researchTurnPlannerOverride = DirectAPIPlannerClient(
                        provider: loadedResearchConfiguration.directAPIProvider,
                        endpointURL: resolvedEndpointURL,
                        modelIdentifier: loadedResearchConfiguration.directAPIModelIdentifier
                    )
                    researchTurnMaxAgentSteps = loadedResearchConfiguration.maximumAgentSteps
                    isOffDeviceTurnInFlight = true
                    let providerLabel = loadedResearchConfiguration.directAPIProvider.displayLabel.lowercased()
                    currentTurnHUDState = .understanding("researching with \(providerLabel) \(loadedResearchConfiguration.directAPIModelIdentifier)…")
                    print("🔬 Routing research turn to Direct API (\(providerLabel)/\(loadedResearchConfiguration.directAPIModelIdentifier))")
                    Task { [weak self] in
                        try? await self?.ttsClient.speakText(
                            "Researching that — give me a minute."
                        )
                    }
                } else {
                    print("⚠️ Research Direct-API endpoint URL is empty/invalid; falling back to phoneLargeModel route")
                    mutableIntentPrediction = PaceIntentPrediction(
                        intent: .phoneLargeModel,
                        confidence: intentPrediction.confidence
                    )
                }
            }
        }

        // When the intent is phoneLargeModel and the user has set up the cloud bridge,
        // route the turn through the bridge instead of refusing it with a local-only message.
        // This is the one intentional break of the no-cloud-LLM principle — consent-gated.
        if mutableIntentPrediction.route == .phoneLargeModel {
            let currentBridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
            let bridgeIsActiveForThisTurn = currentBridgeConfiguration.hasUserAcceptedConsent
                && (currentBridgeConfiguration.mode == .hybrid
                    || currentBridgeConfiguration.mode == .alwaysBridge)

            if bridgeIsActiveForThisTurn {
                // Signal HybridPlannerClient (or CloudBridgePlannerClient directly in
                // alwaysBridge mode) to use the large-model path for this turn.
                if let hybridPlanner = plannerClient as? HybridPlannerClient {
                    hybridPlanner.routingHintForNextCall = .preferLarge
                }
                // Record first-use so the 24-hour soak timer starts ticking.
                PaceCloudBridgeConsent.markFirstUsedIfUnset(now: Date())
                isCloudBridgeCallActive = true
                isOffDeviceTurnInFlight = true

                let upstreamDisplayName = currentBridgeConfiguration.upstream.displayLabel
                let bridgeRoutingHUDDetail = "thinking with \(upstreamDisplayName.lowercased())…"
                currentTurnHUDState = .understanding(bridgeRoutingHUDDetail)
                print("📡 Routing phoneLargeModel turn to cloud bridge (\(upstreamDisplayName))")
                // Speak the "phone a friend" announcement immediately (fire-and-
                // forget so it doesn't block the bridge call) — it both sets the
                // expectation that this turn goes off-device AND masks the
                // bridge's spin-up latency, so the user isn't left in silence.
                Task { [weak self] in
                    try? await self?.ttsClient.speakText(
                        "Let me phone a friend for this one — give me a sec."
                    )
                }
                // Fall through to the normal planner pipeline — the routing hint
                // will cause the planner to call the bridge.
            } else {
                // Bridge is off or consent not given — keep the existing local-only message.
                if let unsupportedResponse = PaceIntentUnsupportedDetector.unsupportedResponse(
                    for: transcript,
                    prediction: mutableIntentPrediction
                ) {
                    print("🚫 Unsupported intent: \(unsupportedResponse.reason)")
                    handleUnsupportedTurn(transcript: transcript, unsupportedResponse: unsupportedResponse)
                    return
                }
            }
        } else if let unsupportedResponse = PaceIntentUnsupportedDetector.unsupportedResponse(
            for: transcript,
            prediction: mutableIntentPrediction
        ) {
            print("🚫 Unsupported intent: \(unsupportedResponse.reason)")
            handleUnsupportedTurn(transcript: transcript, unsupportedResponse: unsupportedResponse)
            return
        }
        if mutableIntentPrediction.intent == .chitchat {
            print("🎯 Intent: chitchat (confidence \(String(format: "%.2f", mutableIntentPrediction.confidence))) — fast-path")
            handleChitchatFastPath(transcript: transcript)
            return
        }
        if mutableIntentPrediction.route == .answerDirectly {
            print("🎯 Intent: pureKnowledge (confidence \(String(format: "%.2f", mutableIntentPrediction.confidence))) — text-only planner")
            handleTextOnlyPlannerFastPath(transcript: transcript)
            return
        }
        // Fast local-action path is skipped for research turns —
        // research wants the heavyweight planner, not a deterministic
        // "open Music" shortcut.
        if researchTurnPlannerOverride == nil,
           let fastActionParseResult = PaceFastActionCommandParser.parse(transcript: transcript) {
            print("🎯 Intent: fastLocalAction — skipping screenshot, VLM, and planner")
            handleFastLocalActionPath(
                transcript: transcript,
                fastActionParseResult: fastActionParseResult
            )
            return
        }
        print("🎯 Intent: \(mutableIntentPrediction.intent.rawValue) (confidence \(String(format: "%.2f", mutableIntentPrediction.confidence))) — \(mutableIntentPrediction.route.rawValue)")
        currentTurnHUDState = .understanding(routeHUDDetail(for: mutableIntentPrediction))

        // Capture for the Task closure: a Sendable bundle of the
        // per-turn planner override + step ceiling so the agent loop
        // body doesn't have to read CompanionManager state for them.
        let plannerClientForThisTurn: any BuddyPlannerClient = researchTurnPlannerOverride ?? plannerClient
        let capturedResearchConfiguration = researchTurnConfiguration
        // Whether this turn took the research route; flips the
        // system-prompt build to `buildForResearchTurn` so the
        // headless CLI gets a research-shaped prompt instead of
        // Pace's agent-mode tool docs.
        let isResearchTurn: Bool = (researchTurnPlannerOverride != nil)

        currentResponseTask = Task {
            voiceState = .processing

            let turnStartedAt = Date()
            // Research turns get a larger step ceiling from
            // PaceResearchTierStore so the planner can fetch + read +
            // synthesize across multiple MCP calls. Other turns use
            // the existing Info.plist AgentMaxSteps default.
            let maxAgentStepCount = researchTurnMaxAgentSteps
                ?? PaceTagParsers.readMaxAgentStepCount()
            // Cumulative coarse output-token estimate across the turn.
            // When non-nil, the loop bails once it crosses the
            // research config's perTurnTokenBudgetCap so a runaway
            // loop can't blow the user's bill.
            var cumulativeOutputTokenEstimate = 0
            var stepIndex = 0
            var currentTurnUserPrompt = transcript
            var pendingPostActionFeedbackText: String?
            let streamingMailDraftDetector = PaceStreamingMailDraftDetector()

            do {
                agentStepLoop: while stepIndex < maxAgentStepCount {
                    stepIndex += 1
                    streamingMailDraftDetector.reset()
                    let isFirstStep = (stepIndex == 1)
                    guard !Task.isCancelled else { return }

                    // 1. Capture screens for this step. On the first step,
                    // prefer the PTT-press prewarm capture if it finished:
                    // it already contains the cursor screen plus enriched
                    // analysis, so re-capturing before consuming it just
                    // adds latency to the hot path.
                    let screenCaptureStartedAt = Date()
                    var prewarmedContextForStep: PaceScreenContextPrewarmedSnapshot?
                    let screenCaptures: [CompanionScreenCapture]
                    if isFirstStep,
                       screenContextService.hasInFlightPrewarmedTask {
                        print("👁️  Awaiting pre-warm capture for first agent step…")
                        let prewarmedContext = await screenContextService.consumeInFlightPrewarmedSnapshot()
                        if let prewarmedContext,
                           !prewarmedContext.screenCaptures.isEmpty {
                            prewarmedContextForStep = prewarmedContext
                            screenCaptures = prewarmedContext.screenCaptures
                            print("👁️  First step using pre-warmed capture(s): \(screenCaptures.count)")
                        } else {
                            print("⚠️ Pre-warm capture unavailable — capturing screens now")
                            screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        }
                    } else {
                        screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    }
                    guard !Task.isCancelled else { return }
                    let screenCaptureElapsedMs = Int(
                        Date().timeIntervalSince(screenCaptureStartedAt) * 1000
                    )
                    // Per-stage timing — combined with TTFT/TTFSW these
                    // explain where each turn's budget actually goes.
                    // Useful when verifying that a perceived slowdown is
                    // (e.g.) screen capture vs. planner inference.
                    print("⏱  Step \(stepIndex) screen capture: \(screenCaptureElapsedMs)ms")

                    // System prompt + thread-memory injection are cheap
                    // (no VLM call) so they're computed BEFORE the planner
                    // branch below. The agent-mode block is omitted when
                    // EnableActions is off — pure prefill savings.
                    let isAgentModeEnabled = AppBundleConfiguration
                        .stringValue(forKey: "EnableActions")?
                        .lowercased() == "true"
                    let threadSummaryInjectionForTurn = threadMemory.injectionPrefix()
                    // Research turns route through PaceLocalCLIPlannerClient
                    // (claude/codex CLI). The CLI has its own web tools
                    // and doesn't need Pace's local action-tag dialect —
                    // shipping the agent-mode tool docs would just
                    // confuse the headless CLI into returning Pace
                    // action JSON instead of a spoken research answer.
                    let systemPromptForTurn: String
                    if isResearchTurn {
                        systemPromptForTurn = CompanionSystemPrompt.buildForResearchTurn(
                            threadSummaryInjection: threadSummaryInjectionForTurn
                        )
                    } else {
                        systemPromptForTurn = CompanionSystemPrompt.build(
                            includeAgentMode: isAgentModeEnabled,
                            isTuitionModeEnabled: isTuitionModeEnabled,
                            threadSummaryInjection: threadSummaryInjectionForTurn
                        )
                    }
                    // Mark this turn as off-device for the amber-tint
                    // capsule when the active planner is anything other
                    // than the on-device tiers (DirectAPI, alwaysBridge).
                    // `plannerClientForThisTurn` covers both the normal
                    // configured planner and the per-turn research
                    // override that may have swapped in Cloud Bridge or
                    // Direct API just for this turn.
                    if plannerClientForThisTurn is DirectAPIPlannerClient
                        || plannerClientForThisTurn is CloudBridgePlannerClient {
                        isOffDeviceTurnInFlight = true
                    }

                    // Wave 4 speculative race (FIRST STEP ONLY): when the
                    // gate passes, the in-process Apple FM "lite" planner
                    // (transcript only, NO VLM) runs CONCURRENTLY with the
                    // full VLM-fed planner. Lite produces audio in ~150ms
                    // while a cold VLM (2–3s) is still running; the full
                    // path supersedes within 500ms if it catches up. The
                    // full planner's COMPLETE text always drives action
                    // parsing below — the lite path is spoken-feedback
                    // only and can never emit a real action. When the gate
                    // is false the single-planner else-branch is
                    // byte-identical to pre-race behavior.
                    let appleFoundationModelsIsAvailableForRace =
                        textOnlyPlannerClient is AppleFoundationModelsPlannerClient
                    // Thermal gate: under `.fair` pressure or worse the
                    // race's "extra planner call for ~150 ms TTFSW"
                    // trade stops paying off — the OS will throttle us
                    // externally anyway, and the second call mostly
                    // burns battery + adds fan noise.
                    let thermalAllowsSpeculativeRace = PaceThermalStateAdvisor.shouldRunSpeculativeRace(
                        underRecommendation: thermalStateAdvisor.currentRecommendation
                    )
                    let useSpeculativeRace = isFirstStep
                        && thermalAllowsSpeculativeRace
                        && speculativeRaceShouldFire(
                            intent: intentPrediction.intent,
                            appleFoundationModelsIsAvailable: appleFoundationModelsIsAvailableForRace
                        )

                    // Latency + planner-input capture for the Settings → Debug
                    // trace. plannerSectionStartedAt is measured AFTER screen
                    // capture, so it covers VLM+OCR+planner (single path) or
                    // the race. userPromptForPlannerForDebug records the exact
                    // variable half of the planner input so a failing turn can
                    // be reproduced offline (system prompt is static in source).
                    let plannerSectionStartedAt = Date()
                    var userPromptForPlannerForDebug = ""
                    let fullResponseText: String
                    var raceLiteWonSpokenText: String? = nil
                    if useSpeculativeRace {
                        userPromptForPlannerForDebug = "(speculative race — full-path prompt assembled inside the race; lite path is transcript-only)"
                        let raceWiringResult = await performFirstStepSpeculativePlannerRace(
                            transcript: currentTurnUserPrompt,
                            systemPrompt: systemPromptForTurn,
                            intent: intentPrediction.intent,
                            route: intentPrediction.route,
                            screenCaptures: screenCaptures,
                            prewarmedContext: prewarmedContextForStep
                        )
                        guard !Task.isCancelled else { return }
                        if raceWiringResult.bothPlannersFailed {
                            isCloudBridgeCallActive = false
                            isOffDeviceTurnInFlight = false
                            currentTurnHUDState = .failed("planner offline")
                            speakPlainLanguageFailure(.plannerOffline, context: "speculative-race")
                            break agentStepLoop
                        }
                        fullResponseText = raceWiringResult.fullResponseTextForActionParsing
                        raceLiteWonSpokenText = raceWiringResult.liteWonSpokenText
                    } else {
                        // ---- Single-planner path (byte-identical to pre-race) ----
                        // 2. Build image labels with the actual screenshot pixel
                        //    dimensions so the planner's coordinate space matches
                        //    the image it sees.
                        let labeledImages = screenCaptures.map { capture in
                            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                            return (data: capture.imageData, label: capture.label + dimensionInfo)
                        }

                        // 3. Optionally enrich the user prompt with the local VLM's
                        //    structured element map — cuts perception cost on the
                        //    planner side and is essential when the planner is text-only.
                        let screenContextStartedAt = Date()
                        let screenContextPrompt = await screenContextService.buildUserPromptWithLocalVLMContextIfEnabled(
                            transcript: currentTurnUserPrompt,
                            screenCaptures: screenCaptures,
                            prewarmedContext: prewarmedContextForStep
                        )
                        let userPromptForPlanner = await appendLocalRetrievalContext(
                            to: appendConfiguredMCPContext(to: screenContextPrompt),
                            query: transcript,
                            route: intentPrediction.route,
                            isFirstPlannerStep: isFirstStep
                        )
                        userPromptForPlannerForDebug = userPromptForPlanner
                        let screenContextElapsedMs = Int(
                            Date().timeIntervalSince(screenContextStartedAt) * 1000
                        )
                        print("⏱  Step \(stepIndex) screen context (VLM + OCR + AX): \(screenContextElapsedMs)ms")

                        // Diagnostic: print the first 5 element lines we're
                        // about to send to the planner.
                        logFirstElementsOfPromptForDiagnostics(
                            userPromptForPlanner: userPromptForPlanner,
                            stepIndex: stepIndex
                        )

                        // 4. Build conversation history (already includes prior steps)
                        let historyForPlanner = conversationHistory.map { entry in
                            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                        }

                        // 5. Run the planner. Text-only planners get an empty
                        //    images list; the VLM element-map text inside
                        //    userPromptForPlanner is their only view of the screen.
                        //    `plannerClientForThisTurn` is the per-turn planner
                        //    override (research tier swap) when set, else the
                        //    standard `plannerClient` Pace was constructed with.
                        let imagesForPlanner: [(data: Data, label: String)] =
                            plannerClientForThisTurn.supportsImageInput ? labeledImages : []

                        let (singlePlannerResponseText, _) = try await plannerClientForThisTurn.generateResponseStreaming(
                            images: imagesForPlanner,
                            systemPrompt: systemPromptForTurn,
                            conversationHistory: historyForPlanner,
                            userPrompt: userPromptForPlanner,
                            onTextChunk: { [weak self] accumulatedPlannerText in
                                // 1. Mirror raw text into the bubble so the user
                                //    sees tags, thinking blocks, everything live.
                                //    The end-of-turn step replaces this with the
                                //    cleaned spoken text once parsing completes.
                                //    EXCEPT a structured (v10 JSON) stream —
                                //    show a thinking ellipsis, not raw JSON.
                                self?.responseOverlayManager.updateStreamingText(
                                    Self.streamedPlannerTextIsStructuredEnvelope(accumulatedPlannerText)
                                        ? "…" : accumulatedPlannerText
                                )
                                // 2. Hand the chunk to the streaming TTS so any
                                //    newly-completed sentences get spoken before
                                //    the planner has finished generating the rest.
                                //    This is the dominant perceived-latency win.
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    let shouldSuppressStreamingNarration = Self.streamedPlannerTextIsStructuredEnvelope(accumulatedPlannerText)
                                        || (self.actionExecutor.actionsAreEnabled
                                            && PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                                                forPlannerResponseText: accumulatedPlannerText
                                            ))
                                    guard !shouldSuppressStreamingNarration else { return }
                                    await self.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedPlannerText)
                                }
                                if let streamingMailDraftSnapshot = streamingMailDraftDetector
                                    .detectChange(in: accumulatedPlannerText) {
                                    Task { @MainActor [weak self] in
                                        guard let self,
                                              self.actionExecutor.actionsAreEnabled,
                                              !self.requiresActionApproval else {
                                            return
                                        }
                                        _ = await self.actionExecutor.beginOrUpdateStreamingMailDraft(
                                            streamingMailDraftSnapshot
                                        )
                                    }
                                }
                            }
                        )
                        fullResponseText = singlePlannerResponseText
                    }
                    let plannerSectionElapsedMs = Int(
                        Date().timeIntervalSince(plannerSectionStartedAt) * 1000
                    )
                    guard !Task.isCancelled else { return }

                    // Clear the amber bridge indicator now that the stream has finished.
                    // Do this regardless of whether it was a bridge call or a local call —
                    // clearing when already false is a safe no-op. The
                    // unified off-device flag follows the same lifecycle
                    // so Direct-API turns un-tint the capsule too.
                    isCloudBridgeCallActive = false
                    isOffDeviceTurnInFlight = false

                    // 6. Parse: action tags → [DONE] flag → pointing tag.
                    //    Each pass strips its own tag class so the final
                    //    `spokenText` is clean enough to play via TTS.
                    let rawActionParseResult = PaceActionTagParser.parseActions(from: fullResponseText)
                    // Tuition-mode draw_annotation / clear_annotations
                    // are handled here, before the executor sees the
                    // plan: they're overlay-only side effects with no
                    // place in the action-dispatch switch. Same shape
                    // as the streaming-mail-draft detector below.
                    let annotationDrainOutcome = PaceAnnotationActionDrainer.drain(
                        parseResult: rawActionParseResult,
                        into: annotationOverlayController,
                        screenCaptures: screenCaptures
                    )
                    let actionParseResult = annotationDrainOutcome.drainedParseResult
                    let streamedMailDraftForFinalization = PaceStreamingMailDraftDetector
                        .firstMailDraft(in: actionParseResult.executionPlan)
                    if actionExecutor.hasActiveStreamingMailDraft,
                       streamedMailDraftForFinalization == nil {
                        actionExecutor.cancelActiveStreamingMailDraftTracking()
                    }
                    let (plannerSignaledDone, textAfterDoneStrip) =
                        PaceTagParsers.parseAndStripDoneSignal(from: actionParseResult.spokenText)
                    let pointingParseResultRaw = PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip)

                    // When the planner emitted action tags but no explicit
                    // [POINT:...], use the first click coordinate as the
                    // cursor-flight target so the buddy lands where it's
                    // about to click.
                    let parseResult: PointingParseResult = {
                        if pointingParseResultRaw.coordinate != nil {
                            return pointingParseResultRaw
                        }
                        if let firstClickLocation = actionParseResult.firstClickVisualisationLocation {
                            return PointingParseResult(
                                spokenText: pointingParseResultRaw.spokenText,
                                coordinate: CGPoint(
                                    x: firstClickLocation.xInScreenshotPixels,
                                    y: firstClickLocation.yInScreenshotPixels
                                ),
                                elementLabel: "action target",
                                screenNumber: firstClickLocation.screenNumber
                            )
                        }
                        return pointingParseResultRaw
                    }()
                    // When the speculative race's LITE path won the audio,
                    // the user already heard the lite answer — so the
                    // spoken/displayed/journaled string is the lite text,
                    // NOT the full planner's text (which only drives the
                    // action parse above). This keeps audio, bubble,
                    // reply-replay, and thread memory consistent with what
                    // was actually spoken, and prevents `flushFinal` from
                    // diffing a different string against the already-spoken
                    // lite prefix. nil in every non-race / full-won case.
                    let spokenText = raceLiteWonSpokenText ?? parseResult.spokenText
                    let plannerProvidedFinalFeedback = actionParseResult.actions.isEmpty
                        && !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if plannerProvidedFinalFeedback {
                        pendingPostActionFeedbackText = nil
                    }
                    // Replace the raw-with-tags streaming view with the
                    // cleaned spoken text now that tags are stripped.
                    responseOverlayManager.updateStreamingText(
                        spokenText.isEmpty ? "…" : spokenText
                    )
                    // Note the spoken text so the notch panel can show
                    // the reply-replay button for the next 30 seconds.
                    // Uses the SAME post-processed string that flows
                    // through TTS (think blocks + action tags already
                    // stripped) — see PRD trust-and-failures.
                    noteLastSpokenReply(spokenText)
                    // Sidecar TTS health check: if Kokoro has been
                    // failing this turn, surface the "switched to
                    // system voice" plain-language failure once per
                    // outage window.
                    if let localServerTTSClient = ttsClient as? LocalServerTTSClient {
                        speakSidecarTTSFallbackMemoIfNeeded(
                            isSidecarUnreachable: localServerTTSClient.hasObservedSidecarOutage
                        )
                    }

                    // 7. Move the cursor to the pointing/click target so the
                    //    flight animation is in flight before the click fires.
                    let hasPointCoordinate = parseResult.coordinate != nil
                    if hasPointCoordinate {
                        voiceState = .idle
                    }

                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = parseResult.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()

                    if let pointCoordinate = parseResult.coordinate,
                       let targetScreenCapture {
                        // Same screenshot-pixel → AppKit-global helper
                        // used by the annotation drainer, so the cursor
                        // path and the tuition-mode draw layer can't
                        // drift apart.
                        let globalLocation = PaceAnnotationCoordinateMapper
                            .convertScreenshotPixelToAppKitGlobal(
                                screenshotPixelPoint: pointCoordinate,
                                on: targetScreenCapture
                            )

                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = targetScreenCapture.displayFrame
                        PaceAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                        print("🎯 Step \(stepIndex) pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    } else {
                        print("🎯 Step \(stepIndex) pointing: \(parseResult.elementLabel ?? "no element")")
                    }

                    // 8. Save this step to conversation history. First step
                    //    gets the real transcript; later steps record the
                    //    continuation placeholder so the planner sees its
                    //    own previous narration via assistant turns.
                    recordConversationTurn(
                        userTranscript: isFirstStep ? transcript : "(agent step \(stepIndex))",
                        assistantResponse: spokenText
                    )
                    print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                    PaceAnalytics.trackAIResponseReceived(response: spokenText)

                    // 9. The bulk of the spoken response has been queued
                    //    sentence-by-sentence inside the onTextChunk
                    //    callback above as the planner was generating.
                    //    Here we just speak whatever tail remains past
                    //    the last sentence boundary the streamer found,
                    //    using the fully-cleaned spokenText as the
                    //    source of truth (the streamer used a coarser
                    //    in-flight strip).
                    let shouldSpeakInitialPlannerText = !actionExecutor.actionsAreEnabled
                        || !PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                            for: actionParseResult.executionPlan
                        )
                    if shouldSpeakInitialPlannerText,
                       !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
                        voiceState = .responding
                    }

                    // 10. Execute tool calls/action tags if any.
                    var toolObservations: [PaceActionExecutionObservation] = []
                    var userDeniedActionApproval = false
                    if !actionParseResult.actions.isEmpty {
                        let preflightIssues = PaceToolPreflight.evaluate(
                            actionExecutionPlan: actionParseResult.executionPlan,
                            environment: currentToolPreflightEnvironment()
                        )
                        appendActionResult(.planned(
                            actionExecutionPlan: actionParseResult.executionPlan,
                            preflightIssues: preflightIssues
                        ))

                        // Visual-target ambiguity: if the executor's click
                        // candidates have near-tied, distinguishable labels,
                        // ask ONE short HUD question instead of guessing the
                        // top one. Pauses this turn — resolving an option in
                        // the panel executes the chosen candidate directly
                        // (resolveClickTargetClarification), so we break out
                        // of the agent loop here. See PRD
                        // docs/prds/hud-intent-disambiguator.md.
                        if actionExecutor.actionsAreEnabled,
                           raiseClickTargetClarificationIfAmbiguous(
                               actionExecutionPlan: actionParseResult.executionPlan,
                               screenCaptures: screenCaptures
                           ) {
                            break agentStepLoop
                        }

                        if actionExecutor.actionsAreEnabled {
                            if requestUserApprovalForActionPlan(
                                actionParseResult.executionPlan,
                                preflightIssues: preflightIssues
                            ) {
                                // Brief settle so the cursor flight visibly arrives
                                // before the synthetic click fires.
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled else { return }
                                if actionExecutor.hasActiveStreamingMailDraft,
                                   let finalMailDraft = streamedMailDraftForFinalization {
                                    if let streamingMailObservation = await actionExecutor
                                        .finishActiveStreamingMailDraft(finalMailDraft: finalMailDraft) {
                                        toolObservations.append(streamingMailObservation)
                                    }

                                    let remainingActionPlan = actionParseResult
                                        .executionPlan
                                        .removingFirstMailDraftAction()
                                    toolObservations += await actionExecutor.executeActionPlan(
                                        remainingActionPlan,
                                        screenCaptures: screenCaptures
                                    )
                                } else {
                                    toolObservations = await actionExecutor.executeActionPlan(
                                        actionParseResult.executionPlan,
                                        screenCaptures: screenCaptures
                                    )
                                }
                                // Set-of-Mark recovery: if any click missed,
                                // re-mark the screenshot and let the VLM re-pick
                                // before reporting failure. PRD set-of-mark-click-recovery.
                                toolObservations = await attemptSetOfMarkClickRecovery(
                                    observations: toolObservations,
                                    screenCaptures: screenCaptures
                                )
                                if !toolObservations.isEmpty {
                                    print("🧰 Tool observations:\n\(PaceActionExecutionObservation.formatForPlanner(toolObservations))")
                                    appendActionResult(.completed(observations: toolObservations))
                                    pendingPostActionFeedbackText = PaceActionExecutionObservation
                                        .formatForUserFeedback(toolObservations)
                                    // After every reversible mutation, raise the
                                    // visible undo banner (PRD trust-and-failures).
                                    noteReversibleActionExecuted(
                                        in: actionParseResult.executionPlan
                                    )
                                    // After click-all-fail observations, speak
                                    // the plain-language failure once.
                                    speakFailureForClickMissedIfApplicable(
                                        observations: toolObservations,
                                        clickTargetLabel: Self.firstClickCandidateLabel(
                                            in: actionParseResult.executionPlan
                                        )
                                    )
                                }
                            } else {
                                userDeniedActionApproval = true
                                appendActionResult(PaceActionRunRecord(
                                    status: .denied,
                                    title: "Action denied",
                                    detail: actionParseResult.executionPlan.approvalSummary
                                ))
                                print("🛑 Pace action approval denied — stopping agent loop")
                            }
                        } else {
                            appendActionResult(PaceActionRunRecord(
                                status: .skipped,
                                title: "Actions disabled",
                                detail: "Parsed \(actionParseResult.actions.count) action(s), but EnableActions is false."
                            ))
                            print("🤖 \(actionParseResult.actions.count) action(s) parsed but EnableActions is false — exiting loop after this step")
                        }

                        // Narrate any blocking preflight issue regardless of
                        // approval popup — when the auto-execute path is
                        // silently blocked (no popup, no actions ran), this
                        // keeps the failure audible.
                        speakFailureForBlockingPreflightIfApplicable(
                            preflightIssues: preflightIssues
                        )
                    }

                    // Settings → Debug capture: record this planner step's
                    // raw output, parsed tool calls, and dispatch outcome.
                    // Pure observability sink — never affects the loop.
                    let dispatchSummaryForDebug: String = {
                        if actionParseResult.actions.isEmpty {
                            return "no actions parsed — spoken-only turn"
                        }
                        if userDeniedActionApproval {
                            return "denied by user"
                        }
                        if !actionExecutor.actionsAreEnabled {
                            return "EnableActions=false — not executed"
                        }
                        if toolObservations.isEmpty {
                            return "executed — no observations returned"
                        }
                        return PaceActionExecutionObservation.formatForPlanner(toolObservations)
                    }()
                    recordToolCallDebug(PaceToolCallDebugRecord(
                        transcript: isFirstStep ? transcript : "(agent step \(stepIndex))",
                        lane: .planner,
                        routingDetail: "\(intentPrediction.intent.rawValue) · conf \(String(format: "%.2f", intentPrediction.confidence)) · \(intentPrediction.route.rawValue)",
                        plannerPathDetail: useSpeculativeRace
                            ? (raceLiteWonSpokenText != nil
                                ? "speculative race · lite (Apple FM, no screen) won audio"
                                : "speculative race · full planner won")
                            : "single planner",
                        userHeardScreenlessAnswer: raceLiteWonSpokenText,
                        screenElementCount: lastPlannerElementLineCountForDebug,
                        rawPlannerOutput: fullResponseText,
                        spokenText: spokenText,
                        parsedActionsSummary: Self.toolCallDebugSummary(
                            for: actionParseResult.executionPlan
                        ),
                        dispatchSummary: dispatchSummaryForDebug,
                        plannerLatencyMs: plannerSectionElapsedMs,
                        totalTurnLatencyMs: Int(
                            Date().timeIntervalSince(turnStartedAt) * 1000
                        ),
                        userPrompt: userPromptForPlannerForDebug
                    ))

                    // 11. Exit conditions for the agent loop:
                    //     - planner emitted [DONE]
                    //     - planner emitted no action tags (pure answer turn)
                    //     - actions are disabled (treat every turn as single-shot)
                    // Structured-output turns are SINGLE-SHOT: the v10 JSON
                    // envelope can't carry a [DONE] tag and always contains an
                    // action, so re-looping makes the constrained planner
                    // invent spurious follow-ups (it dictated the user's own
                    // command on an 8-step runaway). Multi-action sequences
                    // ride in one envelope via payload.calls instead.
                    // Token-budget backstop for research turns. Coarse
                    // chars→tokens estimate (chars / 4) is precise
                    // enough for a "your bill is about to balloon"
                    // ceiling. Skipped when no research configuration
                    // is in play.
                    if let researchConfiguration = capturedResearchConfiguration {
                        cumulativeOutputTokenEstimate += fullResponseText.count / 4
                        if cumulativeOutputTokenEstimate >= researchConfiguration.perTurnTokenBudgetCap {
                            print("⛔ Research turn hit token budget cap (~\(cumulativeOutputTokenEstimate) tokens / ceiling \(researchConfiguration.perTurnTokenBudgetCap)) — bailing")
                            await MainActor.run {
                                self.currentTurnHUDState = .done("hit token budget")
                            }
                            break agentStepLoop
                        }
                    }
                    let exitLoop = plannerSignaledDone
                        || actionParseResult.actions.isEmpty
                        || !actionExecutor.actionsAreEnabled
                        || userDeniedActionApproval
                        || plannerClientForThisTurn.usesStructuredActionOutput
                    if exitLoop {
                        if plannerSignaledDone {
                            print("✅ Agent loop: planner signaled [DONE] at step \(stepIndex)")
                        } else if plannerClientForThisTurn.usesStructuredActionOutput {
                            print("✅ Agent loop: structured-output turn is single-shot — stopping after step \(stepIndex)")
                        }
                        break agentStepLoop
                    }

                    // 12. Brief wait so the action's effect lands in the UI
                    //     before we capture the next screenshot. Without this
                    //     the new screen capture may still show pre-click state.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }

                    // Set up the next iteration.
                    let toolObservationPromptText = PaceActionExecutionObservation.formatForPlanner(toolObservations)
                    if toolObservationPromptText.isEmpty {
                        currentTurnUserPrompt = "continue the task. look at the current screen, then either emit the next step's action tags or emit [DONE] if the task is complete."
                    } else {
                        currentTurnUserPrompt = """
                        tool results:
                        \(toolObservationPromptText)

                        continue the task. use the tool results and current screen, then either emit the next step's tool calls/action tags or emit [DONE] if the task is complete.
                        """
                    }
                    voiceState = .processing
                }

                if stepIndex >= maxAgentStepCount {
                    print("⚠️ Agent loop: hit max steps (\(maxAgentStepCount)) without [DONE] — stopping")
                }

                if let pendingPostActionFeedbackText,
                   !pendingPostActionFeedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Task.isCancelled {
                    responseOverlayManager.updateStreamingText(pendingPostActionFeedbackText)
                    await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: pendingPostActionFeedbackText)
                    voiceState = .responding
                }
                if currentTurnHUDState.status == .understanding
                    || currentTurnHUDState.status == .acting {
                    currentTurnHUDState = .done("turn finished")
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted. Hide the
                // overlay immediately so it doesn't linger over the next
                // turn's "listening…" state.
                isCloudBridgeCallActive = false
                isOffDeviceTurnInFlight = false
                responseOverlayManager.hideOverlay()
            } catch {
                PaceAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                isCloudBridgeCallActive = false
                isOffDeviceTurnInFlight = false
                responseOverlayManager.updateStreamingText("error: \(error.localizedDescription)")
                responseOverlayManager.finishStreaming()
                currentTurnHUDState = .failed(error.localizedDescription)
                speakCreditsErrorFallback()
                // Plain-language failure narration — see PRD
                // docs/prds/trust-and-failures.md. The cloud bridge
                // gets its own kind so the user knows which CLI to
                // inspect; everything else maps onto plannerOffline.
                if plannerClient is CloudBridgePlannerClient {
                    speakPlainLanguageFailure(
                        .cloudBridgeUpstreamError(
                            provider: cloudBridgeUpstream.displayLabel
                        ),
                        context: "planner-catch"
                    )
                } else {
                    speakPlainLanguageFailure(.plannerOffline, context: "planner-catch")
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
                // Keep the bubble up while TTS is still speaking so the
                // user can read along, then fade ~800ms after audio ends.
                let weakTTSClient = ttsClient
                responseOverlayManager.finishStreaming(keepVisibleUntil: { @MainActor in
                    weakTTSClient.isPlaying
                })
                // Restore the walking avatar (if user has it enabled)
                // and reset the trigger so the next turn defaults to
                // keyboard until something says otherwise.
                if isWalkingAvatarEnabled {
                    avatarOverlayManager?.show()
                }
                currentDictationTrigger = .keyboard
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Result of wiring ONE first agent step through the speculative
    /// planner race. `fullResponseTextForActionParsing` is ALWAYS the
    /// full planner's text when it succeeded (so actions parse from the
    /// accurate, VLM-fed planner no matter who won the audio); it falls
    /// back to the lite text only when the full path threw.
    /// `liteWonSpokenText` is non-nil ONLY when the lite path won the
    /// audio outright — it is the cleaned string the user actually heard,
    /// which the caller uses as the spoken/displayed/journaled text.
    /// `bothPlannersFailed` routes the caller to the failure narrator.
    struct PaceFirstStepRaceWiringResult {
        let fullResponseTextForActionParsing: String
        let liteWonSpokenText: String?
        let bothPlannersFailed: Bool
    }

    /// Wave 4: wire the first agent step through `PaceSpeculativePlanner
    /// Race`. The lite path (in-process Apple FM, transcript only, no VLM)
    /// races the full VLM-fed planner; the winner's tokens stream to TTS +
    /// the bubble as they arrive, while the full path's COMPLETE text
    /// always comes back for action parsing. Only invoked when
    /// `speculativeRaceShouldFire` is true for a FIRST step — multi-step
    /// agent turns keep the single-planner path.
    func performFirstStepSpeculativePlannerRace(
        transcript: String,
        systemPrompt: String,
        intent: PaceIntent,
        route: PaceIntentRoute,
        screenCaptures: [CompanionScreenCapture],
        prewarmedContext: PaceScreenContextPrewarmedSnapshot?
    ) async -> PaceFirstStepRaceWiringResult {
        let fullClient = plannerClient
        let liteClient = textOnlyPlannerClient

        // The full path's expensive input prep (VLM + OCR + AX + retrieval)
        // is deferred into this builder so it runs CONCURRENTLY with the
        // lite path instead of blocking it — that overlap is the whole
        // cold-path speed win. Assembly is identical to the single-planner
        // else-branch in the agent loop.
        let fullPlannerInputBuilder: @MainActor () async -> PaceChatTurnPart = { [weak self] in
            guard let self else {
                return PaceChatTurnPart(
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: transcript
                )
            }
            let labeledImages = screenCaptures.map { capture -> (data: Data, label: String) in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let screenContextStartedAt = Date()
            let screenContextPrompt = await self.screenContextService.buildUserPromptWithLocalVLMContextIfEnabled(
                transcript: transcript,
                screenCaptures: screenCaptures,
                prewarmedContext: prewarmedContext
            )
            let userPromptForPlanner = await self.appendLocalRetrievalContext(
                to: self.appendConfiguredMCPContext(to: screenContextPrompt),
                query: transcript,
                route: route,
                isFirstPlannerStep: true
            )
            print("⏱  Race full-path screen context (VLM + OCR + AX): \(Int(Date().timeIntervalSince(screenContextStartedAt) * 1000))ms")
            self.logFirstElementsOfPromptForDiagnostics(
                userPromptForPlanner: userPromptForPlanner,
                stepIndex: 1
            )
            let historyForPlanner = self.conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }
            let imagesForPlanner: [(data: Data, label: String)] =
                fullClient.supportsImageInput ? labeledImages : []
            return PaceChatTurnPart(
                images: imagesForPlanner,
                systemPrompt: systemPrompt,
                conversationHistory: historyForPlanner,
                userPrompt: userPromptForPlanner
            )
        }

        // Winner box: shared by reference between the synchronous onToken
        // callback (winner-flip detection) and the async TTS-dispatch Task
        // (stale-lite-chunk guard after a supersede).
        let winnerBox = PaceSpeculativeRaceWinnerBox()

        let raceResult = await PaceSpeculativePlannerRace.raceSpeculative(
            transcript: transcript,
            systemPrompt: systemPrompt,
            // The system prompt already carries the rolling thread-memory
            // summary via CompanionSystemPrompt.build(threadSummaryInjection:),
            // so the lite user prompt must NOT prepend it again.
            threadMemoryPrefix: "",
            intent: intent,
            liteClient: liteClient,
            fullClient: fullClient,
            fullPlannerInputBuilder: fullPlannerInputBuilder,
            spokenCharacterCountProbe: { [weak self] in
                self?.streamingSentenceTTSPipeline.firstSpokenWordCharacterCount ?? 0
            },
            onToken: { [weak self] accumulatedText, winner in
                guard let self else { return }
                // The first full token while lite has been speaking is a
                // supersede: reset the TTS pipeline so the full stream — a
                // different string than lite — replays cleanly instead of
                // being diffed against the already-spoken lite prefix.
                if winnerBox.winner == .lite, winner == .full {
                    self.streamingSentenceTTSPipeline.prepareForSupersedingStreamWithinTurn()
                }
                winnerBox.winner = winner
                self.responseOverlayManager.updateStreamingText(
                    Self.streamedPlannerTextIsStructuredEnvelope(accumulatedText)
                        ? "…" : accumulatedText
                )
                // The full (main) planner is decode-constrained to the v10
                // JSON envelope, so its stream is raw JSON — never speak it;
                // the parsed spokenText is flushed at turn end instead. The
                // lite path stays free prose and streams normally.
                let shouldSuppressStreamingNarration = Self.streamedPlannerTextIsStructuredEnvelope(accumulatedText)
                    || (self.actionExecutor.actionsAreEnabled
                        && PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                            forPlannerResponseText: accumulatedText
                        ))
                guard !shouldSuppressStreamingNarration else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // A lite chunk's dispatch Task scheduled BEFORE a
                    // supersede must not re-speak lite over the freshly
                    // reset full stream — drop it if the winner has moved on.
                    guard winner == winnerBox.winner else { return }
                    await self.streamingSentenceTTSPipeline.acceptStreamedText(accumulatedText)
                }
            },
            onCompletion: { _ in }
        )

        switch raceResult.outcome {
        case .bothFailed:
            return PaceFirstStepRaceWiringResult(
                fullResponseTextForActionParsing: "",
                liteWonSpokenText: nil,
                bothPlannersFailed: true
            )
        case .liteWon:
            // Actions (if any) still parse from the full planner's text
            // when it succeeded; the user heard the lite answer, so the
            // spoken/displayed string is the lite text cleaned the same
            // way the full path's spoken text is.
            let liteRawText = raceResult.litePlannerResponseText ?? ""
            return PaceFirstStepRaceWiringResult(
                fullResponseTextForActionParsing: raceResult.fullPlannerResponseText ?? liteRawText,
                liteWonSpokenText: Self.cleanedSpokenTextForRace(from: liteRawText),
                bothPlannersFailed: false
            )
        case .fullWon, .fullSupersededLite:
            return PaceFirstStepRaceWiringResult(
                fullResponseTextForActionParsing: raceResult.fullPlannerResponseText ?? "",
                liteWonSpokenText: nil,
                bothPlannersFailed: false
            )
        }
    }

    /// Strip tags from a planner response the same way the agent loop
    /// derives `spokenText`, so the lite-won spoken string the user hears
    /// matches the cleaning the full path gets. Pure + static — no actor
    /// hops, unit-testable in isolation.
    nonisolated private static func cleanedSpokenTextForRace(from rawText: String) -> String {
        let actionParse = PaceActionTagParser.parseActions(from: rawText)
        let (_, textAfterDoneStrip) = PaceTagParsers.parseAndStripDoneSignal(from: actionParse.spokenText)
        return PaceTagParsers.parsePointingCoordinates(from: textAfterDoneStrip).spokenText
    }

    /// Builds the prompt sent to the cloud planner. When the local VLM is
    /// enabled in Info.plist, runs the cursor screen through it first and
    /// prepends a structured element map. The cloud planner can then refer
    /// to elements by name without re-doing the perception work itself.
    /// One-line diagnostic dump of what the planner is about to see.
    /// Surfaces the FIRST 5 element lines from the prompt so a console
    /// paste makes it obvious whether the target the user named is
    /// actually in the element map — separating "model picked wrong"
    /// from "model never saw the target." Stays terse so it doesn't
    /// drown the rest of the log.
    func logFirstElementsOfPromptForDiagnostics(
        userPromptForPlanner: String,
        stepIndex: Int
    ) {
        let allElementLines = userPromptForPlanner
            .split(separator: "\n")
            .filter { $0.contains("|") && !$0.hasPrefix("===") }
        // Stash the full count for the Settings → Debug post-execution
        // capture so a "did the planner even see the screen?" question is
        // answerable per turn.
        lastPlannerElementLineCountForDebug = allElementLines.count
        let elementLines = allElementLines.prefix(5)
        guard !elementLines.isEmpty else {
            print("🔬 Step \(stepIndex) planner sees: <no element-list lines in prompt>")
            return
        }
        print("🔬 Step \(stepIndex) planner sees (top 5 of element map):")
        for line in elementLines {
            print("     \(line)")
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Pace" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isPaceCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Surfaces a planner/TTS failure silently — visible in the response
    /// overlay (already updated by the caller) and the audit log, but
    /// never spoken through NSSpeechSynthesizer. The previous Apple-voice
    /// "Something went wrong" line was rated worse than no audio.
    func speakCreditsErrorFallback() {
        currentTurnHUDState = .failed("response error")
        PaceAPIAuditLog.shared.record(
            subsystem: "pipeline",
            operation: "error",
            target: "companion-manager",
            durationMilliseconds: 0,
            outcome: "error",
            detail: "main planner/TTS path failed"
        )
    }
}
