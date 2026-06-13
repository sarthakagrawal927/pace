//
//  PaceEpisodicMemory.swift
//  leanring-buddy
//
//  Episodic memory primitives: the fact struct, the
//  deterministic pattern extractor (kept for the v1 keyword
//  patterns that don't need an LLM call), tombstones for user-
//  deleted facts, the sensitive-topic policy, and the in-memory
//  store that enforces dedup + the 200-fact LRU cap.
//
//  The Apple FM / LM Studio extractors live in
//  `PaceEpisodicFactExtractor.swift` and produce facts that flow
//  through `PaceEpisodicFactStore` on the way to retrieval.
//

import Foundation

// MARK: - Fact

/// One durable fact about the user or the user's world. The store
/// dedup key is `(subject, predicate)` case-insensitive — see
/// `PaceEpisodicFactStore.applyDedup(_:against:)`.
nonisolated struct PaceEpisodicFact: Codable, Equatable, Identifiable {
    let identifier: String
    let extractedAt: Date
    let subject: String
    let predicate: String
    let value: String
    let confidence: Double
    let expiresAt: Date?
    let topicHashtags: [String]
    let sourceTurnId: String?

    var id: String { identifier }
}

// MARK: - Tombstone

/// Marker for a fact the user explicitly deleted. The extractor
/// MUST NOT re-insert any fact whose `(subject, predicate, value)`
/// triplet matches a non-expired tombstone. Tombstones expire after
/// 30 days — long enough that re-extraction reliably means a fresh
/// signal, short enough that genuinely-changed circumstances can be
/// re-captured.
struct PaceEpisodicTombstone: Codable, Equatable {
    let factId: String
    let deletedAt: Date
    /// Triplet captured at deletion time so the extractor can match
    /// against the same `(subject, predicate, value)` even if the
    /// stable fact ID hash changed across builds.
    let subject: String
    let predicate: String
    let value: String

    /// Tombstones lose force after 30 days. Per PRD: durable but not
    /// forever — circumstances change.
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(deletedAt) > Self.retentionInterval
    }

    func matches(fact: PaceEpisodicFact) -> Bool {
        Self.normalizedTriplet(subject: subject, predicate: predicate, value: value)
            == Self.normalizedTriplet(subject: fact.subject, predicate: fact.predicate, value: fact.value)
    }

    static func normalizedTriplet(subject: String, predicate: String, value: String) -> String {
        let normalizedSubject = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPredicate = predicate.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(normalizedSubject)|\(normalizedPredicate)|\(normalizedValue)"
    }
}

// MARK: - Sensitive topic policy

/// Topic hashtags that are durably stored but excluded from the
/// `LOCAL CONTEXT` block fed to the planner unless the user opts in
/// via `injectSensitiveEpisodicTopics`. Tagged by the extractor in
/// the system prompt; defaulting to OFF for injection respects the
/// privacy-first posture spelled out in CLAUDE.md.
nonisolated enum PaceEpisodicSensitiveTopics {
    static let sensitiveTopicHashtags: Set<String> = [
        "#health",
        "#finance",
        "#relationship",
    ]

    /// True if any of the fact's hashtags fall into the sensitive set.
    /// Comparison is case-insensitive and `#` is preserved (matches
    /// the extractor's prompt instructions).
    static func isFactSensitive(_ fact: PaceEpisodicFact) -> Bool {
        let normalizedHashtags = Set(fact.topicHashtags.map { $0.lowercased() })
        let normalizedSensitive = Set(sensitiveTopicHashtags.map { $0.lowercased() })
        return !normalizedHashtags.isDisjoint(with: normalizedSensitive)
    }

    /// Permission scope written into the retrieval document so the
    /// retrieval layer can filter on injection without re-parsing
    /// hashtags. Sensitive facts get a distinct scope so the filter
    /// is a fast string comparison.
    static let sensitivePermissionScope = "episodicMemory-sensitive"
    static let standardPermissionScope = "episodicMemory"
}

// MARK: - Pattern extractor (deterministic, v1)

/// The original deterministic keyword-pattern extractor. Kept so the
/// few high-confidence cases (preferences, family-health, work
/// deadline) still extract WITHOUT a model call. Renamed from
/// `PaceEpisodicFactExtractor` to free the bare name for the protocol
/// in `PaceEpisodicFactExtractor.swift`.
struct PaceEpisodicPatternFactExtractor {
    var now: () -> Date = Date.init

    func extractFacts(
        from userTranscript: String,
        assistantText: String = "",
        frontmostApplicationName: String? = nil,
        sourceTurnId: String? = nil
    ) -> [PaceEpisodicFact] {
        let trimmedTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = trimmedTranscript.lowercased()
        guard !trimmedTranscript.isEmpty else { return [] }
        guard !Self.looksEphemeral(normalizedTranscript) else { return [] }
        guard !Self.looksLikeAction(normalizedTranscript) else { return [] }

        let extractedAt = now()
        var facts: [PaceEpisodicFact] = []

        if let preference = Self.preferenceFact(from: trimmedTranscript) {
            facts.append(makeFact(
                extractedAt: extractedAt,
                subject: "user",
                predicate: "prefers",
                value: preference,
                confidence: 0.82,
                topicHashtags: ["#preference"],
                sourceTurnId: sourceTurnId
            ))
        }

        if let healthFact = Self.healthFact(from: trimmedTranscript) {
            facts.append(makeFact(
                extractedAt: extractedAt,
                subject: healthFact.subject,
                predicate: "is in",
                value: healthFact.value,
                confidence: 0.78,
                topicHashtags: ["#family", "#health"],
                sourceTurnId: sourceTurnId
            ))
        }

        if let workFact = Self.workFact(from: trimmedTranscript) {
            facts.append(makeFact(
                extractedAt: extractedAt,
                subject: workFact.subject,
                predicate: workFact.predicate,
                value: workFact.value,
                confidence: 0.76,
                topicHashtags: ["#work"],
                sourceTurnId: sourceTurnId
            ))
        }

        return facts
    }

    private func makeFact(
        extractedAt: Date,
        subject: String,
        predicate: String,
        value: String,
        confidence: Double,
        topicHashtags: [String],
        sourceTurnId: String?
    ) -> PaceEpisodicFact {
        let stableSeed = "\(subject)|\(predicate)|\(value)|\(sourceTurnId ?? "")"
        return PaceEpisodicFact(
            identifier: "episodic-\(abs(stableSeed.hashValue))",
            extractedAt: extractedAt,
            subject: subject,
            predicate: predicate,
            value: value,
            confidence: confidence,
            expiresAt: nil,
            topicHashtags: topicHashtags,
            sourceTurnId: sourceTurnId
        )
    }

    /// Renders a fact as a `PaceRetrievalDocument` for the local
    /// retrieval index. Sensitive facts use a distinct
    /// `permissionScope` so the injection-time filter can drop them
    /// in a single string compare.
    nonisolated static func retrievalDocument(for fact: PaceEpisodicFact) -> PaceRetrievalDocument {
        let permissionScope = PaceEpisodicSensitiveTopics.isFactSensitive(fact)
            ? PaceEpisodicSensitiveTopics.sensitivePermissionScope
            : PaceEpisodicSensitiveTopics.standardPermissionScope
        return PaceRetrievalDocument(
            id: fact.identifier,
            source: .episodicMemory,
            title: "\(fact.subject) \(fact.predicate)",
            text: "\(fact.subject) \(fact.predicate) \(fact.value) \(fact.topicHashtags.joined(separator: " "))",
            modifiedAt: fact.extractedAt,
            permissionScope: permissionScope
        )
    }

    private static func looksEphemeral(_ normalizedTranscript: String) -> Bool {
        let ephemeralHints = [
            "i'm hungry", "i am hungry", "i'm tired", "i am tired",
            "i feel sleepy", "i'm bored", "right now", "for today",
        ]
        return ephemeralHints.contains(where: normalizedTranscript.contains)
    }

    private static func looksLikeAction(_ normalizedTranscript: String) -> Bool {
        let actionPrefixes = [
            "open ", "click ", "tap ", "press ", "type ", "scroll ",
            "draft ", "compose ", "send ", "set a timer", "start a timer",
        ]
        return actionPrefixes.contains(where: normalizedTranscript.hasPrefix)
    }

    private static func preferenceFact(from transcript: String) -> String? {
        let patterns = ["i prefer ", "i like ", "i usually use ", "my preferred "]
        let lowercasedTranscript = transcript.lowercased()
        for pattern in patterns where lowercasedTranscript.contains(pattern) {
            guard let range = lowercasedTranscript.range(of: pattern) else { continue }
            let originalStartIndex = transcript.index(transcript.startIndex, offsetBy: lowercasedTranscript.distance(from: lowercasedTranscript.startIndex, to: range.upperBound))
            return sanitizedValue(String(transcript[originalStartIndex...]))
        }
        return nil
    }

    private static func healthFact(from transcript: String) -> (subject: String, value: String)? {
        let lowercasedTranscript = transcript.lowercased()
        let subjects = ["my mom", "my mother", "my dad", "my father", "my partner"]
        guard let subject = subjects.first(where: lowercasedTranscript.contains) else { return nil }
        if lowercasedTranscript.contains("hospital") {
            return (subject: subject.replacingOccurrences(of: "my ", with: "user's "), value: "the hospital")
        }
        return nil
    }

    private static func workFact(from transcript: String) -> (subject: String, predicate: String, value: String)? {
        let lowercasedTranscript = transcript.lowercased()
        guard lowercasedTranscript.contains("shipping")
            || lowercasedTranscript.contains("launch")
            || lowercasedTranscript.contains("deadline") else {
            return nil
        }
        if lowercasedTranscript.contains("friday") {
            return (subject: "work milestone", predicate: "happens on", value: "Friday")
        }
        return (subject: "work milestone", predicate: "is", value: sanitizedValue(transcript))
    }

    private static func sanitizedValue(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))
            .prefix(180)
            .description
    }
}

// MARK: - Store

/// Hard cap on stored facts and the LRU eviction policy. The cap
/// keeps the retrieval index bounded so episodic memory can't
/// dominate the planner's LOCAL CONTEXT injection over time, and so
/// the document set fits comfortably in the existing lexical store.
enum PaceEpisodicMemoryLimits {
    /// 200 is the PRD-mandated ceiling; eviction drops the oldest by
    /// `extractedAt` (true LRU on insert ordering).
    static let maximumStoredFactCount: Int = 200
}

/// Outcome of applying a freshly-extracted fact to the store.
/// Surfaced to callers so the wiring in `CompanionManager` can log
/// what happened without re-querying the store.
enum PaceEpisodicFactStoreApplyOutcome: Equatable {
    /// New fact, no existing `(subject, predicate)` row. Inserted.
    case inserted
    /// Existing `(subject, predicate)` row replaced because the new
    /// fact is newer AND its confidence is within 0.1 of the
    /// existing one. Treats "essentially the same belief, freshly
    /// re-stated" as an update rather than a duplicate.
    case replaced(previousFactId: String)
    /// Existing `(subject, predicate)` row appended alongside the
    /// new one because the confidence gap was too large. Both stay.
    case appended
    /// Skipped because the fact triplet matches an unexpired
    /// tombstone.
    case skippedBecauseOfTombstone
}

/// Pure dedup decision used by the store. Pulled out so tests can
/// drive it without spinning up the whole store.
enum PaceEpisodicFactDedupPolicy {
    /// Apply the dedup rule for a single incoming fact against the
    /// current store contents. Returns the action and, for the
    /// replace case, the identifier of the fact to drop.
    static func decision(
        for incomingFact: PaceEpisodicFact,
        existingFacts: [PaceEpisodicFact]
    ) -> PaceEpisodicFactStoreApplyOutcome {
        let normalizedIncomingSubject = incomingFact.subject.lowercased()
        let normalizedIncomingPredicate = incomingFact.predicate.lowercased()
        let matchingExistingFact = existingFacts.first { existingFact in
            existingFact.subject.lowercased() == normalizedIncomingSubject
                && existingFact.predicate.lowercased() == normalizedIncomingPredicate
        }
        guard let matchingExistingFact else {
            return .inserted
        }
        // Same subject+predicate — decide replace vs append by
        // recency AND confidence proximity. Recency without
        // proximity is too aggressive (a wildly different confidence
        // reading is a different belief, not a refresh).
        let incomingIsNewer = incomingFact.extractedAt > matchingExistingFact.extractedAt
        let confidenceDelta = abs(incomingFact.confidence - matchingExistingFact.confidence)
        let confidenceIsClose = confidenceDelta < 0.1
        if incomingIsNewer && confidenceIsClose {
            return .replaced(previousFactId: matchingExistingFact.identifier)
        }
        return .appended
    }
}

/// In-memory storage of `PaceEpisodicFact`s plus their tombstones.
/// Wraps the dedup, tombstone, and LRU-cap logic so the wiring in
/// `PaceLocalRetriever.recordEpisodicFacts` and the Settings →
/// Memory tab can reuse one place.
final class PaceEpisodicFactStore {
    private var factsById: [String: PaceEpisodicFact] = [:]
    private var tombstones: [PaceEpisodicTombstone] = []
    private var now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var allFacts: [PaceEpisodicFact] {
        factsById.values.sorted { $0.extractedAt < $1.extractedAt }
    }

    var allTombstones: [PaceEpisodicTombstone] {
        tombstones
    }

    /// Returns the facts currently visible to the retrieval injector.
    /// Sensitive-topic facts are excluded unless the caller passes
    /// `includeSensitiveTopics: true`.
    func factsForInjection(includeSensitiveTopics: Bool) -> [PaceEpisodicFact] {
        allFacts.filter { fact in
            includeSensitiveTopics || !PaceEpisodicSensitiveTopics.isFactSensitive(fact)
        }
    }

    /// Insert a single fact through dedup + tombstone gates. Returns
    /// what happened so the caller can log/audit.
    @discardableResult
    func apply(_ incomingFact: PaceEpisodicFact) -> PaceEpisodicFactStoreApplyOutcome {
        // Tombstone gate first — a re-extracted fact never resurrects
        // a deleted one unless its tombstone has expired.
        cleanExpiredTombstones()
        let matchingActiveTombstone = tombstones.first { tombstone in
            !tombstone.isExpired(now: now()) && tombstone.matches(fact: incomingFact)
        }
        if matchingActiveTombstone != nil {
            return .skippedBecauseOfTombstone
        }

        let dedupOutcome = PaceEpisodicFactDedupPolicy.decision(
            for: incomingFact,
            existingFacts: Array(factsById.values)
        )
        switch dedupOutcome {
        case .inserted:
            factsById[incomingFact.identifier] = incomingFact
        case .replaced(let previousFactId):
            factsById.removeValue(forKey: previousFactId)
            factsById[incomingFact.identifier] = incomingFact
        case .appended:
            factsById[incomingFact.identifier] = incomingFact
        case .skippedBecauseOfTombstone:
            // Unreachable — handled above. Kept exhaustive.
            return .skippedBecauseOfTombstone
        }
        enforceLRUCap()
        return dedupOutcome
    }

    /// Insert a batch and return per-fact outcomes paired with the
    /// surviving fact identifiers. Callers use this list to decide
    /// what to upsert into retrieval.
    func applyBatch(_ incomingFacts: [PaceEpisodicFact]) -> [(PaceEpisodicFact, PaceEpisodicFactStoreApplyOutcome)] {
        incomingFacts.map { fact in (fact, apply(fact)) }
    }

    /// Tombstone a fact by identifier — used by the Settings UI.
    /// Returns the tombstone for the caller to persist alongside.
    @discardableResult
    func deleteFact(withIdentifier factId: String) -> PaceEpisodicTombstone? {
        guard let removedFact = factsById.removeValue(forKey: factId) else { return nil }
        let tombstone = PaceEpisodicTombstone(
            factId: removedFact.identifier,
            deletedAt: now(),
            subject: removedFact.subject,
            predicate: removedFact.predicate,
            value: removedFact.value
        )
        tombstones.append(tombstone)
        return tombstone
    }

    /// Clear every stored fact and tombstone everything that was
    /// stored at the moment of reset. Lets users wipe episodic
    /// memory from Settings without risking same-turn re-extraction.
    func resetAll() {
        let snapshotForTombstoning = Array(factsById.values)
        factsById.removeAll()
        let deletedAt = now()
        for fact in snapshotForTombstoning {
            tombstones.append(PaceEpisodicTombstone(
                factId: fact.identifier,
                deletedAt: deletedAt,
                subject: fact.subject,
                predicate: fact.predicate,
                value: fact.value
            ))
        }
    }

    /// Drop the oldest facts until we're back under the cap. Cheap —
    /// runs once per insert.
    private func enforceLRUCap() {
        guard factsById.count > PaceEpisodicMemoryLimits.maximumStoredFactCount else { return }
        let sortedByExtractedAt = factsById.values.sorted { $0.extractedAt < $1.extractedAt }
        let overflowCount = factsById.count - PaceEpisodicMemoryLimits.maximumStoredFactCount
        for evictedFact in sortedByExtractedAt.prefix(overflowCount) {
            factsById.removeValue(forKey: evictedFact.identifier)
        }
    }

    /// Drop tombstones that have aged out of the 30-day retention
    /// window. The cleanup runs on every apply so the tombstone list
    /// can't grow without bound either.
    private func cleanExpiredTombstones() {
        let currentTime = now()
        tombstones.removeAll { $0.isExpired(now: currentTime) }
    }
}
