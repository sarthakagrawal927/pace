//
//  PaceMemoryIndex.swift
//  leanring-buddy
//
//  In-memory CRUD + semantic ranking over the unified memory entry list
//  (see docs/prds/unified-memory.md, Phase 1). This type holds the live
//  list and answers recall queries with brute-force cosine similarity;
//  it never touches disk — persistence is `PaceMemoryStore`'s job.
//
//  Pure, deterministic logic. No app wiring yet. Ships dark.
//

import Foundation

@MainActor
final class PaceMemoryIndex {
    private var entriesById: [String: PaceMemoryEntry] = [:]

    init() {}

    func upsert(_ entry: PaceMemoryEntry) {
        entriesById[entry.id] = entry
    }

    func entry(id: String) -> PaceMemoryEntry? {
        entriesById[id]
    }

    /// Every entry the index holds, including tombstoned ones, ordered by
    /// creation date so the store and UI see a stable sequence.
    func allEntries() -> [PaceMemoryEntry] {
        entriesById.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id < rhs.id
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Entries that have not been soft-deleted — the recall and UI surface.
    func activeEntries() -> [PaceMemoryEntry] {
        allEntries().filter { $0.isActive }
    }

    /// Soft-delete: mark the entry tombstoned but keep it so recent deletes
    /// can be retained for the 30-day grace window before a hard purge.
    func tombstone(id: String, now: Date) {
        guard var existingEntry = entriesById[id] else { return }
        existingEntry.tombstonedAt = now
        existingEntry.updatedAt = now
        entriesById[id] = existingEntry
    }

    /// Hard-remove entries whose tombstone is older than `interval` ago.
    /// Callers pass 30 days to honor the PRD's tombstone retention window.
    func purgeTombstonesOlderThan(_ interval: TimeInterval, now: Date) {
        let cutoffDate = now.addingTimeInterval(-interval)
        entriesById = entriesById.filter { _, entry in
            guard let tombstonedAt = entry.tombstonedAt else {
                return true
            }
            return tombstonedAt > cutoffDate
        }
    }

    func setEmbedding(_ embedding: [Float], forEntryId id: String) {
        guard var existingEntry = entriesById[id] else { return }
        existingEntry.embedding = embedding
        entriesById[id] = existingEntry
    }

    /// Semantic recall: rank active, embedded entries by cosine similarity
    /// to the query vector, highest first, and return the top-N. Entries
    /// without an embedding, or whose embedding dimension does not match the
    /// query, are skipped rather than crashing. Deterministic: ties break by
    /// entry id so the order is stable across runs.
    func rankBySemanticSimilarity(toQueryEmbedding query: [Float], topN: Int) -> [PaceMemoryEntry] {
        guard topN > 0 else { return [] }

        var scoredEntries: [(entry: PaceMemoryEntry, similarity: Double)] = []
        for candidateEntry in activeEntries() {
            guard let candidateEmbedding = candidateEntry.embedding else {
                continue
            }
            guard candidateEmbedding.count == query.count else {
                continue
            }
            let similarity = cosineSimilarity(candidateEmbedding, query)
            scoredEntries.append((entry: candidateEntry, similarity: similarity))
        }

        let rankedEntries = scoredEntries.sorted { lhs, rhs in
            if lhs.similarity == rhs.similarity {
                return lhs.entry.id < rhs.entry.id
            }
            return lhs.similarity > rhs.similarity
        }

        return rankedEntries.prefix(topN).map { $0.entry }
    }

    /// Lexical recall: rank active entries by standard BM25 keyword
    /// relevance of `entry.text` to `query`, highest first, and return the
    /// top-N. This is the fallback ranking mode the unified retriever uses
    /// when embeddings are unavailable, so keyword recall runs over the SAME
    /// index as semantic recall rather than a separate store. Entries with no
    /// query-term overlap score 0 and are excluded. Deterministic: ties break
    /// by entry id ascending so the order is stable across runs. An empty or
    /// whitespace-only query, or `topN <= 0`, yields no results.
    func rankByKeywordSimilarity(toQuery query: String, topN: Int) -> [PaceMemoryEntry] {
        guard topN > 0 else { return [] }

        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        let candidateEntries = activeEntries()
        guard !candidateEntries.isEmpty else { return [] }

        let documentTokensByEntryId = Self.tokenizeDocuments(for: candidateEntries)
        let averageDocumentLength = Self.averageDocumentLength(of: documentTokensByEntryId)
        let inverseDocumentFrequencyByTerm = Self.inverseDocumentFrequencyByTerm(
            forQueryTokens: queryTokens,
            documentTokensByEntryId: documentTokensByEntryId
        )

        var scoredEntries: [(entry: PaceMemoryEntry, score: Double)] = []
        for candidateEntry in candidateEntries {
            let documentTokens = documentTokensByEntryId[candidateEntry.id] ?? []
            let score = Self.bm25Score(
                queryTokens: queryTokens,
                documentTokens: documentTokens,
                averageDocumentLength: averageDocumentLength,
                inverseDocumentFrequencyByTerm: inverseDocumentFrequencyByTerm
            )
            // Exclude entries with no query-term overlap so the fallback never
            // injects irrelevant memories just to fill the top-N.
            guard score > 0 else { continue }
            scoredEntries.append((entry: candidateEntry, score: score))
        }

        let rankedEntries = scoredEntries.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.entry.id < rhs.entry.id
            }
            return lhs.score > rhs.score
        }

        return rankedEntries.prefix(topN).map { $0.entry }
    }

    /// Replace the entire index in one shot — used at load time when the
    /// store hands back the persisted entry list.
    func replaceAll(_ entries: [PaceMemoryEntry]) {
        entriesById.removeAll(keepingCapacity: true)
        for entry in entries {
            entriesById[entry.id] = entry
        }
    }

    /// Replace every entry belonging to one source with a fresh set — the
    /// connector-resync primitive (Phase 5 step 2). Connector documents are
    /// not user-curated facts, so this HARD-removes the source's prior
    /// entries (no tombstone) before inserting the current ones, which makes
    /// a resync idempotent and naturally reflects connector adds/removes.
    func replaceEntries(forSource source: PaceRetrievalSource, with entries: [PaceMemoryEntry]) {
        for (entryId, existingEntry) in entriesById where existingEntry.source == source {
            entriesById[entryId] = nil
        }
        for entry in entries {
            entriesById[entry.id] = entry
        }
    }

    /// Cosine similarity between two equal-length vectors. Returns 0 when
    /// either vector is a zero vector, so a degenerate embedding ranks at
    /// the bottom instead of producing a divide-by-zero.
    private func cosineSimilarity(_ first: [Float], _ second: [Float]) -> Double {
        var dotProduct = 0.0
        var firstMagnitudeSquared = 0.0
        var secondMagnitudeSquared = 0.0
        for index in first.indices {
            let firstComponent = Double(first[index])
            let secondComponent = Double(second[index])
            dotProduct += firstComponent * secondComponent
            firstMagnitudeSquared += firstComponent * firstComponent
            secondMagnitudeSquared += secondComponent * secondComponent
        }
        let firstMagnitude = firstMagnitudeSquared.squareRoot()
        let secondMagnitude = secondMagnitudeSquared.squareRoot()
        guard firstMagnitude > 0, secondMagnitude > 0 else {
            return 0.0
        }
        return dotProduct / (firstMagnitude * secondMagnitude)
    }

    // MARK: - BM25 keyword ranking helpers

    /// Standard BM25 free parameters. `k1` controls term-frequency
    /// saturation and `b` controls how strongly document length normalizes
    /// the score; 1.5 and 0.75 are the conventional defaults.
    private static let bm25TermFrequencySaturation: Double = 1.5
    private static let bm25LengthNormalization: Double = 0.75

    /// Lowercases, splits on any non-alphanumeric character, drops empty
    /// tokens, and removes common English stopwords. Stopword removal matters
    /// for the fallback scorer: without it a trivial shared function word
    /// ("is", "the", "my") makes an unrelated entry score > 0 and surface for
    /// a query it has nothing to do with. No stemming — kept predictable.
    private static func tokenize(_ text: String) -> [String] {
        return text
            .lowercased()
            .split { character in
                !character.isLetter && !character.isNumber
            }
            .map { String($0) }
            .filter { !lexicalStopwords.contains($0) }
    }

    /// High-frequency English function words excluded from BM25 scoring so
    /// keyword overlap reflects meaningful terms, not glue words. Small on
    /// purpose — this is a recall fallback, not a full search engine.
    private static let lexicalStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
        "can", "did", "do", "does", "for", "from", "had", "has", "have",
        "how", "i", "if", "in", "is", "it", "its", "me", "my", "of", "on",
        "or", "so", "that", "the", "their", "them", "then", "there", "they",
        "this", "to", "was", "we", "were", "what", "when", "where", "which",
        "who", "will", "with", "would", "you", "your"
    ]

    /// Pre-tokenizes each candidate entry's text once so the BM25 pass and
    /// the IDF pass share the same token lists instead of re-tokenizing.
    private static func tokenizeDocuments(
        for entries: [PaceMemoryEntry]
    ) -> [String: [String]] {
        var documentTokensByEntryId: [String: [String]] = [:]
        for entry in entries {
            documentTokensByEntryId[entry.id] = tokenize(entry.text)
        }
        return documentTokensByEntryId
    }

    /// Mean token count across the active-entry corpus — BM25's `avgdl`.
    /// Returns 0 when there are no documents so the caller's length-
    /// normalization guard can short-circuit.
    private static func averageDocumentLength(
        of documentTokensByEntryId: [String: [String]]
    ) -> Double {
        guard !documentTokensByEntryId.isEmpty else { return 0 }
        let totalTokenCount = documentTokensByEntryId.values.reduce(0) { runningTotal, tokens in
            runningTotal + tokens.count
        }
        return Double(totalTokenCount) / Double(documentTokensByEntryId.count)
    }

    /// IDF for each unique query term, computed over the active-entry corpus
    /// with the standard BM25 (Robertson–Spärck Jones) formula:
    /// `log((N - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1)`.
    /// The `+ 1` keeps the IDF non-negative so a term appearing in every
    /// document contributes a small positive weight rather than dragging the
    /// score below zero. Rarer terms (lower document frequency) earn a
    /// strictly higher IDF, so they outrank common terms.
    private static func inverseDocumentFrequencyByTerm(
        forQueryTokens queryTokens: [String],
        documentTokensByEntryId: [String: [String]]
    ) -> [String: Double] {
        let totalDocumentCount = Double(documentTokensByEntryId.count)
        let uniqueQueryTerms = Set(queryTokens)

        var inverseDocumentFrequencyByTerm: [String: Double] = [:]
        for queryTerm in uniqueQueryTerms {
            var documentsContainingTerm = 0
            for documentTokens in documentTokensByEntryId.values {
                if documentTokens.contains(queryTerm) {
                    documentsContainingTerm += 1
                }
            }
            let documentFrequency = Double(documentsContainingTerm)
            let inverseDocumentFrequency = Foundation.log(
                (totalDocumentCount - documentFrequency + 0.5) / (documentFrequency + 0.5) + 1
            )
            inverseDocumentFrequencyByTerm[queryTerm] = inverseDocumentFrequency
        }
        return inverseDocumentFrequencyByTerm
    }

    /// Sum the BM25 contribution of every query term against one document's
    /// token list. Returns 0 when the document shares no query terms, which
    /// the caller uses to exclude non-overlapping entries.
    private static func bm25Score(
        queryTokens: [String],
        documentTokens: [String],
        averageDocumentLength: Double,
        inverseDocumentFrequencyByTerm: [String: Double]
    ) -> Double {
        guard !documentTokens.isEmpty, averageDocumentLength > 0 else { return 0 }

        let documentLength = Double(documentTokens.count)
        let termFrequencyByTerm = termFrequencyByTerm(in: documentTokens)

        var accumulatedScore = 0.0
        for queryTerm in Set(queryTokens) {
            let termFrequency = Double(termFrequencyByTerm[queryTerm] ?? 0)
            guard termFrequency > 0 else { continue }
            let inverseDocumentFrequency = inverseDocumentFrequencyByTerm[queryTerm] ?? 0

            let numerator = termFrequency * (bm25TermFrequencySaturation + 1)
            let denominator = termFrequency + bm25TermFrequencySaturation * (
                1 - bm25LengthNormalization
                + bm25LengthNormalization * (documentLength / averageDocumentLength)
            )
            accumulatedScore += inverseDocumentFrequency * (numerator / denominator)
        }
        return accumulatedScore
    }

    /// Raw term-frequency counts for one document's token list.
    private static func termFrequencyByTerm(in documentTokens: [String]) -> [String: Int] {
        var termFrequencyByTerm: [String: Int] = [:]
        for token in documentTokens {
            termFrequencyByTerm[token, default: 0] += 1
        }
        return termFrequencyByTerm
    }
}
