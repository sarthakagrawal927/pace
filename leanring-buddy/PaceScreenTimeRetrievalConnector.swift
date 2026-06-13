//
//  PaceScreenTimeRetrievalConnector.swift
//  leanring-buddy
//
//  System-wide app usage from macOS's own Screen Time data
//  (~/Library/Application Support/Knowledge/knowledgeC.db, the local
//  database behind the Screen Time UI). Complements Pace's own
//  app-usage journal: the journal only covers periods Pace is running,
//  while Screen Time covers everything macOS recorded (~4 weeks).
//
//  Permission posture mirrors the Notes/Mail connectors: reading the
//  database requires the user to grant Pace Full Disk Access; this
//  connector never prompts — an unreadable database is reported as a
//  skipped source with a repair hint. The database is opened read-only
//  and immutable so Screen Time's own writes are never disturbed.
//

import AppKit
import Foundation
import SQLite3

struct PaceScreenTimeReadError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

nonisolated final class PaceScreenTimeRetrievalConnector {
    /// Core Data timestamps count seconds from 2001-01-01 UTC.
    static let coreDataEpochOffset: TimeInterval = 978_307_200
    static let maximumAppsPerDay = 15
    static let defaultDayCount = 7

    private let knowledgeDatabaseURL: URL

    init(knowledgeDatabaseURL: URL? = nil) {
        self.knowledgeDatabaseURL = knowledgeDatabaseURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
    }

    /// Loads per-day, per-app foreground seconds from the Screen Time
    /// database and renders day-bucketed retrieval documents. Throws when
    /// the database is missing or unreadable (most commonly: Full Disk
    /// Access not granted).
    func loadScreenTimeDocuments(
        dayCount: Int = PaceScreenTimeRetrievalConnector.defaultDayCount,
        now: Date = Date()
    ) throws -> [PaceRetrievalDocument] {
        guard FileManager.default.fileExists(atPath: knowledgeDatabaseURL.path) else {
            throw PaceScreenTimeReadError(
                message: "Screen Time database not found — grant Pace Full Disk Access in System Settings → Privacy & Security."
            )
        }

        let usageRows = try queryAppUsageRows(since: now.addingTimeInterval(-TimeInterval(dayCount) * 86_400))

        // (dayKey → bundleIdentifier → seconds)
        var secondsByDayAndBundle: [String: [String: TimeInterval]] = [:]
        for usageRow in usageRows {
            let dayKey = Self.dayFormatter.string(from: usageRow.endedAt)
            secondsByDayAndBundle[dayKey, default: [:]][usageRow.bundleIdentifier, default: 0]
                += usageRow.durationSeconds
        }

        return secondsByDayAndBundle.keys.sorted().map { dayKey in
            let appSeconds = secondsByDayAndBundle[dayKey] ?? [:]
            let topApps = appSeconds
                .sorted { $0.value > $1.value }
                .prefix(Self.maximumAppsPerDay)
            let lines = topApps.map { bundleIdentifier, seconds in
                "\(Self.displayName(forBundleIdentifier: bundleIdentifier)) | \(Int(seconds / 60))m"
            }
            let retrievalHeader = "System screen time — apps used and minutes spent across the whole Mac on \(dayKey):"
            return PaceRetrievalDocument(
                id: "screen-time-\(dayKey)",
                source: .screenTime,
                title: "Screen Time — \(dayKey)",
                text: ([retrievalHeader] + lines).joined(separator: "\n"),
                modifiedAt: Self.dayFormatter.date(from: dayKey),
                permissionScope: "full-disk-access"
            )
        }
    }

    // MARK: - SQLite

    private struct AppUsageRow {
        let bundleIdentifier: String
        let endedAt: Date
        let durationSeconds: TimeInterval
    }

    private func queryAppUsageRows(since cutoff: Date) throws -> [AppUsageRow] {
        // immutable=1: read the database without touching its WAL even
        // while Screen Time's daemon holds it open.
        let databaseURI = "file:\(knowledgeDatabaseURL.path)?immutable=1"
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURI,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw PaceScreenTimeReadError(
                message: "Could not open the Screen Time database — grant Pace Full Disk Access in System Settings → Privacy & Security."
            )
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT ZVALUESTRING, ZSTARTDATE, ZENDDATE
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/app/usage'
          AND ZVALUESTRING IS NOT NULL
          AND ZENDDATE > ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PaceScreenTimeReadError(message: "Screen Time database has an unexpected schema.")
        }
        defer { sqlite3_finalize(statement) }

        let cutoffCoreDataTimestamp = cutoff.timeIntervalSince1970 - Self.coreDataEpochOffset
        sqlite3_bind_double(statement, 1, cutoffCoreDataTimestamp)

        var usageRows: [AppUsageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleIdentifierCString = sqlite3_column_text(statement, 0) else { continue }
            let startCoreDataTimestamp = sqlite3_column_double(statement, 1)
            let endCoreDataTimestamp = sqlite3_column_double(statement, 2)
            let durationSeconds = endCoreDataTimestamp - startCoreDataTimestamp
            guard durationSeconds > 0, durationSeconds < 86_400 else { continue }
            usageRows.append(AppUsageRow(
                bundleIdentifier: String(cString: bundleIdentifierCString),
                endedAt: Date(timeIntervalSince1970: endCoreDataTimestamp + Self.coreDataEpochOffset),
                durationSeconds: durationSeconds
            ))
        }
        return usageRows
    }

    // MARK: - Display names

    private static var displayNameCache: [String: String] = [:]

    private static func displayName(forBundleIdentifier bundleIdentifier: String) -> String {
        if let cached = displayNameCache[bundleIdentifier] {
            return cached
        }
        let resolvedName: String
        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            resolvedName = FileManager.default.displayName(atPath: applicationURL.path)
                .replacingOccurrences(of: ".app", with: "")
        } else {
            // Uninstalled app: the last reverse-DNS component is readable
            // enough ("com.figma.Desktop" → "Desktop" is wrong-ish, so keep
            // the last two components for context).
            let components = bundleIdentifier.split(separator: ".")
            resolvedName = components.suffix(2).joined(separator: ".")
        }
        displayNameCache[bundleIdentifier] = resolvedName
        return resolvedName
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
