//
//  PaceWatchModeCommandParser.swift
//  leanring-buddy
//
//  Parses explicit voice commands for the screen watch loop. Kept pure so the
//  command grammar can be tested without constructing CompanionManager.
//

import Foundation

nonisolated enum PaceWatchModeCommand: Equatable {
    case start
    case stop
}

nonisolated enum PaceWatchModeCommandParser {
    static func parse(_ transcript: String) -> PaceWatchModeCommand? {
        let normalizedTranscript = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalizedTranscript.isEmpty else {
            return nil
        }

        if containsStopCommand(in: normalizedTranscript) {
            return .stop
        }

        if containsStartCommand(in: normalizedTranscript) {
            return .start
        }

        return nil
    }

    private static func containsStartCommand(in normalizedTranscript: String) -> Bool {
        let startPhrases = [
            "watch my screen",
            "watch the screen",
            "start watch mode",
            "turn on watch mode",
            "enable watch mode",
            "keep watching",
            "watch for changes",
            "monitor my screen",
            "monitor the screen",
        ]

        return startPhrases.contains { normalizedTranscript.contains($0) }
    }

    private static func containsStopCommand(in normalizedTranscript: String) -> Bool {
        let stopPhrases = [
            "stop watching",
            "stop watch mode",
            "turn off watch mode",
            "disable watch mode",
            "cancel watch mode",
            "pause watch mode",
            "quit watch mode",
            "do not watch my screen",
            "don t watch my screen",
            "dont watch my screen",
        ]

        return stopPhrases.contains { normalizedTranscript.contains($0) }
    }
}
