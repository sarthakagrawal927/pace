//
//  PaceSpotlightMemoryIndexerTests.swift
//  leanring-buddyTests
//
//  Pure mapping tests for the Spotlight memory mirror. The CoreSpotlight
//  index call itself can't be unit-tested cleanly (requires a real
//  CSSearchableIndex backing store and process-level entitlements);
//  these tests pin the pure entry → CSSearchableItem mapping rules
//  so the mirror can't silently start indexing the wrong fields.
//

import CoreSpotlight
import Foundation
import Testing
@testable import Pace

struct PaceSpotlightMemoryIndexerTests {

    @Test func builtItemHasEntryIDAsUniqueIdentifier() async throws {
        let entry = makeEntry(id: "mem-001", text: "remembered something")
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        #expect(item.uniqueIdentifier == "mem-001")
        #expect(item.domainIdentifier == "com.pace.app.memory")
    }

    @Test func builtItemTitleIsBoundedPrefixOfText() async throws {
        // Long text would otherwise push every other column off the
        // Spotlight result row. Verify the bound holds.
        let veryLongText = String(repeating: "a", count: 200)
        let entry = makeEntry(id: "mem-002", text: veryLongText)
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        #expect(item.attributeSet.title?.count == 60)
    }

    @Test func builtItemContentDescriptionIsFullText() async throws {
        let entry = makeEntry(
            id: "mem-003",
            text: "user prefers Firefox as their default browser"
        )
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        #expect(item.attributeSet.contentDescription == entry.text)
    }

    @Test func builtItemKeywordsIncludePaceTokenAndKindAndTopicTags() async throws {
        let entry = makeEntry(
            id: "mem-004",
            text: "the team finalised the spec on march 5th",
            kind: .fact,
            topicTags: ["product", "spec"]
        )
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        let keywords = item.attributeSet.keywords ?? []
        #expect(keywords.contains("pace"))
        #expect(keywords.contains("fact"))
        #expect(keywords.contains("product"))
        #expect(keywords.contains("spec"))
    }

    @Test func mappingDropsEntriesWithEmptyText() async throws {
        // Spotlight would otherwise render a blank result row.
        let blankEntry = makeEntry(id: "mem-005", text: "")
        let whitespaceEntry = makeEntry(id: "mem-006", text: "   \n\t  ")
        #expect(
            PaceSpotlightMemoryIndexer.buildSearchableItem(
                forEntry: blankEntry,
                domainIdentifier: "com.pace.app.memory"
            ) == nil
        )
        #expect(
            PaceSpotlightMemoryIndexer.buildSearchableItem(
                forEntry: whitespaceEntry,
                domainIdentifier: "com.pace.app.memory"
            ) == nil
        )
    }

    @Test func bulkBuildSkipsTombstonedEntries() async throws {
        // Tombstoned entries are still in the persistence file (so we
        // honour the 30-day retention window for recovery), but they
        // must NOT show up in Spotlight.
        let active = makeEntry(id: "mem-007", text: "still around")
        var tombstoned = makeEntry(id: "mem-008", text: "deleted ages ago")
        tombstoned.tombstonedAt = Date()

        let items = PaceSpotlightMemoryIndexer.buildSearchableItems(
            fromActiveEntries: [active, tombstoned],
            domainIdentifier: "com.pace.app.memory"
        )
        #expect(items.count == 1)
        #expect(items.first?.uniqueIdentifier == "mem-007")
    }

    @Test func humanKindLabelIsStableAcrossKinds() async throws {
        // Pin the labels so a future kind rename doesn't silently
        // change what users see in the Spotlight result subject line.
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .conversationTurn) == "conversation")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .fact) == "fact")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .preference) == "preference")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .journalEvent) == "journal event")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .summary) == "summary")
    }

    // MARK: - Builders

    private func makeEntry(
        id: String,
        text: String,
        kind: PaceMemoryEntryKind = .conversationTurn,
        topicTags: [String] = []
    ) -> PaceMemoryEntry {
        PaceMemoryEntry(
            id: id,
            kind: kind,
            text: text,
            structured: nil,
            source: .paceHistory,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedding: nil,
            confidence: nil,
            topicTags: topicTags,
            tombstonedAt: nil
        )
    }
}
