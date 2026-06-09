//
//  PaceTurnHUDState.swift
//  leanring-buddy
//
//  Small user-visible turn status model for the notch panel and cursor
//  bubble. It keeps fast intent/progress feedback out of the planner prompt.
//

import Foundation

enum PaceTurnHUDStatus: Equatable {
    case idle
    case listening
    case understanding
    case acting
    case needsClarification
    case done
    case failed
    case unsupported
}

struct PaceTurnHUDState: Equatable {
    let status: PaceTurnHUDStatus
    let title: String
    let detail: String?
    let options: [String]

    static let idle = PaceTurnHUDState(
        status: .idle,
        title: "Ready",
        detail: nil,
        options: []
    )

    static let listening = PaceTurnHUDState(
        status: .listening,
        title: "Listening",
        detail: "Hold Control+Option",
        options: []
    )

    static func understanding(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .understanding,
            title: "Understanding",
            detail: detail,
            options: []
        )
    }

    static func acting(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .acting,
            title: "Acting",
            detail: detail,
            options: []
        )
    }

    static func clarification(question: String, options: [String]) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .needsClarification,
            title: question,
            detail: options.joined(separator: " / "),
            options: options
        )
    }

    static func done(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .done,
            title: "Done",
            detail: detail,
            options: []
        )
    }

    static func failed(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .failed,
            title: "Needs attention",
            detail: detail,
            options: []
        )
    }

    static func unsupported(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .unsupported,
            title: "Local only",
            detail: detail,
            options: []
        )
    }
}

struct PaceIntentClarification: Equatable {
    let question: String
    let options: [String]
}

struct PacePendingIntentClarification: Equatable {
    let originalTranscript: String
    let clarification: PaceIntentClarification
}

enum PaceIntentClarificationResolver {
    static func clarifiedTranscript(
        for pendingClarification: PacePendingIntentClarification,
        selectedOption: String
    ) -> String? {
        let normalizedSelectedOption = selectedOption
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard pendingClarification.clarification.options.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSelectedOption
        }) else {
            return nil
        }

        let clarifiedTarget: String
        if normalizedSelectedOption.contains("selected text") {
            clarifiedTarget = "selected text"
        } else if normalizedSelectedOption.contains("focused field") {
            clarifiedTarget = "focused field"
        } else if normalizedSelectedOption.contains("current item") {
            clarifiedTarget = "current item"
        } else {
            clarifiedTarget = normalizedSelectedOption
        }

        return replacingAmbiguousReference(
            in: pendingClarification.originalTranscript,
            with: clarifiedTarget
        )
    }

    private static func replacingAmbiguousReference(
        in transcript: String,
        with clarifiedTarget: String
    ) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return "the \(clarifiedTarget)" }

        let pattern = #"\b(it|that|this)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return "\(trimmedTranscript) the \(clarifiedTarget)"
        }

        let fullRange = NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
        guard regex.firstMatch(in: trimmedTranscript, range: fullRange) != nil else {
            return "\(trimmedTranscript) the \(clarifiedTarget)"
        }

        return regex.stringByReplacingMatches(
            in: trimmedTranscript,
            options: [],
            range: fullRange,
            withTemplate: "the \(clarifiedTarget)"
        )
    }
}

struct PaceIntentUnsupportedResponse: Equatable {
    let spokenText: String
    let reason: String
}

enum PaceIntentUnsupportedDetector {
    static func unsupportedResponse(
        for transcript: String,
        prediction: PaceIntentPrediction
    ) -> PaceIntentUnsupportedResponse? {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard prediction.route == .phoneLargeModel
                || normalizedTranscript.contains("use cloud")
                || normalizedTranscript.contains("ask gemini")
                || normalizedTranscript.contains("ask chatgpt")
                || normalizedTranscript.contains("private cloud") else {
            return nil
        }

        return PaceIntentUnsupportedResponse(
            spokenText: "I only use local models on this Mac.",
            reason: "Cloud or large-model escalation is not available."
        )
    }
}

enum PaceIntentClarifier {
    static func clarification(for transcript: String) -> PaceIntentClarification? {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTranscript.isEmpty else { return nil }

        if looksLikeAmbiguousEditCommand(normalizedTranscript) {
            return PaceIntentClarification(
                question: "Edit selected text or the focused field?",
                options: ["Selected text", "Focused field"]
            )
        }

        if looksLikeAmbiguousDestructiveCommand(normalizedTranscript) {
            return PaceIntentClarification(
                question: "What should I delete?",
                options: ["Selected text", "Current item"]
            )
        }

        return nil
    }

    private static func looksLikeAmbiguousEditCommand(_ normalizedTranscript: String) -> Bool {
        let editPhrases = [
            "edit it", "edit that", "edit this",
            "rewrite it", "rewrite that", "rewrite this",
            "fix it", "fix that", "fix this",
            "change it", "change that", "change this",
            "make it better", "clean it up", "polish it"
        ]

        guard editPhrases.contains(where: normalizedTranscript.contains) else {
            return false
        }

        let explicitTargets = [
            "selected text", "selection", "highlighted text",
            "focused field", "current field", "text field",
            "whole field", "draft", "email", "note"
        ]
        return !explicitTargets.contains(where: normalizedTranscript.contains)
    }

    private static func looksLikeAmbiguousDestructiveCommand(_ normalizedTranscript: String) -> Bool {
        let ambiguousDestructivePhrases = [
            "delete it", "delete that", "delete this",
            "remove it", "remove that", "remove this",
            "discard it", "discard that", "discard this"
        ]

        guard ambiguousDestructivePhrases.contains(where: normalizedTranscript.contains) else {
            return false
        }

        let explicitObjects = [
            "selected text", "selection", "highlighted text",
            "sentence", "paragraph", "file", "folder", "email",
            "message", "event", "reminder", "note", "draft",
            "current item"
        ]
        return !explicitObjects.contains(where: normalizedTranscript.contains)
    }
}
