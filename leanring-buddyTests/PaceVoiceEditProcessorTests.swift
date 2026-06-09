//
//  PaceVoiceEditProcessorTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceVoiceEditProcessorTests {
    @Test func parsesCommonVoiceEditCommands() async throws {
        #expect(PaceVoiceEditProcessor.parseCommand("make this shorter")?.operation == .shorten)
        #expect(PaceVoiceEditProcessor.parseCommand("make that more direct")?.operation == .makeDirect)
        #expect(PaceVoiceEditProcessor.parseCommand("fix grammar")?.operation == .fixGrammar)
        #expect(PaceVoiceEditProcessor.parseCommand("delete the last sentence")?.operation == .deleteLastSentence)
        #expect(PaceVoiceEditProcessor.parseCommand("turn this into bullets")?.operation == .makeBullets)
        #expect(PaceVoiceEditProcessor.parseCommand("replace sarthak with team")?.operation == .replace(oldText: "sarthak", newText: "team"))
    }

    @Test func appliesDeterministicSelectedTextEdits() async throws {
        let shortenedText = PaceVoiceEditProcessor.process(
            selectedText: "I think we should ship local only. This second sentence is extra.",
            request: PaceVoiceEditRequest(operation: .shorten)
        )
        #expect(shortenedText == "I think we should ship local only")

        let directText = PaceVoiceEditProcessor.process(
            selectedText: "I think we should just ship local only",
            request: PaceVoiceEditRequest(operation: .makeDirect)
        )
        #expect(directText == "We should ship local only")

        let grammarText = PaceVoiceEditProcessor.process(
            selectedText: "lets ship local only",
            request: PaceVoiceEditRequest(operation: .fixGrammar)
        )
        #expect(grammarText == "Let's ship local only")

        let replacedText = PaceVoiceEditProcessor.process(
            selectedText: "Sarthak should review the launch note",
            request: PaceVoiceEditRequest(operation: .replace(oldText: "sarthak", newText: "team"))
        )
        #expect(replacedText == "team should review the launch note")

        let bulletText = PaceVoiceEditProcessor.process(
            selectedText: "Ship local only. Keep it fast.",
            request: PaceVoiceEditRequest(operation: .makeBullets)
        )
        #expect(bulletText == "- Ship local only\n- Keep it fast")
    }
}
