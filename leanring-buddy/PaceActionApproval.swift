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
    static func shouldExecuteActions(
        request: PaceActionApprovalRequest?,
        decision: PaceActionApprovalDecision
    ) -> Bool {
        guard request != nil else {
            return true
        }
        return decision == .allowOnce
    }
}
