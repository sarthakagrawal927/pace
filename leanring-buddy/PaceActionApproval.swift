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
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile, .mcp:
            return true
        case .openMessages(let messageRequest):
            return messageRequest.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
             .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll, .openApplication,
             .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes:
            return false
        }
    }

    private static func canRelyOnVisualOrObservationFeedback(_ action: PaceParsedAction) -> Bool {
        switch action {
        case .click, .doubleClick, .clickCandidates, .type, .setTextValue, .editSelectedText,
             .undoLastMutation, .pressKey, .readClipboard, .snapWindow, .scroll, .openApplication,
             .openURL, .controlMusic, .adjustVolume, .adjustBrightness,
             .listCalendarEvents, .finder, .searchNotes:
            return true
        case .openMessages(let messageRequest):
            return messageRequest.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        case .createCalendarEvent, .createReminder, .createNote, .appendNote,
             .composeMail, .createThingsToDo, .runShortcut, .downloadFile, .mcp:
            return false
        }
    }
}
