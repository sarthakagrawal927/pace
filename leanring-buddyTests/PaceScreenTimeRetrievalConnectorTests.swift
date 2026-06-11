//
//  PaceScreenTimeRetrievalConnectorTests.swift
//  leanring-buddyTests
//

import Foundation
import SQLite3
import Testing

@testable import Pace

struct PaceScreenTimeRetrievalConnectorTests {
    /// Builds a minimal knowledgeC-shaped SQLite database with /app/usage rows.
    private func makeFixtureDatabase(
        rows: [(bundleIdentifier: String, start: Date, end: Date)]
    ) throws -> URL {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-screentime-\(UUID().uuidString).db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        let createTable = """
        CREATE TABLE ZOBJECT (
            Z_PK INTEGER PRIMARY KEY,
            ZSTREAMNAME TEXT,
            ZVALUESTRING TEXT,
            ZSTARTDATE REAL,
            ZENDDATE REAL
        )
        """
        #expect(sqlite3_exec(database, createTable, nil, nil, nil) == SQLITE_OK)

        for row in rows {
            let startCoreData = row.start.timeIntervalSince1970
                - PaceScreenTimeRetrievalConnector.coreDataEpochOffset
            let endCoreData = row.end.timeIntervalSince1970
                - PaceScreenTimeRetrievalConnector.coreDataEpochOffset
            let insert = """
            INSERT INTO ZOBJECT (ZSTREAMNAME, ZVALUESTRING, ZSTARTDATE, ZENDDATE)
            VALUES ('/app/usage', '\(row.bundleIdentifier)', \(startCoreData), \(endCoreData))
            """
            #expect(sqlite3_exec(database, insert, nil, nil, nil) == SQLITE_OK)
        }
        return databaseURL
    }

    @Test func aggregatesUsagePerDayAndApp() async throws {
        let now = Date()
        let databaseURL = try makeFixtureDatabase(rows: [
            ("com.apple.dt.Xcode", now.addingTimeInterval(-7200), now.addingTimeInterval(-5400)), // 30m
            ("com.apple.dt.Xcode", now.addingTimeInterval(-3600), now.addingTimeInterval(-2700)), // 15m
            ("com.apple.Safari", now.addingTimeInterval(-1800), now.addingTimeInterval(-1200)),   // 10m
        ])
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let connector = PaceScreenTimeRetrievalConnector(knowledgeDatabaseURL: databaseURL)
        let documents = try connector.loadScreenTimeDocuments(now: now)

        // All rows are within today (or split across two days near midnight).
        #expect(!documents.isEmpty)
        let combinedText = documents.map(\.text).joined(separator: "\n")
        #expect(combinedText.contains("Xcode | 45m") || combinedText.contains("Xcode | 30m"))
        #expect(combinedText.contains("| 10m"))
        #expect(documents.allSatisfy { $0.source == .screenTime })
        #expect(documents.allSatisfy { $0.id.hasPrefix("screen-time-") })
        #expect(documents.first?.text.contains("System screen time") == true)
    }

    @Test func ignoresRowsOutsideTheDayWindowAndBogusDurations() async throws {
        let now = Date()
        let databaseURL = try makeFixtureDatabase(rows: [
            // 30 days ago: outside the 7-day window.
            ("com.old.app", now.addingTimeInterval(-30 * 86_400), now.addingTimeInterval(-30 * 86_400 + 600)),
            // Negative duration: corrupt row, skipped.
            ("com.bad.app", now, now.addingTimeInterval(-600)),
        ])
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let connector = PaceScreenTimeRetrievalConnector(knowledgeDatabaseURL: databaseURL)
        let documents = try connector.loadScreenTimeDocuments(now: now)
        #expect(documents.isEmpty)
    }

    @Test func missingDatabaseThrowsFullDiskAccessHint() async throws {
        let connector = PaceScreenTimeRetrievalConnector(
            knowledgeDatabaseURL: URL(fileURLWithPath: "/nonexistent/knowledgeC.db")
        )
        do {
            _ = try connector.loadScreenTimeDocuments()
            Issue.record("Expected a read error for a missing database")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            #expect(message.contains("Full Disk Access"))
        }
    }
}
