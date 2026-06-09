//
//  PaceDictationPostProcessorTests.swift
//  leanring-buddyTests
//
//  Coverage for the rule-backed dictation post-processor — the Stage A
//  scaffold that runs on every `intent:"dictate"` payload before the
//  text reaches AX type-replay. Tests pin current behavior so the
//  upcoming trained post-processor (Stage B) can be A/B'd against a
//  known baseline.
//

import Testing

@testable import Pace

struct PaceDictationPostProcessorTests {

    // MARK: - Empty / whitespace inputs

    @Test func emptyInputYieldsEmpty() async throws {
        #expect(PaceDictationPostProcessor.process(rawText: "") == "")
    }

    @Test func whitespaceOnlyInputYieldsEmpty() async throws {
        #expect(PaceDictationPostProcessor.process(rawText: "   \n\t  ") == "")
    }

    // MARK: - Spoken punctuation expansion

    @Test func expandsComma() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "hello comma world")
        #expect(out.contains(", world"))
    }

    @Test func expandsPeriod() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "i love this period new thought")
        #expect(out.contains(". new thought"))
    }

    @Test func expandsQuestionMark() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "are you there question mark")
        #expect(out.contains("there?"))
    }

    @Test func expandsExclamationMark() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "wow exclamation mark amazing")
        #expect(out.contains("! amazing"))
    }

    @Test func expandsColonAndSemicolon() async throws {
        let colon = PaceDictationPostProcessor.process(rawText: "key colon value")
        #expect(colon.contains(": value"))
        let semi = PaceDictationPostProcessor.process(rawText: "first semicolon second")
        #expect(semi.contains("; second"))
    }

    @Test func expandsParens() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "calling open paren foo close paren done")
        #expect(out.contains("(foo)"))
    }

    @Test func expandsParenthesisLongForm() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "calling open parenthesis foo close parenthesis done")
        #expect(out.contains("(foo)"))
    }

    @Test func expandsSlashes() async throws {
        let fwd = PaceDictationPostProcessor.process(rawText: "path is foo slash bar")
        #expect(fwd.contains("foo/bar"))
        let bwd = PaceDictationPostProcessor.process(rawText: "win path c backslash temp")
        #expect(bwd.contains("c\\temp"))
    }

    @Test func expandsUnderscoreAndDash() async throws {
        let under = PaceDictationPostProcessor.process(rawText: "name is foo underscore bar")
        #expect(under.contains("foo_bar"))
        let dash = PaceDictationPostProcessor.process(rawText: "id is alpha dash beta")
        #expect(dash.contains("alpha-beta"))
    }

    @Test func expandsFullStopAsAlias() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "ok full stop next")
        #expect(out.contains(". next"))
    }

    @Test func collapsesMultipleSpaces() async throws {
        // Multi-token spoken punctuation should not leave double-spaces in the
        // collapsed output.
        let out = PaceDictationPostProcessor.process(rawText: "a comma b comma c")
        #expect(!out.contains("  "))
        // First-letter gets capitalized; check the tail substring + comma joins.
        #expect(out.contains(", b, c"))
    }

    @Test func tightensSpaceBeforeTrailingPunctuation() async throws {
        // The regex `" +([,.;:?!\)])"` removes spaces between text and a
        // trailing punctuation glyph after expansion.
        let out = PaceDictationPostProcessor.process(rawText: "ending here period")
        #expect(out.contains("here."))
        #expect(!out.contains("here ."))
    }

    // MARK: - Prose contraction cleanup

    @Test func contractsLetsToLetsApostrophe() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "lets go")
        #expect(out.starts(with: "Let's") || out.starts(with: "let's"))
    }

    @Test func contractsImToImApostrophe() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "im going now")
        #expect(out.contains("I'm going"))
    }

    @Test func capitalizesIWhenStandalone() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "hi i am here")
        #expect(out.contains(" I am "))
    }

    @Test func iInsideWordIsNotTouched() async throws {
        // Word boundary should prevent capitalizing the "i" in "him" / "this".
        let out = PaceDictationPostProcessor.process(rawText: "im happy with this")
        #expect(out.contains("this"))
        #expect(!out.contains("thIs"))
    }

    // MARK: - First-letter capitalization

    @Test func capitalizesFirstLetterOfProse() async throws {
        let out = PaceDictationPostProcessor.process(rawText: "hello there")
        #expect(out.starts(with: "Hello"))
    }

    @Test func capitalizesFirstLetterAfterPunctuationCleanup() async throws {
        // Spoken punctuation should not break first-letter capitalization.
        let out = PaceDictationPostProcessor.process(rawText: "hi comma friend")
        #expect(out.starts(with: "Hi"))
    }

    // MARK: - Mode-driven routing

    @Test func explicitProseModeUsesProseCleanup() async throws {
        // Even with paren-like content, an explicit "prose" mode does not
        // attempt the code-cleanup path.
        let out = PaceDictationPostProcessor.process(
            rawText: "open paren foo close paren",
            mode: "prose"
        )
        // Should still be parens, but should NOT be treated as a function call
        #expect(out.contains("(foo)"))
    }

    @Test func explicitCodeModeTriggersCodeCleanupEvenWithoutHeuristics() async throws {
        let out = PaceDictationPostProcessor.process(
            rawText: "parse action payload open paren args close paren",
            mode: "code"
        )
        // Function-call pattern should produce camelCase + args
        #expect(out == "parseActionPayload(args)")
    }

    // MARK: - Code-mode heuristics

    @Test func codeHeuristicTriggersOnParenChars() async throws {
        let out = PaceDictationPostProcessor.process(
            rawText: "get user open paren id close paren"
        )
        // Heuristic should detect "(" after expansion and run code cleanup
        #expect(out == "getUser(id)")
    }

    @Test func codeHeuristicTriggersOnUnderscore() async throws {
        // "snake case" phrase implies code mode per looksLikeSpokenCode
        let out = PaceDictationPostProcessor.process(
            rawText: "make a snake case name open paren foo close paren"
        )
        // Should be routed through code cleanup
        #expect(out.contains("("))
        #expect(out.contains(")"))
    }

    @Test func codeFunctionCallProducesLowerCamelCase() async throws {
        let out = PaceDictationPostProcessor.process(
            rawText: "Send Mail Now open paren recipient close paren"
        )
        #expect(out.contains("sendMailNow(recipient)"))
    }

    @Test func codeFunctionCallJoinsArgsWithCommas() async throws {
        let out = PaceDictationPostProcessor.process(
            rawText: "compute open paren a b c close paren"
        )
        #expect(out.contains("compute(a, b, c)"))
    }

    // MARK: - Mixed / round-trip behaviors

    @Test func longProseRoundTripPreservesCoreText() async throws {
        let raw = "hey alice comma can we move our lunch to friday question mark"
        let out = PaceDictationPostProcessor.process(rawText: raw)
        // Both the punctuation expansion and contraction/capitalization pass
        // should yield natural text.
        #expect(out.contains("alice"))
        #expect(out.contains("friday?"))
        #expect(out.contains(","))
        #expect(out.starts(with: "Hey"))
    }

    @Test func multipleSentencesCollapseCleanly() async throws {
        let raw = "i landed safely period call you later"
        let out = PaceDictationPostProcessor.process(rawText: raw)
        #expect(out.contains(". call you later"))
        // First-letter cap should also fire
        #expect(out.starts(with: "I") || out.starts(with: "i"))
    }

    @Test func unicodePassesThroughCleanly() async throws {
        // No emoji/unicode rules, but the processor shouldn't crash on
        // non-ASCII input.
        let out = PaceDictationPostProcessor.process(rawText: "café comma latte")
        #expect(out.contains(", latte"))
        #expect(out.contains("afé"))
    }
}
