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

import Foundation

@MainActor
final class StreamingSentenceTTSPipeline {
    private let ttsClient: any BuddyTTSClient
    /// Tag-stripped, sentence-bounded text that's already been queued
    /// to the TTS client. We diff against this on each new chunk so
    /// only the new completed sentence(s) get spoken.
    private var alreadyDispatchedSafeText: String = ""

    /// Minimum length of a "completed" prefix before we submit it to
    /// the TTS. Avoids speaking tiny fragments like "Sure," in
    /// isolation when the planner is still thinking. Lower = faster
    /// first audio out. 8 chars is roughly "hmm, that" — enough for
    /// AVSpeechSynthesizer to begin meaningfully without sounding
    /// clipped.
    private let minimumChunkCharacterCount: Int = 8

    /// Timestamp of the moment the user committed to a query — typically
    /// PTT-release. Set externally via `markIntentCommitted()`. Used to
    /// log time-to-first-spoken-word (TTFSW), the headline latency
    /// metric this product is positioned on.
    private var intentCommittedAt: Date?
    private var hasLoggedTimeToFirstSpokenWord: Bool = false

    init(ttsClient: any BuddyTTSClient) {
        self.ttsClient = ttsClient
    }

    /// Called when a new voice turn begins. Clears the dispatch
    /// history so the next chunk starts a fresh queue.
    func resetForNewTurn() {
        alreadyDispatchedSafeText = ""
        intentCommittedAt = nil
        hasLoggedTimeToFirstSpokenWord = false
    }

    /// Mark the moment the user finished expressing intent (PTT
    /// release). The pipeline measures from this point to the first
    /// dispatched TTS utterance and logs it as time-to-first-spoken-
    /// word — the headline latency metric on the product positioning.
    func markIntentCommitted() {
        intentCommittedAt = Date()
        hasLoggedTimeToFirstSpokenWord = false
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
        if !allowShortFinalChunk && trimmedNewPortion.count < minimumChunkCharacterCount {
            return
        }

        do {
            try await ttsClient.speakText(trimmedNewPortion)
            alreadyDispatchedSafeText = speakableSafePrefix
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
