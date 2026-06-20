//
//  CompanionManager+ConversationMemory.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  conversation turn recording, thread memory persistence, episodic fact extraction.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Conversation & thread memory

    func persistThreadMemorySnapshot() {
        guard isThreadMemoryEnabled else {
            threadMemoryStore.clear()
            return
        }
        threadMemoryStore.save(threadMemory.snapshot(now: Date()))
    }

    /// Rehydrate the prior conversation at launch. Called once from
    /// `start()`. Skips restore (and wipes the file) when the feature
    /// is disabled.
    func restorePersistedThreadMemoryIfEnabled() {
        guard isThreadMemoryEnabled else {
            threadMemoryStore.clear()
            return
        }
        guard let persistedSnapshot = threadMemoryStore.load() else { return }
        threadMemory.restore(from: persistedSnapshot)
        print("🧠 Thread memory restored: \(persistedSnapshot.verbatimWindow.count) verbatim turn(s), summary=\(persistedSnapshot.summary != nil)")
    }
    func recordConversationTurn(
        userTranscript: String,
        assistantResponse: String
    ) {
        // The committed user message is about to land in the chat transcript,
        // so retire the live in-progress speech bubble (no duplicate).
        liveSpeechDraft = ""
        // Same reasoning on the assistant side: the committed reply is about
        // to land, so retire the live streamed-reply row or the panel shows
        // the reply twice (streaming row + committed row). This LOCKS the row
        // retired for the rest of the turn, so the final flushFinal dispatch
        // and any late stream chunk can't re-populate it.
        streamingSentenceTTSPipeline.finalizeInFlightStreamedTextForTurn()
        let recordedAt = Date()
        let stableTurnId = "turn-\(Int(recordedAt.timeIntervalSince1970))-\(abs(userTranscript.hashValue))"

        // Push the turn into the verbatim window. If the window
        // overflowed, the displaced pair is what feeds the next
        // detached summarizer call.
        let displacedTurnPair = threadMemory.record(
            userTurn: userTranscript,
            assistantTurn: assistantResponse,
            turnId: stableTurnId,
            now: recordedAt
        )

        localRetriever.recordPaceHistory(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        )
        // Mirror the same turn into the in-window chat surface so the
        // Conversations tab stays aligned with the canonical
        // `paceHistory` write — voice turns appear in chat history,
        // and chat turns dedupe against the optimistic user row that
        // PaceChatSession.submitUserMessage already inserted.
        chatSession.appendCompletedTurn(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse,
            recordedAt: recordedAt
        )
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        // 1. Fast pattern extractor — inline, sub-millisecond.
        let patternExtractedFacts = episodicPatternExtractor.extractFacts(
            from: userTranscript,
            assistantText: assistantResponse,
            frontmostApplicationName: frontmostAppName,
            sourceTurnId: stableTurnId
        )
        recordExtractedEpisodicFacts(patternExtractedFacts, turnId: stableTurnId)
        refreshLocalRetrievalPublishedState()

        // 2. LLM-backed extractor — DETACHED. Never awaited by the
        //    user-facing pipeline. Apple FM is in-process, ~0 RAM
        //    delta. LM Studio fallback is loopback-only. Either
        //    failure is silent — episodic memory is best-effort.
        scheduleDetachedEpisodicLLMExtractionCall(
            userTranscript: userTranscript,
            assistantSpokenText: assistantResponse,
            frontmostAppName: frontmostAppName,
            turnId: stableTurnId,
            intentRoute: lastIntentRouteForEpisodicExtraction
        )

        // Persist the conversation after every turn so it survives
        // quit/relaunch. Before the displaced-pair guard below, which
        // returns early on turns that didn't overflow the window.
        persistThreadMemorySnapshot()

        // Dual-write the turn into the unified memory index (ships dark).
        recordUnifiedMemoryTurn(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse,
            turnId: stableTurnId,
            recordedAt: recordedAt
        )

        guard let displacedTurnPair else { return }
        scheduleDetachedThreadSummarizationCall(
            displacedTurnPair: displacedTurnPair,
            recordedAt: recordedAt
        )
    }

    /// Mirrors the existing detached episodic-fact-extractor pattern:
    /// summarization is fire-and-forget on a utility-priority detached
    /// task. The user-facing planner turn NEVER awaits this. The
    /// version snapshot captured BEFORE the FM call lets
    /// `PaceThreadMemory.applySummaryUpdate` drop out-of-order arrivals
    /// when the user fires multiple turns faster than the summarizer
    /// completes.
    func scheduleDetachedThreadSummarizationCall(
        displacedTurnPair: PaceThreadTurnPair,
        recordedAt: Date
    ) {
        let priorSummaryForCall = threadMemory.currentSummaryText()
        let reservedSummaryVersion = threadMemory.reserveNextSummaryVersion()
        let summarizerInput = PaceThreadSummarizerInput(
            priorSummary: priorSummaryForCall,
            displacedTurnPair: displacedTurnPair,
            sessionStartedAt: recordedAt,
            frontmostApplicationName: NSWorkspace.shared.frontmostApplication?.localizedName
        )
        let summarizerForThisCall = threadSummarizerClient
        Task.detached(priority: .utility) { [weak self] in
            do {
                let updatedSummaryText = try await summarizerForThisCall.updatedSummary(
                    for: summarizerInput
                )
                await MainActor.run { [weak self] in
                    self?.threadMemory.applySummaryUpdate(
                        summary: updatedSummaryText,
                        summaryVersion: reservedSummaryVersion,
                        updatedAt: Date()
                    )
                    self?.persistThreadMemorySnapshot()
                }
            } catch {
                // Summarizer failure leaves the prior summary in
                // place. No retry storm — the next turn will trigger
                // a fresh call with the next displaced pair.
                print("⚠️ Thread summarizer call failed: \(error)")
            }
        }
    }

    /// Passes a batch of newly-extracted facts through the
    /// `PaceEpisodicFactStore` (dedup + tombstone gates + 200-fact
    /// LRU cap) and writes the surviving documents into the local
    /// retrieval index. Confidence threshold ≥0.7 is applied here so
    /// callers don't have to.
    func recordExtractedEpisodicFacts(
        _ rawFacts: [PaceEpisodicFact],
        turnId: String
    ) {
        let highConfidenceFacts = rawFacts.filter { $0.confidence >= 0.7 }
        guard !highConfidenceFacts.isEmpty else { return }
        let appliedOutcomes = episodicFactStore.applyBatch(highConfidenceFacts)
        let survivingFacts = appliedOutcomes.compactMap { (fact, outcome) -> PaceEpisodicFact? in
            switch outcome {
            case .inserted, .replaced, .appended:
                return fact
            case .skippedBecauseOfTombstone:
                return nil
            }
        }
        // For replacements, drop the previous fact's retrieval doc
        // so the store never carries two `(subject, predicate)`
        // rows when the dedup policy said "replace".
        var replacedPreviousFactIds: [String] = []
        for (_, outcome) in appliedOutcomes {
            if case .replaced(let previousFactId) = outcome {
                localRetriever.removeEpisodicFactDocument(withId: previousFactId)
                replacedPreviousFactIds.append(previousFactId)
            }
        }
        if !survivingFacts.isEmpty {
            localRetriever.recordEpisodicFacts(survivingFacts)
        }
        // Dual-write the same facts into the unified memory index (ships dark).
        upsertUnifiedMemoryFacts(
            survivingFacts,
            replacedPreviousFactIds: replacedPreviousFactIds
        )
    }

    /// Fires the LLM-backed episodic extractor on a DETACHED utility
    /// task. The user-facing TTS/planner pipeline NEVER awaits this.
    /// Apple FM is in-process and adds ~0 RAM delta; LM Studio is
    /// loopback-only via `PaceLocalEndpointGuard`. Per the PRD only
    /// `.pureKnowledge | .screenDescription | .chitchat` turns are
    /// extracted from — `.screenAction` and `.phoneLargeModel` turns
    /// are commands, not durable facts.
    func scheduleDetachedEpisodicLLMExtractionCall(
        userTranscript: String,
        assistantSpokenText: String,
        frontmostAppName: String?,
        turnId: String,
        intentRoute: PaceIntent
    ) {
        let intentIsEligibleForExtraction: Bool
        switch intentRoute {
        case .pureKnowledge, .screenDescription, .chitchat, .unknown, .research:
            // `.unknown` runs the full pipeline anyway; we let it
            // through so an unclassified turn doesn't silently drop
            // an extractable fact. Research turns are knowledge-style
            // so their summarized output is fact-extractable too.
            intentIsEligibleForExtraction = true
        case .screenAction, .phoneLargeModel:
            intentIsEligibleForExtraction = false
        }
        guard intentIsEligibleForExtraction else { return }
        let extractorForThisCall = episodicLLMFactExtractor
        Task.detached(priority: .utility) { [weak self] in
            let extractedFacts = await extractorForThisCall.extract(
                userTranscript: userTranscript,
                assistantSpokenText: assistantSpokenText,
                frontmostAppName: frontmostAppName,
                turnId: turnId
            )
            guard !extractedFacts.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.recordExtractedEpisodicFacts(extractedFacts, turnId: turnId)
                self?.refreshLocalRetrievalPublishedState()
            }
        }
    }

    /// User-facing API for Settings → Memory → Delete fact. Adds a
    /// 30-day tombstone (via `PaceEpisodicFactStore`) AND removes
    /// the retrieval document so the LOCAL CONTEXT block stops
    /// showing the fact immediately.
    func deleteEpisodicFact(withIdentifier factId: String) {
        guard let _ = episodicFactStore.deleteFact(withIdentifier: factId) else { return }
        localRetriever.removeEpisodicFactDocument(withId: factId)
        // Cascade into the unified index so semantic recall also stops
        // surfacing the deleted fact (same id as the episodic identifier).
        tombstoneUnifiedMemoryEntry(id: factId)
        refreshLocalRetrievalPublishedState()
    }

    /// User-facing API for Settings → Memory → Reset all. Tombstones
    /// every currently-stored fact for 30 days and clears the
    /// retrieval bucket.
    func resetAllEpisodicMemory() {
        episodicFactStore.resetAll()
        localRetriever.clearDocuments(forSource: .episodicMemory)
        // Cascade into the unified index so semantic recall and the
        // episodic roster stay in lockstep after a reset.
        tombstoneAllUnifiedMemoryFacts()
        refreshLocalRetrievalPublishedState()
    }

    /// Drops state if the idle threshold elapsed AND journals one
    /// line into `paceHistory` so "what did we talk about earlier?"
    /// can recall via the existing keyword retriever. The summary
    /// text itself is NEVER journaled — only the session id and the
    /// lifecycle cause.
    func evaluateThreadIdleAndResetIfNeeded(now: Date) {
        guard let sessionEndCause = threadMemory.sessionDidIdle(now: now) else {
            return
        }
        let endingSessionId = threadMemory.currentSessionId
        threadMemory.resetSession(cause: sessionEndCause, now: now)
        // Mirror the now-empty live state to disk so a relaunch after an
        // idle-while-running reset starts fresh rather than resurrecting
        // the conversation the idle gate just decided to drop.
        persistThreadMemorySnapshot()
        // Lever #1 — drop the bundled-MLX session cache when the
        // idle gate clears the conversation, so the next turn
        // doesn't continue from the prior session's KV state.
        PaceMLXPlannerClient.invalidateSessionCache(reason: "thread idle reset")
        let causeDisplayName: String
        switch sessionEndCause {
        case .idleTimeout:
            causeDisplayName = "idleTimeout"
        case .userReset:
            causeDisplayName = "userReset"
        }
        localRetriever.recordPaceHistory(
            userTranscript: "session ended (cause: \(causeDisplayName))",
            assistantResponse: "session \(endingSessionId) ended",
            now: now
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Public surface for the Settings "Reset thread now" button.
    func resetThreadMemoryNow() {
        let now = Date()
        let endingSessionId = threadMemory.currentSessionId
        threadMemory.resetSession(cause: .userReset, now: now)
        // "Until I reset" — an explicit reset wipes the on-disk copy too,
        // so the conversation does not come back on the next launch.
        threadMemoryStore.clear()
        // Lever #1 — also drop the bundled-MLX KV cache so the next
        // turn rebuilds from the new (empty) conversation state.
        // Without this, the MLX session would still carry the prior
        // turns' KV state, defeating the user's explicit reset.
        PaceMLXPlannerClient.invalidateSessionCache(reason: "user reset thread memory")
        localRetriever.recordPaceHistory(
            userTranscript: "session ended (cause: userReset)",
            assistantResponse: "session \(endingSessionId) ended",
            now: now
        )
        refreshLocalRetrievalPublishedState()
    }

    /// Settings debug surface: returns the raw summary text + version
    /// counter so the user can audit what the planner is being told.
    func currentThreadMemorySummarySnapshot() -> (summaryText: String?, summaryVersion: Int) {
        return (
            summaryText: threadMemory.currentSummaryText(),
            summaryVersion: threadMemory.currentSummaryVersionValue()
        )
    }
}
