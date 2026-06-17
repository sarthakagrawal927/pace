//
//  PaceClearAnnotationsCommandParserTests.swift
//  leanring-buddyTests
//
//  Pure parser tests — no CompanionManager construction needed.
//

import Testing
@testable import Pace

struct PaceClearAnnotationsCommandParserTests {
    @Test func recognizedClearPhrasesReturnClear() async throws {
        for transcript in [
            "clear annotations",
            "clear the annotations",
            "clear drawings",
            "clear the drawings",
            "stop drawing now please",
            "wipe annotations",
            "wipe the screen for me",
            "remove annotations",
            "erase the annotations",
            "get rid of the drawings",
            "hide annotations",
        ] {
            #expect(
                PaceClearAnnotationsCommandParser.parse(transcript) == .clear,
                "expected \(transcript) to match"
            )
        }
    }

    @Test func capitalizationAndPunctuationToleratedDuringNormalization() async throws {
        #expect(PaceClearAnnotationsCommandParser.parse("Clear, annotations!") == .clear)
        #expect(PaceClearAnnotationsCommandParser.parse("CLEAR ANNOTATIONS.") == .clear)
    }

    @Test func unrelatedTranscriptDoesNotTrigger() async throws {
        #expect(PaceClearAnnotationsCommandParser.parse("") == nil)
        #expect(PaceClearAnnotationsCommandParser.parse("clear the screen") == nil)
        #expect(PaceClearAnnotationsCommandParser.parse("draw a clear circle around the button") == nil)
        #expect(PaceClearAnnotationsCommandParser.parse("annotate the menu") == nil)
        #expect(PaceClearAnnotationsCommandParser.parse("what is on my screen") == nil)
    }
}
