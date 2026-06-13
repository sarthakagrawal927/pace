//
//  PaceTranscriptionContextualPhraseBuilder.swift
//  leanring-buddy
//
//  Builds local-only vocabulary hints for the active transcription provider.
//

import AppKit
import Foundation

enum PaceTranscriptionContextualPhraseBuilder {
    static let maximumPhraseCount = 80

    static func phrasesForCurrentTurn(
        frontmostApplicationName: String? = NSWorkspace.shared.frontmostApplication?.localizedName,
        additionalTerms: [String] = []
    ) -> [String] {
        var candidatePhrases: [String] = [
            "Pace",
            "Raycast",
            "LM Studio",
            "Qwen",
            "Qwen three",
            "WhisperKit",
            "ScreenCaptureKit",
            "SwiftUI",
            "AppKit",
            "Accessibility",
            "AX",
            "Finder",
            "Notes",
            "Mail",
            "Calendar",
            "Reminders",
            "Things",
            "Shortcuts",
            "Messages"
        ]

        if let frontmostApplicationName {
            candidatePhrases.append(frontmostApplicationName)
        }

        for toolDefinition in PaceToolRegistry.localTools {
            candidatePhrases.append(toolDefinition.canonicalName)
            candidatePhrases.append(Self.spokenPhrase(fromToolName: toolDefinition.canonicalName))
            candidatePhrases.append(contentsOf: toolDefinition.aliases)
            candidatePhrases.append(contentsOf: toolDefinition.aliases.map(Self.spokenPhrase(fromToolName:)))
        }

        candidatePhrases.append(contentsOf: additionalTerms)

        return Array(uniquePhrases(candidatePhrases).prefix(maximumPhraseCount))
    }

    nonisolated static func spokenPhrase(fromToolName toolName: String) -> String {
        toolName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    static func uniquePhrases(_ phrases: [String]) -> [String] {
        var seenNormalizedPhrases = Set<String>()
        var uniquePhrases: [String] = []

        for phrase in phrases {
            let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPhrase.isEmpty else { continue }

            let normalizedPhrase = trimmedPhrase
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()

            guard seenNormalizedPhrases.insert(normalizedPhrase).inserted else { continue }
            uniquePhrases.append(trimmedPhrase)
        }

        return uniquePhrases
    }
}
