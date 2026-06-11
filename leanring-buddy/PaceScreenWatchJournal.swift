//
//  PaceScreenWatchJournal.swift
//  leanring-buddy
//
//  Pure day-bucketed journal of watch-mode screen events, persisted as
//  retrieval documents so "what did I do today?" questions can be answered
//  from local history. One rolling document per (day, screen label) keeps
//  the BM25 chunker cheap and retention enforceable with source-wide
//  replaces. Isolation-free so every rule is unit-testable.
//

import Foundation

nonisolated struct PaceScreenWatchJournalEntry: Equatable {
    let recordedAt: Date
    let screenLabel: String
    let categoryDisplayName: String
    let frontmostApplicationName: String?
    let screenDescription: String?
}

nonisolated struct PaceScreenWatchJournal {
    static let maximumEntriesPerDayBucket = 40
    static let maximumDayBucketCount = 7
    static let duplicateSuppressionWindowInSeconds: TimeInterval = 90
    static let maximumScreenDescriptionCharacterCount = 140
    static let documentIdPrefix = "screen-watch-journal"

    private struct JournalLine {
        let recordedAt: Date
        let categoryDisplayName: String
        let frontmostApplicationName: String
        let descriptionExcerpt: String

        var renderedText: String {
            let timeOfDay = PaceScreenWatchJournal.timeFormatter.string(from: recordedAt)
            return "\(timeOfDay) | \(categoryDisplayName) | app: \(frontmostApplicationName) | \(descriptionExcerpt)"
        }
    }

    private struct DayBucket {
        let dayKey: String
        let screenLabel: String
        var lines: [JournalLine]
    }

    private var bucketsById: [String: DayBucket] = [:]

    init(rehydratingFrom persistedDocuments: [PaceRetrievalDocument], now: Date) {
        for document in persistedDocuments where document.source == .screenWatchHistory {
            guard let (dayKey, screenLabel) = Self.parseDocumentIdentity(of: document) else { continue }
            let lines = document.text
                .split(separator: "\n")
                .compactMap { Self.parseLine(String($0), dayKey: dayKey) }
            guard !lines.isEmpty else { continue }
            bucketsById[document.id] = DayBucket(
                dayKey: dayKey,
                screenLabel: screenLabel,
                lines: lines
            )
        }
        pruneOldDayBuckets(now: now)
    }

    /// Records the entry and returns the changed day-bucket document, or nil
    /// when the entry was suppressed as a near-duplicate.
    mutating func record(_ entry: PaceScreenWatchJournalEntry) -> PaceRetrievalDocument? {
        let dayKey = Self.dayFormatter.string(from: entry.recordedAt)
        let bucketId = Self.documentId(dayKey: dayKey, screenLabel: entry.screenLabel)

        let sanitizedApplicationName = Self.sanitizeForLineFormat(
            entry.frontmostApplicationName ?? "unknown"
        )
        let descriptionExcerpt = Self.descriptionExcerpt(from: entry.screenDescription)

        var bucket = bucketsById[bucketId] ?? DayBucket(
            dayKey: dayKey,
            screenLabel: entry.screenLabel,
            lines: []
        )

        if let newestLine = bucket.lines.last,
           newestLine.categoryDisplayName == entry.categoryDisplayName,
           newestLine.frontmostApplicationName == sanitizedApplicationName,
           entry.recordedAt.timeIntervalSince(newestLine.recordedAt) < Self.duplicateSuppressionWindowInSeconds {
            return nil
        }

        bucket.lines.append(JournalLine(
            recordedAt: entry.recordedAt,
            categoryDisplayName: Self.sanitizeForLineFormat(entry.categoryDisplayName),
            frontmostApplicationName: sanitizedApplicationName,
            descriptionExcerpt: descriptionExcerpt
        ))
        if bucket.lines.count > Self.maximumEntriesPerDayBucket {
            bucket.lines.removeFirst(bucket.lines.count - Self.maximumEntriesPerDayBucket)
        }
        bucketsById[bucketId] = bucket

        return Self.document(for: bucket)
    }

    /// Full current document set after pruning buckets older than the
    /// retention window.
    mutating func allDocuments(now: Date) -> [PaceRetrievalDocument] {
        pruneOldDayBuckets(now: now)
        let sortedBuckets = bucketsById.values.sorted { firstBucket, secondBucket in
            if firstBucket.dayKey == secondBucket.dayKey {
                return firstBucket.screenLabel < secondBucket.screenLabel
            }
            return firstBucket.dayKey < secondBucket.dayKey
        }
        return sortedBuckets.map(Self.document(for:))
    }

    // MARK: - Pruning

    private mutating func pruneOldDayBuckets(now: Date) {
        let sortedDayKeys = Set(bucketsById.values.map(\.dayKey)).sorted()
        guard sortedDayKeys.count > Self.maximumDayBucketCount else { return }
        let dayKeysToDrop = Set(sortedDayKeys.dropLast(Self.maximumDayBucketCount))
        bucketsById = bucketsById.filter { !dayKeysToDrop.contains($0.value.dayKey) }
    }

    // MARK: - Document building

    private static func document(for bucket: DayBucket) -> PaceRetrievalDocument {
        // Natural-language header so BM25 lexical retrieval can match
        // questions like "what was I doing" / "what did I do" — only document
        // text is indexed, and the data lines share few tokens with those
        // questions. The rehydration line parser skips it (wrong shape).
        let retrievalHeader = "Screen activity: what I was doing and what I did on \(bucket.dayKey) (\(bucket.screenLabel)):"
        return PaceRetrievalDocument(
            id: documentId(dayKey: bucket.dayKey, screenLabel: bucket.screenLabel),
            source: .screenWatchHistory,
            title: "Screen activity journal — \(bucket.dayKey) — \(bucket.screenLabel)",
            text: ([retrievalHeader] + bucket.lines.map(\.renderedText)).joined(separator: "\n"),
            modifiedAt: bucket.lines.last?.recordedAt,
            permissionScope: "screen-watch"
        )
    }

    static func documentId(dayKey: String, screenLabel: String) -> String {
        "\(documentIdPrefix)-\(dayKey)-\(screenLabelSlug(screenLabel))"
    }

    static func screenLabelSlug(_ screenLabel: String) -> String {
        let lowered = screenLabel.lowercased()
        var slugCharacters: [Character] = []
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                slugCharacters.append(character)
                lastWasDash = false
            } else if !lastWasDash, !slugCharacters.isEmpty {
                slugCharacters.append("-")
                lastWasDash = true
            }
        }
        while slugCharacters.last == "-" {
            slugCharacters.removeLast()
        }
        return slugCharacters.isEmpty ? "screen" : String(slugCharacters)
    }

    // MARK: - Line round-tripping

    private static func sanitizeForLineFormat(_ rawText: String) -> String {
        let collapsed = rawText
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "unknown" : collapsed
    }

    private static func descriptionExcerpt(from screenDescription: String?) -> String {
        guard let screenDescription = screenDescription?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !screenDescription.isEmpty else {
            return "no screen description"
        }
        guard screenDescription.count > maximumScreenDescriptionCharacterCount else {
            return screenDescription
        }
        return String(screenDescription.prefix(maximumScreenDescriptionCharacterCount)) + "…"
    }

    private static func parseDocumentIdentity(of document: PaceRetrievalDocument) -> (dayKey: String, screenLabel: String)? {
        // The human-readable title carries the original screen label; the id
        // only has the slug. Title format: "Screen activity journal — <day> — <label>"
        let titleComponents = document.title.components(separatedBy: " — ")
        guard titleComponents.count >= 3, titleComponents[0] == "Screen activity journal" else {
            return nil
        }
        let dayKey = titleComponents[1]
        let screenLabel = titleComponents[2...].joined(separator: " — ")
        guard dayFormatter.date(from: dayKey) != nil else { return nil }
        return (dayKey, screenLabel)
    }

    private static func parseLine(_ renderedLine: String, dayKey: String) -> JournalLine? {
        let parts = renderedLine.components(separatedBy: " | ")
        guard parts.count >= 4 else { return nil }
        let timeOfDay = parts[0]
        guard let recordedAt = dateTimeFormatter.date(from: "\(dayKey) \(timeOfDay)") else {
            return nil
        }
        let appPart = parts[2]
        let frontmostApplicationName = appPart.hasPrefix("app: ")
            ? String(appPart.dropFirst("app: ".count))
            : appPart
        return JournalLine(
            recordedAt: recordedAt,
            categoryDisplayName: parts[1],
            frontmostApplicationName: frontmostApplicationName,
            descriptionExcerpt: parts[3...].joined(separator: " | ")
        )
    }

    // MARK: - Formatters

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
