//
//  PaceTranscriptionContextualPhraseBuilderTests.swift
//  leanring-buddyTests
//

import Testing

@testable import Pace

@MainActor
struct PaceTranscriptionContextualPhraseBuilderTests {
    @Test func includesFrontmostApplicationAndToolNames() async throws {
        let phrases = PaceTranscriptionContextualPhraseBuilder.phrasesForCurrentTurn(
            frontmostApplicationName: "Cursor",
            additionalTerms: []
        )

        #expect(phrases.contains("Cursor"))
        #expect(phrases.contains("open_app"))
        #expect(phrases.contains("open app"))
        #expect(phrases.contains("set_value"))
        #expect(phrases.contains("set value"))
    }

    @Test func removesDuplicatePhrasesCaseInsensitively() async throws {
        let phrases = PaceTranscriptionContextualPhraseBuilder.uniquePhrases([
            "Raycast",
            " raycast ",
            "RAYCAST",
            "Pace"
        ])

        #expect(phrases == ["Raycast", "Pace"])
    }

    @Test func capsPhraseCount() async throws {
        let additionalTerms = (0..<200).map { "term-\($0)" }
        let phrases = PaceTranscriptionContextualPhraseBuilder.phrasesForCurrentTurn(
            frontmostApplicationName: "Cursor",
            additionalTerms: additionalTerms
        )

        #expect(phrases.count == PaceTranscriptionContextualPhraseBuilder.maximumPhraseCount)
    }
}
