//
//  PaceMemoryIndexTests.swift
//  leanring-buddyTests
//
//  Pure unit tests for the unified memory index (Phase 1). Covers entry
//  CRUD, tombstone exclusion + purge, cosine ranking order, embedding
//  edge cases, and the JSON round-trip the store relies on. The module is
//  intentionally I/O-free, so every behavior is observable from its API.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceMemoryIndexTests {
    // MARK: - Helpers

    private func makeFixedDate(_ secondsSinceEpoch: TimeInterval) -> Date {
        return Date(timeIntervalSince1970: secondsSinceEpoch)
    }

    private func makeEntry(
        id: String,
        kind: PaceMemoryEntryKind = .conversationTurn,
        text: String = "text",
        structured: [String: String]? = nil,
        source: PaceRetrievalSource = .paceHistory,
        createdAt: Date,
        updatedAt: Date? = nil,
        embedding: [Float]? = nil,
        confidence: Double? = nil,
        topicTags: [String] = [],
        tombstonedAt: Date? = nil
    ) -> PaceMemoryEntry {
        PaceMemoryEntry(
            id: id,
            kind: kind,
            text: text,
            structured: structured,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt,
            embedding: embedding,
            confidence: confidence,
            topicTags: topicTags,
            tombstonedAt: tombstonedAt
        )
    }

    // MARK: - Upsert

    @Test func upsertInsertsNewEntry() async throws {
        let index = PaceMemoryIndex()
        let entry = makeEntry(id: "a", text: "hello", createdAt: makeFixedDate(1_000))
        index.upsert(entry)
        #expect(index.entry(id: "a") == entry)
        #expect(index.allEntries().count == 1)
    }

    @Test func upsertReplacesExistingEntryById() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "a", text: "first", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "a", text: "second", createdAt: makeFixedDate(1_000)))
        #expect(index.allEntries().count == 1)
        #expect(index.entry(id: "a")?.text == "second")
    }

    @Test func replaceEntriesForSourceSwapsOnlyThatSource() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "cal-1", source: .calendar, createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "cal-2", source: .calendar, createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "mail-1", source: .mail, createdAt: makeFixedDate(1_000)))

        index.replaceEntries(
            forSource: .calendar,
            with: [makeEntry(id: "cal-3", source: .calendar, createdAt: makeFixedDate(2_000))]
        )

        // The calendar source is fully swapped; the mail source is untouched.
        #expect(index.entry(id: "cal-1") == nil)
        #expect(index.entry(id: "cal-2") == nil)
        #expect(index.entry(id: "cal-3") != nil)
        #expect(index.entry(id: "mail-1") != nil)
        #expect(Set(index.allEntries().map(\.id)) == ["cal-3", "mail-1"])
    }

    // MARK: - Tombstone

    @Test func tombstoneExcludesFromActiveButKeepsInAllEntries() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "a", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "b", createdAt: makeFixedDate(2_000)))

        index.tombstone(id: "a", now: makeFixedDate(3_000))

        #expect(index.activeEntries().map(\.id) == ["b"])
        #expect(index.allEntries().map(\.id) == ["a", "b"])
        #expect(index.entry(id: "a")?.isActive == false)
        #expect(index.entry(id: "a")?.tombstonedAt == makeFixedDate(3_000))
    }

    // MARK: - Purge

    @Test func purgeRemovesOldTombstonesAndKeepsRecentOnes() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "old", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "recent", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "active", createdAt: makeFixedDate(1_000)))

        let now = makeFixedDate(100_000)
        let thirtyDays: TimeInterval = 30 * 24 * 60 * 60
        // "old" was tombstoned 40 days ago → purged.
        index.tombstone(id: "old", now: now.addingTimeInterval(-40 * 24 * 60 * 60))
        // "recent" was tombstoned 5 days ago → kept.
        index.tombstone(id: "recent", now: now.addingTimeInterval(-5 * 24 * 60 * 60))

        index.purgeTombstonesOlderThan(thirtyDays, now: now)

        #expect(index.entry(id: "old") == nil)
        #expect(index.entry(id: "recent") != nil)
        #expect(index.entry(id: "active") != nil)
        #expect(index.allEntries().map(\.id) == ["active", "recent"])
    }

    // MARK: - Semantic ranking

    @Test func rankBySemanticSimilarityReturnsEntriesInCosineOrder() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "x-axis", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.upsert(makeEntry(id: "y-axis", createdAt: makeFixedDate(1_000), embedding: [0, 1]))
        index.upsert(makeEntry(id: "near-x", createdAt: makeFixedDate(1_000), embedding: [0.9, 0.1]))

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 3)

        // Query [1,0] is closest to [1,0], then [0.9,0.1], then [0,1].
        #expect(ranked.map(\.id) == ["x-axis", "near-x", "y-axis"])
    }

    @Test func rankRespectsTopNLimit() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "x-axis", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.upsert(makeEntry(id: "near-x", createdAt: makeFixedDate(1_000), embedding: [0.9, 0.1]))
        index.upsert(makeEntry(id: "y-axis", createdAt: makeFixedDate(1_000), embedding: [0, 1]))

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 2)

        #expect(ranked.map(\.id) == ["x-axis", "near-x"])
    }

    @Test func rankExcludesEntriesWithoutEmbedding() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "embedded", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.upsert(makeEntry(id: "no-embedding", createdAt: makeFixedDate(1_000), embedding: nil))

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 10)

        #expect(ranked.map(\.id) == ["embedded"])
    }

    @Test func rankExcludesTombstonedEntries() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "active", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.upsert(makeEntry(id: "deleted", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.tombstone(id: "deleted", now: makeFixedDate(2_000))

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 10)

        #expect(ranked.map(\.id) == ["active"])
    }

    @Test func rankSkipsDimensionMismatchedEntriesWithoutCrashing() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "matching", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.upsert(makeEntry(id: "mismatched", createdAt: makeFixedDate(1_000), embedding: [1, 0, 0, 0]))

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 10)

        #expect(ranked.map(\.id) == ["matching"])
    }

    @Test func rankHandlesZeroVectorEntryGracefully() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "strong", createdAt: makeFixedDate(1_000), embedding: [1, 0]))
        index.upsert(makeEntry(id: "zero", createdAt: makeFixedDate(1_000), embedding: [0, 0]))

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 10)

        // Zero-vector entry scores 0 (not a crash) and ranks last.
        #expect(ranked.map(\.id) == ["strong", "zero"])
    }

    // MARK: - Keyword (BM25) ranking

    @Test func rankByKeywordRanksEntriesContainingQueryTermsAboveThoseWithout() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(
            id: "match",
            text: "my preferred browser is Firefox",
            createdAt: makeFixedDate(1_000)
        ))
        index.upsert(makeEntry(
            id: "partial",
            text: "Firefox tabs are nice",
            createdAt: makeFixedDate(1_000)
        ))
        index.upsert(makeEntry(
            id: "irrelevant",
            text: "the weather is cold today",
            createdAt: makeFixedDate(1_000)
        ))

        let ranked = index.rankByKeywordSimilarity(toQuery: "preferred browser firefox", topN: 10)

        // The full-term match ranks first, the single-term match second, and
        // the zero-overlap entry is excluded entirely.
        #expect(ranked.map(\.id) == ["match", "partial"])
    }

    @Test func rankByKeywordExcludesEntriesWithZeroOverlap() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "match", text: "remember my dentist appointment", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "no-overlap", text: "completely unrelated note", createdAt: makeFixedDate(1_000)))

        let ranked = index.rankByKeywordSimilarity(toQuery: "dentist", topN: 10)

        #expect(ranked.map(\.id) == ["match"])
    }

    @Test func rankByKeywordFavorsRarerTermsWithHigherIDF() async throws {
        let index = PaceMemoryIndex()
        // "the" appears in every document (common, low IDF); "quokka" appears
        // in only one (rare, high IDF). The entry matching the rare term
        // should outrank the entry matching only the common term.
        index.upsert(makeEntry(id: "rare-term", text: "the quokka", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "common-only-1", text: "the meeting", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "common-only-2", text: "the report", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "common-only-3", text: "the schedule", createdAt: makeFixedDate(1_000)))

        let ranked = index.rankByKeywordSimilarity(toQuery: "the quokka", topN: 1)

        #expect(ranked.map(\.id) == ["rare-term"])
    }

    @Test func rankByKeywordReturnsEmptyForBlankQuery() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "a", text: "anything at all", createdAt: makeFixedDate(1_000)))

        #expect(index.rankByKeywordSimilarity(toQuery: "", topN: 10).isEmpty)
        #expect(index.rankByKeywordSimilarity(toQuery: "   \n\t ", topN: 10).isEmpty)
    }

    @Test func rankByKeywordReturnsEmptyForNonPositiveTopN() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "a", text: "matching token", createdAt: makeFixedDate(1_000)))

        #expect(index.rankByKeywordSimilarity(toQuery: "matching", topN: 0).isEmpty)
        #expect(index.rankByKeywordSimilarity(toQuery: "matching", topN: -3).isEmpty)
    }

    @Test func rankByKeywordRespectsTopNLimit() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "a", text: "shared keyword alpha", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "b", text: "shared keyword bravo", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "c", text: "shared keyword charlie", createdAt: makeFixedDate(1_000)))

        let ranked = index.rankByKeywordSimilarity(toQuery: "shared keyword", topN: 2)

        #expect(ranked.count == 2)
    }

    @Test func rankByKeywordBreaksTiesByIdAscending() async throws {
        let index = PaceMemoryIndex()
        // Identical text → identical BM25 score → tie broken by id ascending.
        index.upsert(makeEntry(id: "zebra", text: "identical matching text", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "alpha", text: "identical matching text", createdAt: makeFixedDate(2_000)))
        index.upsert(makeEntry(id: "mango", text: "identical matching text", createdAt: makeFixedDate(3_000)))

        let ranked = index.rankByKeywordSimilarity(toQuery: "identical matching text", topN: 10)

        #expect(ranked.map(\.id) == ["alpha", "mango", "zebra"])
    }

    @Test func rankByKeywordExcludesTombstonedEntries() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "active", text: "shared keyword", createdAt: makeFixedDate(1_000)))
        index.upsert(makeEntry(id: "deleted", text: "shared keyword", createdAt: makeFixedDate(1_000)))
        index.tombstone(id: "deleted", now: makeFixedDate(2_000))

        let ranked = index.rankByKeywordSimilarity(toQuery: "shared keyword", topN: 10)

        #expect(ranked.map(\.id) == ["active"])
    }

    // MARK: - Embedding mutation

    @Test func setEmbeddingThenRankIncludesNewlyEmbeddedEntry() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "lazy", createdAt: makeFixedDate(1_000), embedding: nil))

        index.setEmbedding([1, 0], forEntryId: "lazy")

        let ranked = index.rankBySemanticSimilarity(toQueryEmbedding: [1, 0], topN: 10)
        #expect(ranked.map(\.id) == ["lazy"])
        #expect(index.entry(id: "lazy")?.embedding == [1, 0])
    }

    // MARK: - Replace all

    @Test func replaceAllSwapsTheEntireIndex() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "stale", createdAt: makeFixedDate(1_000)))

        index.replaceAll([
            makeEntry(id: "loaded-1", createdAt: makeFixedDate(2_000)),
            makeEntry(id: "loaded-2", createdAt: makeFixedDate(3_000)),
        ])

        #expect(index.entry(id: "stale") == nil)
        #expect(index.allEntries().map(\.id) == ["loaded-1", "loaded-2"])
    }

    // MARK: - JSON round-trip (matches the store's date strategy)

    @Test func entriesRoundTripThroughJSON() async throws {
        let entries = [
            makeEntry(
                id: "turn-1",
                kind: .conversationTurn,
                text: "remember my preferred browser is Firefox",
                source: .paceHistory,
                createdAt: makeFixedDate(4_000)
            ),
            makeEntry(
                id: "fact-1",
                kind: .fact,
                text: "my mom is in the hospital",
                structured: ["subject": "mom", "predicate": "location", "value": "hospital"],
                source: .episodicMemory,
                createdAt: makeFixedDate(5_000),
                updatedAt: makeFixedDate(5_500),
                embedding: [0.1, 0.2, 0.3],
                confidence: 0.8,
                topicTags: ["#health", "#relationship"],
                tombstonedAt: makeFixedDate(6_000)
            ),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(entries)
        let decoded = try decoder.decode([PaceMemoryEntry].self, from: encoded)

        #expect(decoded == entries)
    }
}
