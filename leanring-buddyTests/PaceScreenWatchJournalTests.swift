//
//  PaceScreenWatchJournalTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceScreenWatchJournalTests {
    private func makeEntry(
        recordedAt: Date,
        screenLabel: String = "primary focus",
        categoryDisplayName: String = "major screen change",
        frontmostApplicationName: String? = "Xcode",
        screenDescription: String? = nil
    ) -> PaceScreenWatchJournalEntry {
        PaceScreenWatchJournalEntry(
            recordedAt: recordedAt,
            screenLabel: screenLabel,
            categoryDisplayName: categoryDisplayName,
            frontmostApplicationName: frontmostApplicationName,
            screenDescription: screenDescription
        )
    }

    @Test func firstEventCreatesDayBucketDocumentWithExpectedIdAndTitle() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let recordedAt = Date()
        let document = journal.record(makeEntry(recordedAt: recordedAt))

        let dayKey = PaceScreenWatchJournal.dayFormatter.string(from: recordedAt)
        #expect(document?.id == "screen-watch-journal-\(dayKey)-primary-focus")
        #expect(document?.source == .screenWatchHistory)
        #expect(document?.title == "Screen activity journal — \(dayKey) — primary focus")
    }

    @Test func duplicateCategoryAndAppWithinNinetySecondsIsSuppressed() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let firstRecordedAt = Date()
        #expect(journal.record(makeEntry(recordedAt: firstRecordedAt)) != nil)
        #expect(journal.record(makeEntry(recordedAt: firstRecordedAt.addingTimeInterval(30))) == nil)
        #expect(journal.record(makeEntry(recordedAt: firstRecordedAt.addingTimeInterval(120))) != nil)
    }

    @Test func differentCategoryWithinWindowIsRecorded() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let firstRecordedAt = Date()
        #expect(journal.record(makeEntry(recordedAt: firstRecordedAt)) != nil)
        let differentCategoryDocument = journal.record(makeEntry(
            recordedAt: firstRecordedAt.addingTimeInterval(10),
            categoryDisplayName: "content update"
        ))
        #expect(differentCategoryDocument != nil)
    }

    @Test func bucketCapsAtFortyLinesDroppingOldest() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let startedAt = Date()
        var latestDocument: PaceRetrievalDocument?
        for entryIndex in 0..<45 {
            // Alternate app names so the dedup window never suppresses.
            let document = journal.record(makeEntry(
                recordedAt: startedAt.addingTimeInterval(TimeInterval(entryIndex) * 10),
                frontmostApplicationName: "App\(entryIndex)"
            ))
            latestDocument = document ?? latestDocument
        }
        // First line is the retrieval header; data lines follow.
        let dataLines = (latestDocument?.text.split(separator: "\n") ?? []).dropFirst()
        #expect(dataLines.count == PaceScreenWatchJournal.maximumEntriesPerDayBucket)
        #expect(dataLines.first?.contains("App5") == true)
        #expect(!(latestDocument?.text.contains("App4 ") ?? true))
    }

    @Test func bucketsOlderThanSevenDaysAreDroppedFromAllDocuments() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let now = Date()
        for dayOffset in 0..<9 {
            _ = journal.record(makeEntry(
                recordedAt: now.addingTimeInterval(TimeInterval(-dayOffset) * 86_400)
            ))
        }
        let documents = journal.allDocuments(now: now)
        #expect(documents.count == PaceScreenWatchJournal.maximumDayBucketCount)
    }

    @Test func rehydrationPreservesEarlierSameDayLinesAcrossRestart() async throws {
        let now = Date()
        var firstJournal = PaceScreenWatchJournal(rehydratingFrom: [], now: now)
        _ = firstJournal.record(makeEntry(recordedAt: now, frontmostApplicationName: "Xcode"))
        let secondDocument = firstJournal.record(makeEntry(
            recordedAt: now.addingTimeInterval(120),
            frontmostApplicationName: "Safari"
        ))
        let persistedDocuments = [try #require(secondDocument)]

        var rehydratedJournal = PaceScreenWatchJournal(rehydratingFrom: persistedDocuments, now: now)
        let thirdDocument = rehydratedJournal.record(makeEntry(
            recordedAt: now.addingTimeInterval(300),
            frontmostApplicationName: "Mail"
        ))

        // First line is the retrieval header; data lines follow.
        let dataLines = Array(try #require(thirdDocument).text.split(separator: "\n").dropFirst())
        #expect(dataLines.count == 3)
        #expect(dataLines[0].contains("Xcode"))
        #expect(dataLines[1].contains("Safari"))
        #expect(dataLines[2].contains("Mail"))
    }

    @Test func documentLineIncludesTimeCategoryAppAndDescriptionExcerpt() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let recordedAt = Date()
        let longDescription = String(repeating: "describing the visible window ", count: 12)
        let document = journal.record(makeEntry(
            recordedAt: recordedAt,
            categoryDisplayName: "content update",
            frontmostApplicationName: "Safari",
            screenDescription: longDescription
        ))

        // Index 1: the first line is the retrieval header.
        let line = try #require(document?.text.split(separator: "\n").dropFirst().first.map(String.init))
        let timeOfDay = PaceScreenWatchJournal.timeFormatter.string(from: recordedAt)
        #expect(line.hasPrefix("\(timeOfDay) | content update | app: Safari | "))
        let descriptionPart = line.components(separatedBy: " | ")[3]
        #expect(descriptionPart.count <= PaceScreenWatchJournal.maximumScreenDescriptionCharacterCount + 1)
        #expect(descriptionPart.hasSuffix("…"))
    }

    @Test func missingDescriptionRendersPlaceholder() async throws {
        var journal = PaceScreenWatchJournal(rehydratingFrom: [], now: Date())
        let document = journal.record(makeEntry(recordedAt: Date(), screenDescription: nil))
        #expect(document?.text.hasSuffix("no screen description") == true)
    }
}
