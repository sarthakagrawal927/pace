//
//  PaceActionApproval.swift
//  leanring-buddy
//
//  Pure approval-gate helpers. CompanionManager owns the actual NSAlert UI;
//  this file keeps the allow/cancel contract testable without controlling the
//  user's Mac during unit tests.
//

import Foundation

nonisolated enum PaceActionApprovalDecision: Equatable {
    case allowOnce
    case cancel
}

nonisolated struct PaceActionApprovalRequest: Equatable {
    let approvalSummary: String
    let preflightSummary: String?

    init?(
        approvalSummary: String,
        preflightSummary: String? = nil,
        requiresActionApproval: Bool
    ) {
        let trimmedApprovalSummary = approvalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requiresActionApproval, !trimmedApprovalSummary.isEmpty else {
            return nil
        }
        self.approvalSummary = trimmedApprovalSummary
        let trimmedPreflightSummary = preflightSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preflightSummary = trimmedPreflightSummary?.isEmpty == false ? trimmedPreflightSummary : nil
    }

    var messageText: String {
        "Approve Pace actions?"
    }

    var informativeText: String {
        """
        Pace wants to control your Mac:

        \(approvalSummary)
        \(preflightSummary.map { "\n\n\($0)" } ?? "")

        Only approve this if it matches what you asked for.
        """
    }
}

nonisolated enum PaceActionApprovalPolicy {
    static func requiresExplicitApproval(
        for actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue] = []
    ) -> Bool {
        if preflightIssues.contains(where: { $0.severity == .blocking }) {
            return true
        }

        return actionExecutionPlan.flattenedActions.contains(where: requiresExplicitApproval)
    }

    static func shouldExecuteActions(
        request: PaceActionApprovalRequest?,
        decision: PaceActionApprovalDecision
    ) -> Bool {
        guard request != nil else {
            return true
        }
        return decision == .allowOnce
    }

    static func suppressesInitialSpokenFeedback(
        for actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue] = []
    ) -> Bool {
        let flattenedActions = actionExecutionPlan.flattenedActions
        guard !flattenedActions.isEmpty else { return false }
        guard !requiresExplicitApproval(
            for: actionExecutionPlan,
            preflightIssues: preflightIssues
        ) else {
            return false
        }

        return flattenedActions.allSatisfy(canRelyOnVisualOrObservationFeedback)
    }

    static func suppressesInitialSpokenFeedback(
        forPlannerResponseText plannerResponseText: String,
        preflightIssues: [PaceToolPreflightIssue] = []
    ) -> Bool {
        let parsedActions = PaceActionTagParser.parseActions(from: plannerResponseText)
        guard !parsedActions.executionPlan.flattenedActions.isEmpty else {
            return false
        }
        return suppressesInitialSpokenFeedback(
            for: parsedActions.executionPlan,
            preflightIssues: preflightIssues
        )
    }

    private static func requiresExplicitApproval(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile,
             .recordFlow, .runFlow, .mcp:
            return true
        case .openMessages(let messageRequest):
            return messageRequest.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
             .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll, .openApplication,
             .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes, .startTimer,
             .drawAnnotation, .clearAnnotations:
            return false
        }
    }

    /// Whether the parsed action is in the reversible-mutation set —
    /// i.e., the same set for which `canRelyOnVisualOrObservationFeedback`
    /// returns false. These actions get an undo banner because they
    /// produce a visible artifact the user can undo via `Undo.last` or
    /// app-specific delete. Irreversible inputs like `click` / `type`
    /// don't appear here because there's nothing to undo.
    ///
    /// Kept separate from `canRelyOnVisualOrObservationFeedback` so the
    /// reversibility list can evolve independently of the
    /// initial-spoken-feedback suppression policy.
    static func actionIsReversibleMutation(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile,
             .recordFlow, .runFlow, .mcp, .setTextValue, .editSelectedText:
            return true
        case .openMessages(let messageRequest):
            // Messages with body text creates a visible Messages draft;
            // opening Messages without body text doesn't.
            return messageRequest.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        case .click, .doubleClick, .clickCandidates, .type,
             .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll,
             .openApplication, .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes, .startTimer,
             .drawAnnotation, .clearAnnotations:
            return false
        }
    }

    /// Whether the supplied plan contains at least one reversible
    /// mutation. Used by `CompanionManager` to decide if the undo
    /// banner should appear after the executor finishes.
    static func planContainsReversibleMutation(
        _ actionExecutionPlan: PaceActionExecutionPlan
    ) -> Bool {
        actionExecutionPlan.flattenedActions.contains(where: actionIsReversibleMutation)
    }

    /// Short user-friendly summary of the first reversible mutation in
    /// the plan, used as the undo-banner label. Returns nil when no
    /// reversible action is present.
    static func firstReversibleSummary(
        _ actionExecutionPlan: PaceActionExecutionPlan
    ) -> String? {
        for action in actionExecutionPlan.flattenedActions {
            if actionIsReversibleMutation(action) {
                return reversibleSummary(for: action)
            }
        }
        return nil
    }

    private static func reversibleSummary(for action: PaceParsedAction) -> String {
        switch action {
        case .createNote: return "Created note"
        case .appendNote: return "Appended to note"
        case .createReminder: return "Created reminder"
        case .createCalendarEvent: return "Created calendar event"
        case .composeMail: return "Started mail draft"
        case .createThingsToDo: return "Created Things to-do"
        case .runShortcut: return "Ran shortcut"
        case .downloadFile: return "Downloaded file"
        case .recordFlow: return "Recorded flow"
        case .runFlow: return "Ran flow"
        case .setTextValue, .editSelectedText: return "Edited text"
        case .openMessages: return "Started message draft"
        case .mcp: return "Ran external tool"
        default: return "Last action"
        }
    }

    private static func canRelyOnVisualOrObservationFeedback(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
             .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll, .openApplication,
             .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes, .startTimer,
             .clearAnnotations:
            // clearAnnotations: pure overlay cleanup, no speech needed.
            return true
        case .openMessages(let messageRequest):
            return messageRequest.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile,
             .recordFlow, .runFlow, .mcp,
             .drawAnnotation:
            // drawAnnotation: the spoken narration IS the teaching
            // value — the drawing alone isn't sufficient feedback. So
            // do NOT suppress initial spoken feedback for this action,
            // even though it's read-only.
            return false
        }
    }
}
