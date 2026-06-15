//
//  StreamingSentenceTTSPipeline.swift
//  leanring-buddy
//
//  Consumes the planner's streamed text chunks and dispatches
//  completed sentences to the TTS client as they become available.
//  This is the dominant lever on perceived latency — instead of
//  waiting for the full response to generate before speaking starts
//  (~3s for a typical reply), we begin speaking ~500ms in.
//
//  `AVSpeechSynthesizer.speak(_:)` natively queues utterances, so
//  multiple submissions play seamlessly in order without any extra
//  scheduling code on our side.
//

import Combine
import Foundation

@MainActor
final class StreamingSentenceTTSPipeline: ObservableObject {
    private let ttsClient: any BuddyTTSClient
    /// Tag-stripped, sentence-bounded text that's already been queued
    /// to the TTS client. We diff against this on each new chunk so
    /// only the new completed sentence(s) get spoken.
    private var alreadyDispatchedSafeText: String = ""

    /// Live UI mirror of the speakable text accumulated for the current
    /// turn. Updated on every chunk so SwiftUI surfaces (the chat
    /// transcript in particular) can render a streaming "assistant is
    /// typing" row without subscribing to the planner stream directly.
    /// Cleared by `resetForNewTurn()`. Holds the tag-stripped,
    /// sentence-bounded prefix — identical to what gets spoken — so the
    /// rendered text never includes `<think>` blocks, tool calls, or
    /// `[POINT:…]` tags.
    @Published private(set) var inFlightStreamedText: String = ""

    /// Set once the turn's reply has been committed to the chat
    /// transcript (via `finalizeInFlightStreamedTextForTurn()`). While
    /// true, the dispatch path stops mirroring text into
    /// `inFlightStreamedText` — the committed message is now the single
    /// source of truth, so the live "assistant is typing" row must NOT
    /// reappear. Without this guard the final `flushFinal(...)` call
    /// (and any late `acceptStreamedText` chunk that lands after the
    /// commit) re-populates `inFlightStreamedText`, making the panel
    /// render the reply twice (streaming row + committed row). Reset by
    /// `resetForNewTurn()`.
    private var hasFinalizedStreamedTextForTurn: Bool = false

    /// Minimum length of a "completed" prefix before we submit it to
    /// the TTS. Avoids speaking tiny fragments like "Sure," in
    /// isolation when the planner is still thinking. Lower = faster
    /// first audio out. 8 chars is roughly "hmm, that" — enough for
    /// AVSpeechSynthesizer to begin meaningfully without sounding
    /// clipped.
    private let minimumChunkCharacterCount: Int = 8

    /// Lower threshold used ONLY for the very first sentence of a turn.
    /// Wave 4: trimming the first-sentence floor from 8 → 4 chars lets a
    /// 4-character planner token like "Yes." or "Sure." dispatch the
    /// instant it lands — perceived TTFSW drops by the synthesis latency
    /// of one full word. Subsequent sentences keep the 8-char floor so
    /// the prefetch queue stays effective and the next sentence is
    /// already rendering while the first one plays.
    private let firstSentenceMinimumChunkCharacterCount: Int = 4

    /// True until the FIRST sentence of the current turn has been
    /// dispatched to TTS. Reset on every `markIntentCommitted()` call so
    /// the lowered threshold only applies once per turn. Used in
    /// `dispatchDeltaIfReady` to pick which minimum-chunk floor to apply.
    private var hasDispatchedFirstSentenceOfTurn: Bool = false

    /// Per-turn count of characters that have actually been handed to
    /// `ttsClient.speakText(...)`. Wave 4: the speculative-planner race
    /// supersede-window uses this to decide whether the user has already
    /// heard "too much" of the lite winner to justify a mid-turn cut to
    /// the full pipeline. ~60 chars ≈ 6 spoken syllables; past that
    /// threshold a hard cut feels jarring even if the full stream is
    /// only milliseconds away. Reset on every `markIntentCommitted()`.
    @Published private(set) var firstSpokenWordCharacterCount: Int = 0

    /// Timestamp of the moment the user committed to a query — typically
    /// PTT-release. Set externally via `markIntentCommitted()`. Used to
    /// log time-to-first-spoken-word (TTFSW), the headline latency
    /// metric this product is positioned on.
    private var intentCommittedAt: Date?
    private var hasLoggedTimeToFirstSpokenWord: Bool = false

    /// Per-turn mute switch. When set, the pipeline still computes the
    /// speakable prefix and publishes it through `inFlightStreamedText`
    /// (so the chat UI keeps streaming) but skips the `ttsClient.speakText`
    /// dispatch — chat-mode mute. Reset on every turn boundary so the
    /// flag is ephemeral by construction and cannot leak into the next
    /// voice turn.
    private var isMutedForCurrentTurn: Bool = false

    /// True once `drainQueueAndStopForBargeIn()` has been called for the
    /// current turn. Locks out any further `dispatchDeltaIfReady` work
    /// for THIS turn so speculative sentences arriving after the user
    /// interrupted (e.g. a planner chunk still in flight, or a Wave 4
    /// speculative prefetch result) cannot leak audio. Cleared on the
    /// next `markIntentCommitted()` so the next turn starts clean.
    private var hasBeenDrainedForBargeInThisTurn: Bool = false

    /// Public read of whether the LAST completed turn was interrupted
    /// by a barge-in. Tests assert on this; the CompanionManager uses
    /// it when journaling the interrupt line. Reset on the next
    /// `markIntentCommitted()` call, which represents the user
    /// committing the NEXT turn's intent — at that point the previous
    /// turn's "was interrupted" state is no longer relevant.
    @Published private(set) var lastTurnWasInterrupted: Bool = false

    init(ttsClient: any BuddyTTSClient) {
        self.ttsClient = ttsClient
    }

    /// Called when a new voice turn begins. Clears the dispatch
    /// history so the next chunk starts a fresh queue.
    func resetForNewTurn() {
        alreadyDispatchedSafeText = ""
        intentCommittedAt = nil
        hasLoggedTimeToFirstSpokenWord = false
        isMutedForCurrentTurn = false
        inFlightStreamedText = ""
        hasBeenDrainedForBargeInThisTurn = false
        hasDispatchedFirstSentenceOfTurn = false
        firstSpokenWordCharacterCount = 0
        hasFinalizedStreamedTextForTurn = false
    }

    /// Retires the live streaming-reply mirror at turn completion and
    /// LOCKS it retired for the rest of the turn. The committed assistant
    /// message has just landed in the chat transcript, so the "assistant
    /// is typing" row must clear now AND stay clear — otherwise the final
    /// `flushFinal(...)` dispatch (which still needs to play the audio
    /// tail) or a late `acceptStreamedText` chunk re-populates
    /// `inFlightStreamedText` and the panel renders the reply twice. The
    /// lock is released by the next turn's `resetForNewTurn()`. Mirrors
    /// the `liveSpeechDraft` retirement on the user side.
    func finalizeInFlightStreamedTextForTurn() {
        hasFinalizedStreamedTextForTurn = true
        inFlightStreamedText = ""
    }

    /// Sets the per-turn mute flag. Called by `CompanionManager` right
    /// before a chat-mode turn dispatches into the planner so the
    /// session's `isChatTTSMuted` value gates audio for THIS turn only.
    func setMutedForCurrentTurn(_ isMutedForCurrentTurn: Bool) {
        self.isMutedForCurrentTurn = isMutedForCurrentTurn
    }

    /// Mark the moment the user finished expressing intent (PTT
    /// release). The pipeline measures from this point to the first
    /// dispatched TTS utterance and logs it as time-to-first-spoken-
    /// word — the headline latency metric on the product positioning.
    /// Also clears `lastTurnWasInterrupted` because a new intent
    /// commit means the prior turn's interrupted state is no longer
    /// meaningful — the user has moved on.
    func markIntentCommitted() {
        intentCommittedAt = Date()
        hasLoggedTimeToFirstSpokenWord = false
        lastTurnWasInterrupted = false
        hasBeenDrainedForBargeInThisTurn = false
        // Wave 4: every per-turn flag controlling the speed levers
        // resets here. The new turn earns its lowered first-sentence
        // threshold regardless of how the previous turn ended.
        hasDispatchedFirstSentenceOfTurn = false
        firstSpokenWordCharacterCount = 0
    }

    /// Wave 4 speculative-race supersede entry point. Distinct from
    /// `drainQueueAndStopForBargeIn()`: a supersede is NOT a user
    /// interruption — it's Pace deciding the full pipeline's answer is
    /// better and swapping it in for the lite answer mid-turn. So this:
    ///
    /// 1. Stops the lite sentence currently playing (the user hears a
    ///    brief silence, then the full answer starts).
    /// 2. Resets the dispatch cursor + first-sentence/in-flight state so
    ///    the full stream's accumulated text — which is a DIFFERENT string
    ///    from the lite text — replays cleanly as fresh sentences instead
    ///    of being diffed against the lite prefix (which would dispatch
    ///    garbage or nothing).
    /// 3. Does NOT set `hasBeenDrainedForBargeInThisTurn`, so the full
    ///    stream's subsequent `acceptStreamedText` calls are accepted —
    ///    unlike the barge-in lock, which permanently silences the turn.
    /// 4. PRESERVES `intentCommittedAt` and `hasLoggedTimeToFirstSpokenWord`
    ///    so the TTFSW measurement already taken at the lite first word is
    ///    not lost or re-logged. The headline latency metric still reflects
    ///    when the user first heard audio, race or not.
    func prepareForSupersedingStreamWithinTurn() {
        ttsClient.stopPlayback()
        alreadyDispatchedSafeText = ""
        inFlightStreamedText = ""
        hasDispatchedFirstSentenceOfTurn = false
        firstSpokenWordCharacterCount = 0
    }

    /// Barge-in entry point: empties the in-memory sentence queue, stops
    /// the current sentence on the underlying TTS client, and locks the
    /// pipeline so any speculative sentence (Wave 4's prefetch results,
    /// in-flight planner stream chunks that arrive after the user
    /// interrupted) is discarded on arrival. Distinct from regular
    /// `ttsClient.stopPlayback()` because regular stop doesn't prevent
    /// new sentences from being submitted — this method also guards
    /// against subsequent `acceptStreamedText` calls within the SAME
    /// turn so audio cannot resume after a barge-in.
    ///
    /// Publishes `lastTurnWasInterrupted = true` so the CompanionManager
    /// can include the flag in the paceHistory interrupt log line. Resets
    /// on `markIntentCommitted()` for the next turn.
    func drainQueueAndStopForBargeIn() {
        // Pre-stamp the stop reason BEFORE stopping. The client's
        // stopPlayback() reads the pending reason and propagates it
        // to `lastStopReason` — so a CompanionManager post-stop read
        // sees `.userBargeIn` instead of `.manualStop`.
        ttsClient.recordExpectedStopReason(.userBargeIn)
        // Stop in-flight playback first so the user hears silence
        // immediately, then mark the lock so subsequent
        // `dispatchDeltaIfReady` calls skip without speaking. Order
        // matters: a chunk landing between these two lines should be
        // dropped, which the flag below ensures.
        ttsClient.stopPlayback()
        hasBeenDrainedForBargeInThisTurn = true
        lastTurnWasInterrupted = true
    }

    /// Call on every planner-stream chunk. Computes the new
    /// "speakable, complete sentence" prefix and queues just the
    /// delta to TTS. Cheap; safe to call N times per second.
    func acceptStreamedText(_ accumulatedPlannerText: String) async {
        let speakableSafePrefix = Self.computeSpeakableSafePrefix(from: accumulatedPlannerText)
        await dispatchDeltaIfReady(speakableSafePrefix: speakableSafePrefix)
    }

    /// Called when the planner stream completes. The "final" text is
    /// the fully-stripped spoken text from `parsePointingCoordinates`.
    /// Speaks any tail beyond what's already been queued.
    func flushFinal(finalSpokenText: String) async {
        await dispatchDeltaIfReady(speakableSafePrefix: finalSpokenText, allowShortFinalChunk: true)
    }

    // MARK: - Internals

    private func dispatchDeltaIfReady(
        speakableSafePrefix: String,
        allowShortFinalChunk: Bool = false
    ) async {
        // Mirror the current speakable prefix to the chat-stream
        // publisher, even when the delta is whitespace-only or below the
        // TTS dispatch threshold. The chat UI wants to render every
        // intermediate character; the TTS just wants meaningful chunks.
        // Once the turn is finalized (committed reply in the transcript)
        // we STOP mirroring so the live row can't reappear over the
        // committed message — but audio dispatch below still runs, so
        // `flushFinal`'s tail still plays.
        if !hasFinalizedStreamedTextForTurn && speakableSafePrefix != inFlightStreamedText {
            inFlightStreamedText = speakableSafePrefix
        }

        // Barge-in lock: once the user has interrupted, no more audio
        // for THIS turn. The chat-stream publisher above still updates
        // so the text UI sees the rest of the planner output, but the
        // TTS path is silenced — matches the user's expressed intent
        // to stop hearing the response.
        guard !hasBeenDrainedForBargeInThisTurn else { return }

        guard speakableSafePrefix.count > alreadyDispatchedSafeText.count else { return }

        let newPortion = String(speakableSafePrefix.dropFirst(alreadyDispatchedSafeText.count))
        let trimmedNewPortion = newPortion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNewPortion.isEmpty else {
            // Whitespace-only delta — advance the cursor so we don't
            // submit it again later, but don't speak.
            alreadyDispatchedSafeText = speakableSafePrefix
            return
        }

        // Wait until we have a meaningful chunk so we don't speak
        // "I" then "think" then "you" as separate utterances. The
        // final flush bypasses this gate so the tail always plays.
        //
        // Wave 4: for the FIRST sentence of a turn the floor drops to
        // 4 chars so a tiny opener like "Yes." or "Sure." can dispatch
        // the moment it arrives. Once the first sentence is out, the
        // floor rises back to 8 chars so the second sentence has time
        // to render in the prefetch queue before playback catches up.
        let activeMinimumChunkCharacterCount = hasDispatchedFirstSentenceOfTurn
            ? minimumChunkCharacterCount
            : firstSentenceMinimumChunkCharacterCount
        if !allowShortFinalChunk && trimmedNewPortion.count < activeMinimumChunkCharacterCount {
            return
        }

        // Chat-mode mute: still advance the dispatch cursor so we don't
        // re-evaluate the same prefix on every tick, but skip the audio
        // call. The streamed text remains visible to the UI through
        // `inFlightStreamedText` above.
        guard !isMutedForCurrentTurn else {
            alreadyDispatchedSafeText = speakableSafePrefix
            return
        }

        do {
            try await ttsClient.speakText(trimmedNewPortion)
            alreadyDispatchedSafeText = speakableSafePrefix
            // Wave 4: the FIRST successful dispatch flips the threshold
            // gate so subsequent dispatches use the higher 8-char floor.
            // Track total spoken character count so the speculative-
            // planner-race supersede decision can read "how much has
            // the user already heard" without subscribing to TTS state.
            hasDispatchedFirstSentenceOfTurn = true
            firstSpokenWordCharacterCount += trimmedNewPortion.count
            logTimeToFirstSpokenWordIfApplicable()
        } catch {
            print("⚠️ Streaming TTS submission failed: \(error.localizedDescription)")
        }
    }

    /// On the first successful dispatch after `markIntentCommitted()`,
    /// print the time-to-first-spoken-word. AVSpeechSynthesizer
    /// typically begins audio playback within ~80-200ms of `speak()`
    /// returning, so this is the closest in-process proxy for "user
    /// hears the first syllable" without instrumenting the audio HAL.
    private func logTimeToFirstSpokenWordIfApplicable() {
        guard !hasLoggedTimeToFirstSpokenWord,
              let intentCommittedAt else {
            return
        }
        hasLoggedTimeToFirstSpokenWord = true
        let timeToFirstSpokenWordMs = Int(Date().timeIntervalSince(intentCommittedAt) * 1000)
        print("⚡ TTFSW: \(timeToFirstSpokenWordMs)ms (PTT-release → first TTS dispatch)")
        PaceTelemetryLog.recordTimeToFirstSpokenWord(milliseconds: timeToFirstSpokenWordMs)
    }

    /// Test hook for `computeSpeakableSafePrefix`. Exposes the
    /// nonisolated static helper so unit tests can fixture the parser
    /// without instantiating the full pipeline (which needs a TTS
    /// client and a MainActor context).
    nonisolated static func testablyComputeSpeakableSafePrefix(
        from rawAccumulatedText: String
    ) -> String {
        computeSpeakableSafePrefix(from: rawAccumulatedText)
    }

    /// Strip everything the user shouldn't hear, then bound to the
    /// last complete sentence in the result. The order matters:
    /// thinking blocks first (their `<think>...</think>` would otherwise
    /// look like a "sentence" to the boundary detector), then action
    /// tags + POINT, then sentence segmentation.
    nonisolated private static func computeSpeakableSafePrefix(from rawAccumulatedText: String) -> String {
        // 1. Thinking blocks — handles unterminated `<think>` mid-stream
        //    by dropping everything from the opening tag to end-of-text.
        let thinkStripped = LocalPlannerClient.stripThinkingBlocks(from: rawAccumulatedText)
        guard !thinkStripped.isEmpty else { return "" }
        if looksLikeStructuredPlannerJSON(thinkStripped) {
            return ""
        }

        // 2. Strip ALL complete tool-call blocks, action tags + the POINT tag. Partial
        //    in-progress tags (a `[CLICK` with no closing `]` yet) are
        //    NOT stripped — they remain in the text and will block
        //    sentence-boundary detection until the `]` arrives, which
        //    is exactly what we want (we don't want to speak half of
        //    a tag).
        let toolCallStripped = stripCompletedToolCallBlocksForSpeech(from: thinkStripped)
        let actionStripped = stripCompletedActionTagsForSpeech(from: toolCallStripped)
        let pointStripped = stripPointTagForSpeech(from: actionStripped)

        // 3. If there's an open `<tool_calls` or `[` with no matching
        //    close yet, we can't safely speak anything past it — the
        //    planner might emit a tool/action we'd otherwise speak aloud.
        let safeFromOpenToolCallBlock: String = {
            guard let openToolCallRange = pointStripped.range(
                of: "<tool_calls",
                options: [.caseInsensitive, .backwards]
            ) else {
                return pointStripped
            }
            let afterOpen = openToolCallRange.upperBound
            if afterOpen < pointStripped.endIndex,
               pointStripped[afterOpen...].range(of: "</tool_calls>", options: [.caseInsensitive]) != nil {
                return pointStripped
            }
            return String(pointStripped[..<openToolCallRange.lowerBound])
        }()

        let safeFromOpenBracket: String = {
            guard let lastOpenBracketIndex = safeFromOpenToolCallBlock.lastIndex(of: "[") else {
                return safeFromOpenToolCallBlock
            }
            // Is there a closing `]` after it?
            let afterOpen = safeFromOpenToolCallBlock.index(after: lastOpenBracketIndex)
            if afterOpen < safeFromOpenToolCallBlock.endIndex,
               safeFromOpenToolCallBlock[afterOpen...].contains("]") {
                return safeFromOpenToolCallBlock
            }
            return String(safeFromOpenToolCallBlock[..<lastOpenBracketIndex])
        }()

        // 4. Bound to last complete sentence so we don't speak partial
        //    words. Sentence terminators: `.` `!` `?` `\n`. Require
        //    the terminator to be followed by whitespace OR end of text.
        return computeLastSentenceBoundedPrefix(of: safeFromOpenBracket)
    }

    nonisolated private static func looksLikeStructuredPlannerJSON(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.hasPrefix("{") else { return false }
        return trimmedText.contains(#""spokenText""#)
            || trimmedText.contains(#""intent""#)
            || trimmedText.contains(#""payload""#)
    }

    nonisolated private static func stripCompletedToolCallBlocksForSpeech(from text: String) -> String {
        let pattern = #"<tool_calls>.*?</tool_calls>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return text
        }
        let entireRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: entireRange, withTemplate: ""
        )
    }

    nonisolated private static func stripCompletedActionTagsForSpeech(from text: String) -> String {
        // Matches the same tag shapes PaceActionTagParser recognises.
        let pattern = #"\[(CLICK|DOUBLE_CLICK|TYPE|KEY|SCROLL|OPEN_APP|OPEN_URL|MUSIC|VOLUME|BRIGHTNESS|CALENDAR|REMINDER|DONE):?[^\]]*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let entireRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: entireRange, withTemplate: ""
        )
    }

    nonisolated private static func stripPointTagForSpeech(from text: String) -> String {
        let pattern = #"\[POINT:[^\]]*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let entireRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: entireRange, withTemplate: ""
        )
    }

    nonisolated private static func computeLastSentenceBoundedPrefix(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        // Sentence terminators dispatch a chunk on any prefix length;
        // clause terminators only count when there's already enough
        // text to sound like a phrase (≥18 chars), so we don't speak
        // "hmm," or "sure," as a stub.
        let sentenceTerminators: Set<Character> = [".", "!", "?", "\n"]
        let clauseTerminators: Set<Character> = [",", ";", "—", ":"]
        let minimumClauseLength: Int = 18

        // Walk backwards from the end, returning the prefix up to and
        // including the last terminator that's followed by whitespace
        // or end-of-string. Sentence terminators win unconditionally;
        // clause terminators win only past the minimum length.
        var lastSafeIndex: String.Index?
        var characterIndex = text.endIndex
        while characterIndex > text.startIndex {
            characterIndex = text.index(before: characterIndex)
            let currentCharacter = text[characterIndex]
            let isSentenceTerminator = sentenceTerminators.contains(currentCharacter)
            let isClauseTerminator = clauseTerminators.contains(currentCharacter)
            guard isSentenceTerminator || isClauseTerminator else { continue }

            let oneAfter = text.index(after: characterIndex)
            let isFollowedByWhitespaceOrEnd = oneAfter == text.endIndex
                || text[oneAfter].isWhitespace
            guard isFollowedByWhitespaceOrEnd else { continue }

            if isSentenceTerminator {
                lastSafeIndex = oneAfter
                break
            }
            // Clause terminator: require enough prior text so we don't
            // dispatch "hmm," in isolation. Distance from start to this
            // point is the prefix length being considered.
            let prefixLengthSoFar = text.distance(from: text.startIndex, to: oneAfter)
            if prefixLengthSoFar >= minimumClauseLength {
                lastSafeIndex = oneAfter
                break
            }
        }

        guard let safeIndex = lastSafeIndex else { return "" }
        return String(text[..<safeIndex])
    }
}
