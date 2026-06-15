//
//  StreamingSentenceTTSPipelineDispatchTests.swift
//  leanring-buddyTests
//
//  Wave 4 dispatch-layer tests for `StreamingSentenceTTSPipeline`. The
//  pure parsing logic is covered in
//  `StreamingSentenceTTSPipelineParsingTests`; this file exercises the
//  side-effecting dispatch path through a fake TTS client so we can
//  verify the lowered FIRST-sentence threshold + the eager-filler
//  debouncer behave correctly.
//

import Foundation
import Testing

@testable import Pace

/// Minimal BuddyTTSClient conformer that records every dispatched
/// utterance. Mirrors the stop-reason book-keeping of the real
/// `LocalServerTTSClient` so a turn boundary clears state predictably.
@MainActor
private final class DispatchTestRecordingTTSClient: BuddyTTSClient {
    private(set) var spokenTexts: [String] = []
    private(set) var stopPlaybackCallCount: Int = 0
    private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion
    private var pendingNextStopReason: PaceTTSStopReason?
    var isPlaying: Bool { false }

    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
        lastStopReason = .naturalCompletion
        pendingNextStopReason = nil
    }

    func stopPlayback() {
        stopPlaybackCallCount += 1
        lastStopReason = pendingNextStopReason ?? .manualStop
        pendingNextStopReason = nil
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
        pendingNextStopReason = reason
    }
}

@MainActor
struct StreamingSentenceTTSPipelineDispatchTests {

    // MARK: - Wave 4: first-sentence 4-char threshold

    @Test func fourCharFirstSentenceDispatchesImmediately() async throws {
        // "Yes." is exactly 4 chars after the sentence terminator —
        // the new first-sentence floor. The pipeline must dispatch it
        // even though the legacy 8-char floor would have held it back.
        let ttsClient = DispatchTestRecordingTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        pipeline.markIntentCommitted()

        await pipeline.acceptStreamedText("Yes.")

        #expect(ttsClient.spokenTexts.count == 1,
                "First sentence below 8 chars but at/above 4 chars must dispatch under Wave 4.")
        #expect(ttsClient.spokenTexts.first == "Yes.")
    }

    @Test func subsequentFourCharFragmentsAreHeldBack() async throws {
        // After the first sentence has dispatched, the floor returns to
        // 8 chars. A second 4-char fragment ("And.") must NOT dispatch
        // until enough text has accumulated to pass 8 chars.
        let ttsClient = DispatchTestRecordingTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        pipeline.markIntentCommitted()

        // First sentence dispatches at 4 chars under the lowered floor.
        await pipeline.acceptStreamedText("Yes.")
        #expect(ttsClient.spokenTexts.count == 1)

        // Second 4-char fragment alone must be held — the new portion
        // is "And." (4 chars), below the 8-char floor that applies
        // post-first-sentence.
        await pipeline.acceptStreamedText("Yes. And.")
        #expect(ttsClient.spokenTexts.count == 1,
                "Second sentence at 4 chars must NOT dispatch — floor reverted to 8.")

        // Once the second sentence grows past 8 chars it dispatches.
        await pipeline.acceptStreamedText("Yes. And then maybe.")
        #expect(ttsClient.spokenTexts.count == 2,
                "Second sentence past the 8-char floor must dispatch.")
    }

    @Test func resetForNewTurnRestoresLoweredFirstSentenceFloor() async throws {
        // Across a turn boundary the FIRST sentence of the new turn
        // gets the 4-char floor again. Without the explicit reset the
        // `hasDispatchedFirstSentenceOfTurn` flag would leak across
        // turns.
        let ttsClient = DispatchTestRecordingTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)

        pipeline.resetForNewTurn()
        pipeline.markIntentCommitted()
        await pipeline.acceptStreamedText("Sure.")
        #expect(ttsClient.spokenTexts.count == 1)

        // New turn — caller resets the dispatch cursor (mirrors
        // production flow: CompanionManager always pairs
        // resetForNewTurn() with markIntentCommitted() at turn boundaries)
        // so the lowered floor applies to the next 4-char opener.
        pipeline.resetForNewTurn()
        pipeline.markIntentCommitted()
        await pipeline.acceptStreamedText("Okay.")
        #expect(ttsClient.spokenTexts.count == 2,
                "After a turn boundary the new first sentence must dispatch under the 4-char floor.")
        #expect(ttsClient.spokenTexts.last == "Okay.")
    }

    @Test func firstSpokenWordCharacterCountTracksDispatch() async throws {
        // The speculative-race supersede decision reads this count to
        // know how much the user has heard. Each successful dispatch
        // must advance it by the dispatched character length.
        let ttsClient = DispatchTestRecordingTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        pipeline.markIntentCommitted()
        #expect(pipeline.firstSpokenWordCharacterCount == 0)

        await pipeline.acceptStreamedText("Yes.")
        #expect(pipeline.firstSpokenWordCharacterCount == 4)

        await pipeline.acceptStreamedText("Yes. And then maybe.")
        // Second dispatch adds "And then maybe." — 15 chars trimmed.
        #expect(pipeline.firstSpokenWordCharacterCount == 4 + "And then maybe.".count)
    }

}
