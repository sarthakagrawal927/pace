//
//  PaceAppUsageJournalTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceAppUsageJournalTests {
    @Test func accumulatesDurationAcrossAppSwitches() async throws {
        var journal = PaceAppUsageJournal(rehydratingFrom: [], now: Date())
        let startedAt = Date()
        journal.recordActivation(appName: "Xcode", at: startedAt)
        journal.recordActivation(appName: "Safari", at: startedAt.addingTimeInterval(600))
        journal.recordActivation(appName: "Xcode", at: startedAt.addingTimeInterval(900))
        let flushed_document = journal.flush(now: startedAt.addingTimeInterval(1200))
        let document = try #require(flushed_document)

        // Xcode: 600s + 300s = 15m with 2 activations; Safari: 300s = 5m.
        #expect(document.text.contains("Xcode | 15m | 2 switches"))
        #expect(document.text.contains("Safari | 5m | 1 switches"))
    }

    @Test func documentLinesAreSortedByDurationDescending() async throws {
        var journal = PaceAppUsageJournal(rehydratingFrom: [], now: Date())
        let startedAt = Date()
        journal.recordActivation(appName: "Mail", at: startedAt)
        journal.recordActivation(appName: "Xcode", at: startedAt.addingTimeInterval(60))
        let flushed_document = journal.flush(now: startedAt.addingTimeInterval(1860))
        let document = try #require(flushed_document)

        // First line is the retrieval header; data lines follow.
        let dataLines = document.text.split(separator: "\n").dropFirst()
        #expect(dataLines.first?.hasPrefix("Xcode") == true)
        #expect(dataLines.last?.hasPrefix("Mail") == true)
    }

    @Test func reactivationOfFrontmostAppDoesNotDoubleCountSwitches() async throws {
        var journal = PaceAppUsageJournal(rehydratingFrom: [], now: Date())
        let startedAt = Date()
        journal.recordActivation(appName: "Xcode", at: startedAt)
        journal.recordActivation(appName: "Xcode", at: startedAt.addingTimeInterval(60))
        let flushed_document = journal.flush(now: startedAt.addingTimeInterval(120))
        let document = try #require(flushed_document)
        #expect(document.text.contains("Xcode | 2m | 1 switches"))
    }

    @Test func flushReturnsNilBeforeAnyActivity() async throws {
        var journal = PaceAppUsageJournal(rehydratingFrom: [], now: Date())
        #expect(journal.flush(now: Date()) == nil)
    }

    @Test func dayBucketDocumentHasExpectedIdentity() async throws {
        var journal = PaceAppUsageJournal(rehydratingFrom: [], now: Date())
        let startedAt = Date()
        journal.recordActivation(appName: "Xcode", at: startedAt)
        let flushedAt = startedAt.addingTimeInterval(60)
        let flushed_document = journal.flush(now: flushedAt)
        let document = try #require(flushed_document)

        let dayKey = PaceAppUsageJournal.dayFormatter.string(from: flushedAt)
        #expect(document.id == "app-usage-journal-\(dayKey)")
        #expect(document.source == .appUsageHistory)
        #expect(document.title == "App usage journal — \(dayKey)")
    }

    @Test func rehydrationPreservesEarlierUsageAcrossRestart() async throws {
        let startedAt = Date()
        var firstJournal = PaceAppUsageJournal(rehydratingFrom: [], now: startedAt)
        firstJournal.recordActivation(appName: "Xcode", at: startedAt)
        let flushed_persistedDocument = firstJournal.flush(now: startedAt.addingTimeInterval(600))
        let persistedDocument = try #require(flushed_persistedDocument)

        var rehydratedJournal = PaceAppUsageJournal(
            rehydratingFrom: [persistedDocument],
            now: startedAt.addingTimeInterval(600)
        )
        rehydratedJournal.recordActivation(appName: "Xcode", at: startedAt.addingTimeInterval(600))
        let flushed_mergedDocument = rehydratedJournal.flush(now: startedAt.addingTimeInterval(1200))
        let mergedDocument = try #require(flushed_mergedDocument)

        // 10 minutes before restart + 10 minutes after, same day bucket.
        #expect(mergedDocument.text.contains("Xcode | 20m | 2 switches"))
    }

    @Test func bucketsOlderThanSevenDaysAreDropped() async throws {
        let now = Date()
        var journal = PaceAppUsageJournal(rehydratingFrom: [], now: now)
        for dayOffset in 0..<9 {
            let activatedAt = now.addingTimeInterval(TimeInterval(-dayOffset) * 86_400)
            journal.recordActivation(appName: "Xcode", at: activatedAt)
            _ = journal.flush(now: activatedAt.addingTimeInterval(60))
            journal.recordActivation(appName: "reset-marker-\(dayOffset)", at: activatedAt.addingTimeInterval(61))
        }
        #expect(journal.allDocuments(now: now).count <= PaceAppUsageJournal.maximumDayBucketCount)
    }
}
