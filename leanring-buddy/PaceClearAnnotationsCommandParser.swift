//
//  PaceClearAnnotationsCommandParser.swift
//  leanring-buddy
//
//  Parses explicit voice commands that wipe the tuition-mode annotation
//  layer. Routed BEFORE the planner in `CompanionManager` so saying
//  "clear annotations" doesn't burn a planner round-trip.
//
//  Mirrors the structural shape of `PaceWatchModeCommandParser` —
//  alphanumeric-normalized substring match against a small phrase list.
//

import Foundation

nonisolated enum PaceClearAnnotationsCommand: Equatable {
    case clear
}

nonisolated enum PaceClearAnnotationsCommandParser {
    static func parse(_ transcript: String) -> PaceClearAnnotationsCommand? {
        let normalizedTranscript = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalizedTranscript.isEmpty else { return nil }
        return matchesClearCommand(normalizedTranscript) ? .clear : nil
    }

    private static func matchesClearCommand(_ normalizedTranscript: String) -> Bool {
        let clearPhrases = [
            "clear annotations",
            "clear the annotations",
            "clear drawings",
            "clear the drawings",
            "clear the drawing",
            "clear annotation",
            "stop drawing",
            "stop drawings",
            "wipe annotations",
            "wipe the annotations",
            "wipe the drawing",
            "wipe drawings",
            "wipe the screen",
            "remove annotations",
            "remove the annotations",
            "remove the drawings",
            "erase annotations",
            "erase the annotations",
            "erase drawings",
            "erase the drawings",
            "get rid of the annotations",
            "get rid of the drawings",
            "hide annotations",
            "hide the annotations",
        ]
        return clearPhrases.contains { normalizedTranscript.contains($0) }
    }
}
