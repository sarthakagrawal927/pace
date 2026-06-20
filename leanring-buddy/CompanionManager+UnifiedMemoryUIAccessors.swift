//
//  CompanionManager+UnifiedMemoryUIAccessors.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A4):
//  unified memory Phase 4 UI count accessors, tombstone cascades, and
//  connector resync into the unified index. Throttle state
//  (`lastUnifiedMemoryConnectorSyncAt`) stays in the main file.
//

import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Unified memory (Phase 4: UI accessors + cascade)

    func unifiedMemoryFactCount() -> Int {
        memoryIndex.activeEntries().filter { $0.kind == .fact }.count
    }

    /// Conversation turns currently indexed for semantic recall.
    func unifiedMemoryConversationCount() -> Int {
        memoryIndex.activeEntries().filter { $0.kind == .conversationTurn }.count
    }

    /// Cascade target: tombstone one unified entry so a fact deleted in the
    /// Memory view stops surfacing in semantic recall too. The unified fact
    /// entry shares its id with the episodic fact identifier.
    func tombstoneUnifiedMemoryEntry(id: String) {
        memoryIndex.tombstone(id: id, now: Date())
        persistUnifiedMemory()
    }

    /// Cascade target: tombstone every unified fact entry when the user
    /// resets episodic memory, so semantic recall and the episodic roster
    /// stay in lockstep. Conversation-turn entries are left intact.
    func tombstoneAllUnifiedMemoryFacts() {
        let now = Date()
        for factEntry in memoryIndex.activeEntries() where factEntry.kind == .fact {
            memoryIndex.tombstone(id: factEntry.id, now: now)
        }
        persistUnifiedMemory()
    }

    /// Phase 5 step 2: pull every connector source's current retrieval
    /// documents into the unified index as `.journalEvent` / `.preference`
    /// producers, making the index a superset of the lexical store. `.paceHistory`
    /// and `.episodicMemory` are skipped — Phase 2 already dual-writes those with
    /// richer typing. Read-only against the retriever; idempotent per source via
    /// `replaceEntries`. Embeddings are preserved across resyncs when an entry's
    /// text is unchanged, and scheduled only for new/changed entries so a resync
    /// doesn't re-embed the whole corpus.
    func syncConnectorsIntoUnifiedMemory() {
        let now = Date()
        var entryIdsAndTextsToEmbed: [(id: String, text: String)] = []
        for source in PaceRetrievalSource.allCases
        where source != .paceHistory && source != .episodicMemory {
            let documents = localRetriever.documents(forSource: source)
            let entries: [PaceMemoryEntry] = documents.map { document in
                let existingEntry = memoryIndex.entry(id: document.id)
                let textIsUnchanged = existingEntry?.text == document.text
                let preservedEmbedding = textIsUnchanged ? existingEntry?.embedding : nil
                if preservedEmbedding == nil {
                    entryIdsAndTextsToEmbed.append((id: document.id, text: document.text))
                }
                return PaceMemoryEntry(
                    id: document.id,
                    kind: source == .localPreference ? .preference : .journalEvent,
                    text: document.text,
                    structured: nil,
                    source: source,
                    createdAt: existingEntry?.createdAt ?? document.modifiedAt ?? now,
                    updatedAt: document.modifiedAt ?? now,
                    embedding: preservedEmbedding,
                    confidence: nil,
                    topicTags: [],
                    tombstonedAt: nil
                )
            }
            memoryIndex.replaceEntries(forSource: source, with: entries)
        }
        persistUnifiedMemory()
        scheduleLazyEmbedding(entryIdsAndTextsToEmbed)
    }

    /// Debounced entry point called from `refreshLocalRetrievalPublishedState()`
    /// after retrieval writes, so the unified index trails connector changes
    /// without re-mapping every source on every single write.
    func syncConnectorsIntoUnifiedMemoryIfDue(now: Date = Date()) {
        if let lastSyncAt = lastUnifiedMemoryConnectorSyncAt,
           now.timeIntervalSince(lastSyncAt) < Self.unifiedMemoryConnectorSyncMinimumInterval {
            return
        }
        lastUnifiedMemoryConnectorSyncAt = now
        syncConnectorsIntoUnifiedMemory()
    }
}
