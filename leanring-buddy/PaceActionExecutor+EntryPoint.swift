//
//  PaceActionExecutor+EntryPoint.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  executeActionPlan dispatch and streaming mail draft entry points.
//

import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - High-level entry point

    // MARK: - High-level entry point

    /// Executes a serial sequence of actions parsed from legacy inline tags.
    /// Kept as a compatibility wrapper around the richer tool-plan shape.
    @discardableResult
    func executeActionSequence(
        _ actions: [PaceParsedAction],
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        await executeActionPlan(
            PaceActionExecutionPlan.serial(actions: actions),
            screenCaptures: screenCaptures
        )
    }

    /// Executes a tool plan: outer steps are sequential; actions within one
    /// step are a parallel group at the planner contract level. UI-mutating
    /// actions still run in source order because macOS focus/cursor state is
    /// global and not safe to mutate concurrently.
    @discardableResult
    func executeActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        guard !actionExecutionPlan.steps.isEmpty else { return [] }

        var observations: [PaceActionExecutionObservation] = []

        for (stepIndex, step) in actionExecutionPlan.steps.enumerated() {
            guard !step.actions.isEmpty else { continue }

            for (actionIndex, action) in step.actions.enumerated() {
                if let observation = await executeSingleAction(action, screenCaptures: screenCaptures) {
                    observations.append(observation)
                }

                let isLastActionInStep = (actionIndex == step.actions.count - 1)
                if !isLastActionInStep {
                    try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
                }
            }

            let isLastStep = (stepIndex == actionExecutionPlan.steps.count - 1)
            if !isLastStep {
                try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
            }
        }

        return observations
    }

    var hasActiveStreamingMailDraft: Bool {
        activeStreamingMailDraftState != nil
    }

    @discardableResult
    func beginOrUpdateStreamingMailDraft(
        _ snapshot: PaceStreamingMailDraftSnapshot
    ) async -> PaceActionExecutionObservation? {
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Would stream mail draft body: \(snapshot.normalizedMailDraft.subject)"
            )
        }

        let now = Date()
        if let activeStreamingMailDraftState,
           now.timeIntervalSince(activeStreamingMailDraftState.lastWriteDate) < 0.033 {
            self.activeStreamingMailDraftState = activeStreamingMailDraftState
                .withPendingSnapshot(snapshot)
            return nil
        }

        return await writeStreamingMailDraft(snapshot, isFinalWrite: false)
    }

    @discardableResult
    func finishActiveStreamingMailDraft(
        finalMailDraft: PaceMailDraft
    ) async -> PaceActionExecutionObservation? {
        guard activeStreamingMailDraftState != nil else {
            return nil
        }

        let finalSnapshot = PaceStreamingMailDraftSnapshot(
            recipients: finalMailDraft.recipients,
            subject: finalMailDraft.subject,
            body: finalMailDraft.body
        )
        let observation = await writeStreamingMailDraft(finalSnapshot, isFinalWrite: true)
        activeStreamingMailDraftState = nil

        return observation ?? PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created streaming mail draft: \(finalMailDraft.subject)"
        )
    }

    func cancelActiveStreamingMailDraftTracking() {
        activeStreamingMailDraftState = nil
    }

    func executeSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        let observation = await dispatchSingleAction(action, screenCaptures: screenCaptures)
        let outcomeText: String
        if let observation, observation.summary.lowercased().contains("fail")
            || observation.summary.lowercased().contains("error")
            || observation.summary.lowercased().contains("could not") {
            outcomeText = "error"
        } else {
            outcomeText = "ok"
        }
        PaceAPIAuditLog.shared.record(
            subsystem: "action",
            operation: action.auditOperationName,
            target: action.auditTarget,
            durationMilliseconds: 0,
            outcome: outcomeText,
            outputCharacterCount: observation?.summary.count,
            detail: observation?.summary.prefix(160).description
        )
        return observation
    }

    func dispatchSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        switch action {
        case .click(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 1)
        case .doubleClick(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 2)
        case .clickCandidates(let clickCandidateSet):
            return await clickBestCandidate(clickCandidateSet, screenCaptures: screenCaptures)
        case .type(let textToType):
            await typeText(textToType)
        case .setTextValue(let setTextValueRequest):
            return setTextValue(setTextValueRequest)
        case .editSelectedText(let voiceEditRequest):
            return editSelectedText(voiceEditRequest)
        case .undoLastMutation:
            return undoLastMutation()
        case .pressKey(let keyName, let modifiers):
            await pressKey(named: keyName, withModifiers: modifiers)
        case .readClipboard:
            return readClipboardText()
        case .snapWindow(let snapWindowRequest):
            return snapFocusedWindow(snapWindowRequest)
        case .scroll(let direction, let amount):
            await scroll(direction: direction, amountInLines: amount)
        case .openApplication(let applicationName):
            return await openApplication(named: applicationName)
        case .openURL(let urlString):
            return await openURL(urlString)
        case .controlMusic(let musicCommand):
            return await controlMusic(musicCommand)
        case .adjustVolume(let adjustment):
            await adjustVolume(adjustment)
        case .adjustBrightness(let adjustment):
            await adjustBrightness(adjustment)
        case .listCalendarEvents(let calendarQuery):
            return await listCalendarEvents(calendarQuery)
        case .createCalendarEvent(let calendarEventRequest):
            return await createCalendarEvent(calendarEventRequest)
        case .createReminder(let reminderRequest):
            return await createReminder(reminderRequest)
        case .finder(let finderRequest):
            return await performFinderRequest(finderRequest)
        case .createNote(let noteRequest):
            return await createNote(noteRequest)
        case .appendNote(let noteRequest):
            return await appendNote(noteRequest)
        case .searchNotes(let query):
            return await searchNotes(query: query)
        case .composeMail(let mailDraft):
            return await composeMail(mailDraft)
        case .createThingsToDo(let thingsToDoRequest):
            return await createThingsToDo(thingsToDoRequest)
        case .runShortcut(let shortcutName):
            return await runShortcut(named: shortcutName)
        case .openMessages(let messageRequest):
            return await openMessages(messageRequest)
        case .downloadFile(let downloadRequest):
            return await downloadFile(downloadRequest)
        case .startTimer(let timerRequest):
            return await startTimer(timerRequest)
        case .recordFlow(let flowRequest):
            return recordFlow(flowRequest)
        case .runFlow(let flowRequest):
            return runFlow(flowRequest)
        case .mcp(let mcpToolCall):
            return await callMCPTool(mcpToolCall)
        case .drawAnnotation, .clearAnnotations:
            // Tuition-mode annotation actions are drained out of the
            // plan by `PaceAnnotationActionDrainer` in CompanionManager
            // before it ever reaches the executor. If one slips through
            // (e.g. a future direct caller), no-op silently rather than
            // running an irrelevant local action.
            return nil
        }

        return nil
    }
}
