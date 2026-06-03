//
//  PaceActionResultCenter.swift
//  leanring-buddy
//
//  Small, UI-friendly records for recent local tool plans and outcomes.
//  CompanionManager owns the actual list because it already coordinates
//  planning, approval, execution, and panel state.
//

import Foundation

enum PaceActionRunStatus: String, Equatable {
    case planned
    case completed
    case failed
    case denied
    case skipped

    var displayName: String {
        switch self {
        case .planned:
            return "Planned"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .denied:
            return "Denied"
        case .skipped:
            return "Skipped"
        }
    }
}

struct PaceActionRunRecord: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let status: PaceActionRunStatus
    let title: String
    let detail: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: PaceActionRunStatus,
        title: String,
        detail: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.title = title
        self.detail = detail
    }

    static func planned(
        actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue]
    ) -> PaceActionRunRecord {
        let actionCount = actionExecutionPlan.flattenedActions.count
        let toolWord = actionCount == 1 ? "tool" : "tools"
        let preflightDetail = PaceToolPreflightIssue.formatForUser(preflightIssues)
        let detail = [actionExecutionPlan.approvalSummary, preflightDetail]
            .compactMap { text in
                let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedText?.isEmpty == false ? trimmedText : nil
            }
            .joined(separator: "\n\n")

        return PaceActionRunRecord(
            status: .planned,
            title: "\(actionCount) \(toolWord) planned",
            detail: detail
        )
    }

    static func completed(observations: [PaceActionExecutionObservation]) -> PaceActionRunRecord {
        let hasFailure = observations.contains { observation in
            let lowercasedSummary = observation.summary.lowercased()
            return lowercasedSummary.contains("failed")
                || lowercasedSummary.contains("could not")
                || lowercasedSummary.contains("not granted")
                || lowercasedSummary.contains("does not exist")
        }

        let feedback = PaceActionExecutionObservation.formatForUserFeedback(observations)
            ?? "No tool observations returned."
        return PaceActionRunRecord(
            status: hasFailure ? .failed : .completed,
            title: hasFailure ? "Action needs attention" : "Action complete",
            detail: feedback
        )
    }
}
