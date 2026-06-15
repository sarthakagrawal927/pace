//
//  PaceMemoryRetriever.swift
//  leanring-buddy
//
//  The recall pass of the unified memory system (see
//  docs/prds/unified-memory.md, Phase 3). Embeds the user's query, ranks
//  the memory index by cosine similarity, applies exclusion + sensitive-
//  topic filtering, and assembles one compact LOCAL CONTEXT block for the
//  planner.
//
//  Best-effort: any embedding failure returns nil so the caller can fall
//  back to the existing lexical recall. Ships dark — nothing wires this in
//  yet.
//

import Foundation

@MainActor
final class PaceMemoryRetriever {
    private let memoryIndex: PaceMemoryIndex
    private let embeddingClient: any PaceTextEmbedding

    /// Live read of the user's sensitive-topic injection opt-in. Closure
    /// rather than a stored Bool so the retriever always reflects the
    /// current preference at recall time instead of a value captured at
    /// init.
    private let shouldInjectSensitiveTopics: () -> Bool

    init(
        memoryIndex: PaceMemoryIndex,
        embeddingClient: any PaceTextEmbedding,
        shouldInjectSensitiveTopics: @escaping () -> Bool
    ) {
        self.memoryIndex = memoryIndex
        self.embeddingClient = embeddingClient
        self.shouldInjectSensitiveTopics = shouldInjectSensitiveTopics
    }

    /// Assembles the recall context block for `query`, or nil when there is
    /// nothing to inject (empty query, or no surviving entries after
    /// filtering on either ranking path). Ranks the unified index
    /// semantically when an embedding is available, otherwise falls back to
    /// keyword/BM25 ranking over the SAME index — so an embedding failure no
    /// longer means "no memory," it just means "rank by keyword instead."
    /// `excludingEntryIds` lets the caller drop entries already shown
    /// elsewhere (e.g. the always-include verbatim window). `maxEntries` caps
    /// the rendered line count.
    func assembleContextBlock(
        forQuery query: String,
        excludingEntryIds: Set<String>,
        maxEntries: Int,
        now: Date
    ) async -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        guard maxEntries > 0 else { return nil }

        // Over-fetch so the post-rank filtering (exclusions + sensitive-topic
        // drops) still leaves up to `maxEntries` survivors.
        let overFetchCount = maxEntries + excludingEntryIds.count + 8

        // Semantic path first. Best-effort embedding: any failure or empty
        // vector falls through to the lexical ranker rather than blocking.
        let queryVectors = try? await embeddingClient.embed([trimmedQuery])
        if let queryVector = queryVectors?.first, !queryVector.isEmpty {
            let semanticallyRankedEntries = memoryIndex.rankBySemanticSimilarity(
                toQueryEmbedding: queryVector,
                topN: overFetchCount
            )
            if let semanticBlock = filteredContextBlock(
                fromRankedEntries: semanticallyRankedEntries,
                excludingEntryIds: excludingEntryIds,
                maxEntries: maxEntries,
                now: now
            ) {
                return semanticBlock
            }
        }

        // Lexical fallback over the SAME unified index when embeddings are
        // unavailable (or the semantic path yielded nothing after filtering).
        let keywordRankedEntries = memoryIndex.rankByKeywordSimilarity(
            toQuery: trimmedQuery,
            topN: overFetchCount
        )
        return filteredContextBlock(
            fromRankedEntries: keywordRankedEntries,
            excludingEntryIds: excludingEntryIds,
            maxEntries: maxEntries,
            now: now
        )
    }

    /// Shared tail for both ranking paths: drop excluded entries, drop
    /// sensitive entries unless the user opted in, cap at `maxEntries`, and
    /// format. Returns nil when nothing survives the filtering, so the caller
    /// can try the other ranking path (or ultimately return nil).
    private func filteredContextBlock(
        fromRankedEntries rankedEntries: [PaceMemoryEntry],
        excludingEntryIds: Set<String>,
        maxEntries: Int,
        now: Date
    ) -> String? {
        let injectSensitiveTopics = shouldInjectSensitiveTopics()
        var survivingEntries: [PaceMemoryEntry] = []
        for candidateEntry in rankedEntries {
            if excludingEntryIds.contains(candidateEntry.id) {
                continue
            }
            if Self.isEntrySensitive(candidateEntry) && !injectSensitiveTopics {
                continue
            }
            survivingEntries.append(candidateEntry)
            if survivingEntries.count >= maxEntries {
                break
            }
        }

        guard !survivingEntries.isEmpty else { return nil }
        return Self.formatContextBlock(from: survivingEntries, now: now)
    }

    // MARK: - Pure helpers

    /// True iff any of the entry's topic tags falls into the shared
    /// sensitive-topic set. Comparison is case-insensitive so a `#Health`
    /// tag matches `#health`. Reuses the canonical set from
    /// `PaceEpisodicSensitiveTopics` rather than redefining it.
    static func isEntrySensitive(_ entry: PaceMemoryEntry) -> Bool {
        let normalizedSensitiveTags = Set(
            PaceEpisodicSensitiveTopics.sensitiveTopicHashtags.map { $0.lowercased() }
        )
        let normalizedEntryTags = Set(entry.topicTags.map { $0.lowercased() })
        return !normalizedEntryTags.isDisjoint(with: normalizedSensitiveTags)
    }

    /// Renders the surviving entries into one compact, deterministic
    /// LOCAL CONTEXT block: a header line followed by one "- " line per
    /// entry. Conversation-turn text has newlines collapsed so each entry
    /// stays on a single line; all entries are capped so a runaway entry
    /// can't dominate the planner's context window.
    static func formatContextBlock(from entries: [PaceMemoryEntry], now: Date) -> String {
        let maximumRenderedCharacterCount = 180

        var lines: [String] = ["LOCAL CONTEXT (memory)"]
        for entry in entries {
            let renderedEntryText: String
            switch entry.kind {
            case .fact:
                // Facts are already stored as "subject predicate value" —
                // render verbatim so the triple reads naturally.
                renderedEntryText = trimmedSingleLine(entry.text)
            case .conversationTurn:
                renderedEntryText = singleLineSnippet(
                    entry.text,
                    maximumCharacterCount: maximumRenderedCharacterCount
                )
            case .preference, .journalEvent, .summary:
                renderedEntryText = cappedSingleLine(
                    entry.text,
                    maximumCharacterCount: maximumRenderedCharacterCount
                )
            }
            lines.append("- \(renderedEntryText)")
        }

        return lines.joined(separator: "\n")
    }

    /// Collapses newlines and runs of whitespace into single spaces and
    /// caps length — the conversation-turn snippet form.
    private static func singleLineSnippet(_ text: String, maximumCharacterCount: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " / ")
            .replacingOccurrences(of: "\n", with: " / ")
            .replacingOccurrences(of: "\r", with: " / ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cappedSingleLine(collapsed, maximumCharacterCount: maximumCharacterCount)
    }

    /// Trims surrounding whitespace and caps the string to the rendered
    /// length without adding trailing whitespace.
    private static func cappedSingleLine(_ text: String, maximumCharacterCount: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacterCount else { return trimmed }
        return String(trimmed.prefix(maximumCharacterCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedSingleLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
