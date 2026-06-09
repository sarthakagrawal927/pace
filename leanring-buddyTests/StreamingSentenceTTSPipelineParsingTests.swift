//
//  StreamingSentenceTTSPipelineParsingTests.swift
//  leanring-buddyTests
//
//  Exercises the pure parsing logic the streaming-TTS pipeline uses to
//  decide WHICH prefix of the planner's accumulated stream is safe to
//  dispatch to TTS this tick. The dispatch logic itself is MainActor +
//  has side effects (calls into AVSpeechSynthesizer), so we don't test
//  it here. The parsing decisions are pure-static and where most of
//  the perceived-latency win lives — get them wrong, the user hears
//  weird fragments or waits too long for first audio.
//

import Testing
@testable import Pace

struct StreamingSentenceTTSPipelineParsingTests {

    // MARK: - Sentence terminators

    @Test func sentenceTerminatorDispatchesPrefixUpToAndIncludingPunctuation() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "hmm, let me think. and then"
        )
        // Period after "think" is a sentence terminator followed by
        // whitespace — that's the cut.
        #expect(result == "hmm, let me think.")
    }

    @Test func exclamationAndQuestionMarkAlsoCount() async throws {
        let resultExclamation = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "got it! anything else"
        )
        #expect(resultExclamation == "got it!")

        let resultQuestion = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "what's up? need more"
        )
        #expect(resultQuestion == "what's up?")
    }

    @Test func sentenceTerminatorWithoutTrailingSpaceIsNotDispatched() async throws {
        // No whitespace after the period — could be an abbreviation or
        // mid-word, so we wait.
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "the file is foo.swift"
        )
        #expect(result == "")
    }

    // MARK: - Clause boundaries (the May-2026 latency win)

    @Test func clauseTerminatorDispatchesOnceMinimumLengthMet() async throws {
        // "i think it's broken, " — 19 chars before the comma, well
        // past the 18-char minimum-clause threshold. The clause should
        // dispatch even though no period has arrived yet.
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "i think it's broken, but maybe"
        )
        #expect(result == "i think it's broken,")
    }

    @Test func clauseTerminatorBelowMinimumLengthIsHeldBack() async throws {
        // "hmm, " — only 4 chars before the comma. Below threshold,
        // hold for more text so we don't speak a 2-word stub.
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "hmm, but maybe later"
        )
        #expect(result == "")
    }

    @Test func semicolonAndEmDashAlsoTriggerClauseDispatch() async throws {
        let semicolon = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "okay so this is a thing; another bit"
        )
        #expect(semicolon == "okay so this is a thing;")

        let emDash = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "let's look at it carefully— here's why"
        )
        #expect(emDash == "let's look at it carefully—")
    }

    @Test func colonAlsoTriggersClauseDispatch() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "here's the thing about it: the bug"
        )
        #expect(result == "here's the thing about it:")
    }

    // MARK: - Thinking-block stripping (defensive — feeds into the parser)

    @Test func completedThinkingBlockIsStrippedBeforeBoundaryDetection() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "<think>plan: greet</think>hi there. what's up"
        )
        #expect(result == "hi there.")
    }

    @Test func unterminatedMidStreamThinkingBlockSwallowsTrailingText() async throws {
        // Mid-stream: <think> opened but not yet closed. We can't
        // safely speak past the open tag, so cut at it.
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "ok ready. <think>still thinking"
        )
        #expect(result == "ok ready.")
    }

    // MARK: - Action-tag stripping

    @Test func completedActionTagsAreStrippedFromSpeakablePrefix() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "opening safari [OPEN_APP:Safari] and turning it down [VOLUME:down:2] [DONE]. done."
        )
        // Action tags and [DONE] strip out; the trailing "done."
        // sentence remains the speakable boundary.
        #expect(result == "opening safari  and turning it down  . done.")
    }

    @Test func completedToolCallBlockIsStrippedFromSpeakablePrefix() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: """
            opening music. <tool_calls>
            [[{"tool":"open_app","app":"Music"}]]
            </tool_calls> done.
            """
        )

        #expect(result == "opening music.  done.")
    }

    @Test func openToolCallBlockWithoutClosingTagCutsAtOpenTag() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "opening music. <tool_calls>[[{\"tool\":\"open_app\""
        )

        #expect(result == "opening music.")
    }

    @Test func openActionTagWithoutClosingBracketCutsAtOpenBracket() async throws {
        // Mid-stream: planner has emitted "[CLI" but not "]" yet. We
        // cannot safely speak the tag fragment.
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "sure thing. [CLI"
        )
        #expect(result == "sure thing.")
    }

    @Test func pointTagIsStrippedJustLikeActionTags() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "look at the save button. [POINT:400,300:save]"
        )
        #expect(result == "look at the save button.")
    }

    @Test func structuredPlannerJSONIsNotSpokenMidStream() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: #"{"spokenText":"Drafting that now.","intent":"action","payload":{"name":"Mail.draft""#
        )

        #expect(result == "")
    }

    // MARK: - Empty / edge inputs

    @Test func emptyInputReturnsEmpty() async throws {
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(from: "")
        #expect(result == "")
    }

    @Test func textWithoutAnyTerminatorReturnsEmpty() async throws {
        // No `.`, `!`, `?`, or qualifying clause boundary — wait for more.
        let result = StreamingSentenceTTSPipeline.testablyComputeSpeakableSafePrefix(
            from: "the quick brown fox jumps"
        )
        #expect(result == "")
    }
}
