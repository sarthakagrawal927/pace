//
//  CompanionManager+UnifiedMemoryDualWrite.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A4):
//  unified memory Phase 2 dual-write helpers (restore, persist, turn/fact
//  upsert, lazy embedding scheduling). Index/store collaborators remain in
//  the main file — Swift extensions cannot hold stored properties.
//

import Foundation

@MainActor
extension CompanionManager {

    func restoreUnifiedMemory() {
        memoryIndex.replaceAll(memoryStore.load())
        memoryIndex.purgeTombstonesOlderThan(
            PaceEpisodicTombstone.retentionInterval,
            now: Date()
        )
    }

    /// Persist the whole index. Best-effort; the file is small for one
    /// user and the store swallows any write failure. Also mirrors the
    /// active subset into CoreSpotlight on every save so the system
    /// search index stays consistent with what's actually persisted.
    func persistUnifiedMemory() {
        let allEntries = memoryIndex.allEntries()
        memoryStore.save(allEntries)
        spotlightMemoryIndexer.syncMirror(toMatch: allEntries)
    }

    /// Dual-write a completed conversation turn into the unified index.
    /// Mirrors the `paceHistory` write — same combined "User: …\nPace: …"
    /// surface form — so recall can later rank turns semantically.
    func recordUnifiedMemoryTurn(
        userTranscript: String,
        assistantResponse: String,
        turnId: String,
        recordedAt: Date
    ) {
        let combinedTurnText = "User: \(userTranscript)\nPace: \(assistantResponse)"
        // Extract structured entities at write time (NLTagger named
        // entities + NSDataDetector typed contacts/dates) so the
        // recall side can match deterministically on people, places,
        // organizations, phones, emails, urls, and dates — without
        // re-tokenising the same string on every voice turn.
        let structuredFields = PaceMemoryEntryEnricher.extractStructuredFields(
            fromEntryText: combinedTurnText
        )
        memoryIndex.upsert(
            PaceMemoryEntry(
                id: turnId,
                kind: .conversationTurn,
                text: combinedTurnText,
                structured: structuredFields,
                source: .paceHistory,
                createdAt: recordedAt,
                updatedAt: recordedAt,
                embedding: nil,
                confidence: nil,
                topicTags: [],
                tombstonedAt: nil
            )
        )
        persistUnifiedMemory()
        scheduleLazyEmbedding([(id: turnId, text: combinedTurnText)])
    }

    /// Dual-write extracted durable facts into the unified index, and
    /// tombstone any fact a dedup `.replaced` outcome superseded so the
    /// stale value can't be recalled. Mirrors the episodic store.
    func upsertUnifiedMemoryFacts(
        _ facts: [PaceEpisodicFact],
        replacedPreviousFactIds: [String]
    ) {
        let now = Date()
        for previousFactId in replacedPreviousFactIds {
            memoryIndex.tombstone(id: previousFactId, now: now)
        }
        var entryIdsAndTextsToEmbed: [(id: String, text: String)] = []
        for fact in facts {
            let factText = "\(fact.subject) \(fact.predicate) \(fact.value)"
            memoryIndex.upsert(
                PaceMemoryEntry(
                    id: fact.identifier,
                    kind: .fact,
                    text: factText,
                    structured: [
                        "subject": fact.subject,
                        "predicate": fact.predicate,
                        "value": fact.value
                    ],
                    source: .episodicMemory,
                    createdAt: fact.extractedAt,
                    updatedAt: fact.extractedAt,
                    embedding: nil,
                    confidence: fact.confidence,
                    topicTags: fact.topicHashtags,
                    tombstonedAt: nil
                )
            )
            entryIdsAndTextsToEmbed.append((id: fact.identifier, text: factText))
        }
        persistUnifiedMemory()
        scheduleLazyEmbedding(entryIdsAndTextsToEmbed)
    }

    func scheduleLazyEmbedding(_ entryIdsAndTexts: [(id: String, text: String)]) {
        lazyEmbeddingScheduler.schedule(entryIdsAndTexts)
    }
}
