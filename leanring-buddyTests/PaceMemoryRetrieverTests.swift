//
//  PaceMemoryRetrieverTests.swift
//  leanring-buddyTests
//
//  Unit tests for the Phase 3 recall pass (PaceMemoryRetriever). A stub
//  embedding client gives the tests full control over the cosine ranking,
//  so the async assembly path and the two pure helpers are both observable
//  without a live embedding endpoint.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceMemoryRetrieverTests {
    // MARK: - Stub embedding client

    /// Returns a caller-controlled vector per input. In `throwingMode` it
    /// fails so the retriever's best-effort nil fallback can be exercised.
    private final class StubEmbeddingClient: PaceTextEmbedding {
        var vectorToReturnForQuery: [Float]
        var throwingMode: Bool

        init(vectorToReturnForQuery: [Float], throwingMode: Bool = false) {
            self.vectorToReturnForQuery = vectorToReturnForQuery
            self.throwingMode = throwingMode
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            if throwingMode {
                throw PaceEmbeddingClientError(message: "stub failure")
            }
            return texts.map { _ in vectorToReturnForQuery }
        }
    }

    // MARK: - Helpers

    private func makeFixedDate(_ secondsSinceEpoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: secondsSinceEpoch)
    }

    private func makeEntry(
        id: String,
        kind: PaceMemoryEntryKind = .conversationTurn,
        text: String = "text",
        embedding: [Float]? = nil,
        topicTags: [String] = []
    ) -> PaceMemoryEntry {
        PaceMemoryEntry(
            id: id,
            kind: kind,
            text: text,
            structured: nil,
            source: .paceHistory,
            createdAt: makeFixedDate(1_000),
            updatedAt: makeFixedDate(1_000),
            embedding: embedding,
            confidence: nil,
            topicTags: topicTags,
            tombstonedAt: nil
        )
    }

    private func makeRetriever(
        index: PaceMemoryIndex,
        embeddingClient: any PaceTextEmbedding,
        shouldInjectSensitiveTopics: @escaping () -> Bool = { false }
    ) -> PaceMemoryRetriever {
        PaceMemoryRetriever(
            memoryIndex: index,
            embeddingClient: embeddingClient,
            shouldInjectSensitiveTopics: shouldInjectSensitiveTopics
        )
    }

    // MARK: - assembleContextBlock

    @Test func assembleReturnsBlockContainingHighestCosineEntry() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "close", text: "my mom is in the hospital", embedding: [1, 0]))
        index.upsert(makeEntry(id: "far", text: "the weather is nice", embedding: [0, 1]))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0])
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "how is my mother doing?",
            excludingEntryIds: [],
            maxEntries: 1,
            now: makeFixedDate(2_000)
        )

        let unwrappedBlock = try #require(block)
        #expect(unwrappedBlock.contains("my mom is in the hospital"))
        #expect(!unwrappedBlock.contains("the weather is nice"))
    }

    @Test func assembleNeverIncludesExcludedEntryIds() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "excluded", text: "excluded turn", embedding: [1, 0]))
        index.upsert(makeEntry(id: "kept", text: "kept turn", embedding: [0.9, 0.1]))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0])
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "anything",
            excludingEntryIds: ["excluded"],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        let unwrappedBlock = try #require(block)
        #expect(!unwrappedBlock.contains("excluded turn"))
        #expect(unwrappedBlock.contains("kept turn"))
    }

    @Test func assembleExcludesSensitiveEntryWhenOptOut() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(
            id: "sensitive",
            kind: .fact,
            text: "user's mom is in the hospital",
            embedding: [1, 0],
            topicTags: ["#health"]
        ))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0]),
            shouldInjectSensitiveTopics: { false }
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "anything",
            excludingEntryIds: [],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        // Only a sensitive entry exists and injection is off → nothing survives.
        #expect(block == nil)
    }

    @Test func assembleIncludesSensitiveEntryWhenOptIn() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(
            id: "sensitive",
            kind: .fact,
            text: "user's mom is in the hospital",
            embedding: [1, 0],
            topicTags: ["#health"]
        ))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0]),
            shouldInjectSensitiveTopics: { true }
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "anything",
            excludingEntryIds: [],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        let unwrappedBlock = try #require(block)
        #expect(unwrappedBlock.contains("user's mom is in the hospital"))
    }

    @Test func assembleReturnsNilForWhitespaceQuery() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "any", embedding: [1, 0]))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0])
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "   \n\t ",
            excludingEntryIds: [],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        #expect(block == nil)
    }

    @Test func assembleFallsBackToLexicalBlockWhenEmbeddingThrows() async throws {
        let index = PaceMemoryIndex()
        // No embeddings — the entry is only reachable by keyword.
        index.upsert(makeEntry(id: "browser", text: "my preferred browser is Firefox"))
        index.upsert(makeEntry(id: "weather", text: "the weather is nice"))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0], throwingMode: true)
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "what is my preferred browser?",
            excludingEntryIds: [],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        // Previously this returned nil; the lexical fallback now surfaces the
        // keyword-matching entry over the SAME unified index.
        let unwrappedBlock = try #require(block)
        #expect(unwrappedBlock.contains("my preferred browser is Firefox"))
        #expect(!unwrappedBlock.contains("the weather is nice"))
    }

    @Test func assembleReturnsNilWhenEmbeddingThrowsAndQueryMatchesNothing() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "browser", text: "my preferred browser is Firefox"))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0], throwingMode: true)
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "completely unrelated quokka topic",
            excludingEntryIds: [],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        // No semantic vector and no keyword overlap → nothing to inject.
        #expect(block == nil)
    }

    @Test func assembleLexicalFallbackStillExcludesIdsAndSensitiveEntries() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "excluded", text: "shared keyword excluded turn"))
        index.upsert(makeEntry(
            id: "sensitive",
            kind: .fact,
            text: "shared keyword mom hospital",
            topicTags: ["#health"]
        ))
        index.upsert(makeEntry(id: "kept", text: "shared keyword kept turn"))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0], throwingMode: true),
            shouldInjectSensitiveTopics: { false }
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "shared keyword",
            excludingEntryIds: ["excluded"],
            maxEntries: 5,
            now: makeFixedDate(2_000)
        )

        let unwrappedBlock = try #require(block)
        #expect(unwrappedBlock.contains("shared keyword kept turn"))
        #expect(!unwrappedBlock.contains("shared keyword excluded turn"))
        #expect(!unwrappedBlock.contains("shared keyword mom hospital"))
    }

    @Test func assembleSemanticPathUnchangedWhenEmbeddingReturnsVectors() async throws {
        let index = PaceMemoryIndex()
        // The semantic-matching entry has NO keyword overlap with the query,
        // proving the block came from the cosine path, not the lexical one.
        index.upsert(makeEntry(id: "close", text: "alpha bravo charlie", embedding: [1, 0]))
        index.upsert(makeEntry(id: "far", text: "delta echo foxtrot", embedding: [0, 1]))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0])
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "no shared tokens whatsoever",
            excludingEntryIds: [],
            maxEntries: 1,
            now: makeFixedDate(2_000)
        )

        let unwrappedBlock = try #require(block)
        #expect(unwrappedBlock.contains("alpha bravo charlie"))
        #expect(!unwrappedBlock.contains("delta echo foxtrot"))
    }

    @Test func assembleCapsRenderedEntryLinesAtMaxEntries() async throws {
        let index = PaceMemoryIndex()
        index.upsert(makeEntry(id: "a", text: "alpha", embedding: [1, 0]))
        index.upsert(makeEntry(id: "b", text: "bravo", embedding: [0.9, 0.1]))
        index.upsert(makeEntry(id: "c", text: "charlie", embedding: [0.8, 0.2]))
        index.upsert(makeEntry(id: "d", text: "delta", embedding: [0.7, 0.3]))

        let retriever = makeRetriever(
            index: index,
            embeddingClient: StubEmbeddingClient(vectorToReturnForQuery: [1, 0])
        )

        let block = await retriever.assembleContextBlock(
            forQuery: "anything",
            excludingEntryIds: [],
            maxEntries: 2,
            now: makeFixedDate(2_000)
        )

        let unwrappedBlock = try #require(block)
        let entryLines = unwrappedBlock
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("- ") }
        #expect(entryLines.count == 2)
    }

    // MARK: - isEntrySensitive (pure)

    @Test func isEntrySensitiveTrueForSensitiveTag() async throws {
        let entry = makeEntry(id: "x", topicTags: ["#work", "#finance"])
        #expect(PaceMemoryRetriever.isEntrySensitive(entry))
    }

    @Test func isEntrySensitiveIsCaseInsensitive() async throws {
        let entry = makeEntry(id: "x", topicTags: ["#Health"])
        #expect(PaceMemoryRetriever.isEntrySensitive(entry))
    }

    @Test func isEntrySensitiveFalseForNonSensitiveTags() async throws {
        let entry = makeEntry(id: "x", topicTags: ["#work", "#preference"])
        #expect(!PaceMemoryRetriever.isEntrySensitive(entry))
    }

    @Test func isEntrySensitiveFalseForNoTags() async throws {
        let entry = makeEntry(id: "x", topicTags: [])
        #expect(!PaceMemoryRetriever.isEntrySensitive(entry))
    }

    // MARK: - formatContextBlock (pure)

    @Test func formatContextBlockHasHeaderAndOneLinePerEntry() async throws {
        let entries = [
            makeEntry(id: "a", kind: .fact, text: "user prefers Firefox"),
            makeEntry(id: "b", kind: .preference, text: "default reminder list is Work"),
        ]

        let block = PaceMemoryRetriever.formatContextBlock(from: entries, now: makeFixedDate(2_000))
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.first == "LOCAL CONTEXT (memory)")
        let entryLines = lines.filter { $0.hasPrefix("- ") }
        #expect(entryLines.count == 2)
        #expect(block.contains("- user prefers Firefox"))
        #expect(block.contains("- default reminder list is Work"))
    }

    @Test func formatContextBlockCollapsesConversationTurnNewlines() async throws {
        let entries = [
            makeEntry(id: "a", kind: .conversationTurn, text: "user: hello\nassistant: hi there"),
        ]

        let block = PaceMemoryRetriever.formatContextBlock(from: entries, now: makeFixedDate(2_000))

        // The conversation-turn entry must render on a single line: header
        // line plus exactly one entry line, with the embedded newline gone.
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(block.contains("user: hello / assistant: hi there"))
        #expect(!block.contains("assistant: hi there\n"))
    }
}
