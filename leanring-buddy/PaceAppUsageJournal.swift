//
//  PaceAppUsageJournal.swift
//  leanring-buddy
//
//  Pure day-bucketed journal of foreground app usage. Unlike the screen
//  watch journal this needs no screenshots and no permissions — app
//  activations come from NSWorkspace notifications — so it can answer
//  "how did I spend my time?" even when watch mode is off. One rolling
//  document per day; durations are stored at minute display precision
//  across restarts, which is plenty for time-summary questions.
//

import Foundation

nonisolated struct PaceAppUsageJournal {
    static let maximumDayBucketCount = 7
    static let documentIdPrefix = "app-usage-journal"

    private struct AppDayUsage {
        var accumulatedSeconds: TimeInterval
        var switchCount: Int
    }

    private var usageByDayKey: [String: [String: AppDayUsage]] = [:]
    private var openInterval: (appName: String, startedAt: Date)?

    init(rehydratingFrom persistedDocuments: [PaceRetrievalDocument], now: Date) {
        for document in persistedDocuments where document.source == .appUsageHistory {
            guard document.id.hasPrefix("\(Self.documentIdPrefix)-") else { continue }
            let dayKey = String(document.id.dropFirst("\(Self.documentIdPrefix)-".count))
            guard Self.dayFormatter.date(from: dayKey) != nil else { continue }

            var usageByAppName: [String: AppDayUsage] = [:]
            for renderedLine in document.text.split(separator: "\n") {
                guard let parsed = Self.parseLine(String(renderedLine)) else { continue }
                usageByAppName[parsed.appName] = AppDayUsage(
                    accumulatedSeconds: parsed.minutes * 60,
                    switchCount: parsed.switchCount
                )
            }
            if !usageByAppName.isEmpty {
                usageByDayKey[dayKey] = usageByAppName
            }
        }
        pruneOldDayBuckets()
    }

    /// Records that `appName` became the frontmost application. Closes the
    /// previously open interval (attributing its elapsed time), then starts
    /// a new one. Re-activations of the already-frontmost app are ignored.
    mutating func recordActivation(appName: String, at activationDate: Date) {
        let sanitizedAppName = Self.sanitizeAppName(appName)
        if let openInterval, openInterval.appName == sanitizedAppName {
            return
        }
        closeOpenInterval(until: activationDate)
        bumpSwitchCount(for: sanitizedAppName, on: activationDate)
        openInterval = (sanitizedAppName, activationDate)
    }

    /// Folds the open interval's elapsed time into the current day bucket
    /// (keeping the interval open from `now`) and returns the rebuilt day
    /// document, or nil when there is nothing to report yet.
    mutating func flush(now: Date) -> PaceRetrievalDocument? {
        closeOpenInterval(until: now)
        if let interval = openInterval {
            openInterval = (interval.appName, now)
        }
        let dayKey = Self.dayFormatter.string(from: now)
        guard usageByDayKey[dayKey] != nil else { return nil }
        return document(forDayKey: dayKey)
    }

    mutating func allDocuments(now: Date) -> [PaceRetrievalDocument] {
        pruneOldDayBuckets()
        return usageByDayKey.keys.sorted().map { document(forDayKey: $0) }
    }

    // MARK: - Interval accounting

    private mutating func closeOpenInterval(until endDate: Date) {
        guard let interval = openInterval else { return }
        let elapsedSeconds = endDate.timeIntervalSince(interval.startedAt)
        guard elapsedSeconds > 0 else { return }
        // Attribute the whole interval to the day it ends on. Intervals are
        // short (flushed on every app switch plus a periodic timer), so
        // midnight-crossing slack is at most one flush period.
        let dayKey = Self.dayFormatter.string(from: endDate)
        var usageByAppName = usageByDayKey[dayKey] ?? [:]
        var appUsage = usageByAppName[interval.appName] ?? AppDayUsage(accumulatedSeconds: 0, switchCount: 0)
        appUsage.accumulatedSeconds += elapsedSeconds
        usageByAppName[interval.appName] = appUsage
        usageByDayKey[dayKey] = usageByAppName
        openInterval = (interval.appName, endDate)
    }

    private mutating func bumpSwitchCount(for appName: String, on date: Date) {
        let dayKey = Self.dayFormatter.string(from: date)
        var usageByAppName = usageByDayKey[dayKey] ?? [:]
        var appUsage = usageByAppName[appName] ?? AppDayUsage(accumulatedSeconds: 0, switchCount: 0)
        appUsage.switchCount += 1
        usageByAppName[appName] = appUsage
        usageByDayKey[dayKey] = usageByAppName
    }

    private mutating func pruneOldDayBuckets() {
        let sortedDayKeys = usageByDayKey.keys.sorted()
        guard sortedDayKeys.count > Self.maximumDayBucketCount else { return }
        for dayKeyToDrop in sortedDayKeys.dropLast(Self.maximumDayBucketCount) {
            usageByDayKey.removeValue(forKey: dayKeyToDrop)
        }
    }

    // MARK: - Document building

    private func document(forDayKey dayKey: String) -> PaceRetrievalDocument {
        let usageByAppName = usageByDayKey[dayKey] ?? [:]
        let sortedUsages = usageByAppName.sorted { firstUsage, secondUsage in
            if firstUsage.value.accumulatedSeconds == secondUsage.value.accumulatedSeconds {
                return firstUsage.key < secondUsage.key
            }
            return firstUsage.value.accumulatedSeconds > secondUsage.value.accumulatedSeconds
        }
        let lines = sortedUsages.map { appName, appUsage in
            "\(appName) | \(Int(appUsage.accumulatedSeconds / 60))m | \(appUsage.switchCount) switches"
        }
        // Natural-language header so BM25 lexical retrieval can match
        // questions like "what apps did I use" / "how did I spend my time" —
        // only document text is indexed, and the data lines share no tokens
        // with those questions. Rehydration parsers skip it (wrong shape).
        let retrievalHeader = "Apps used and time spent (app usage, screen time, how I spend my time) on \(dayKey):"
        return PaceRetrievalDocument(
            id: "\(Self.documentIdPrefix)-\(dayKey)",
            source: .appUsageHistory,
            title: "App usage journal — \(dayKey)",
            text: ([retrievalHeader] + lines).joined(separator: "\n"),
            modifiedAt: Self.dayFormatter.date(from: dayKey),
            permissionScope: "app-usage"
        )
    }

    // MARK: - Line round-tripping

    private static func sanitizeAppName(_ rawAppName: String) -> String {
        let collapsed = rawAppName
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "unknown" : collapsed
    }

    private static func parseLine(_ renderedLine: String) -> (appName: String, minutes: TimeInterval, switchCount: Int)? {
        let parts = renderedLine.components(separatedBy: " | ")
        guard parts.count == 3 else { return nil }
        guard parts[1].hasSuffix("m"), let minutes = TimeInterval(parts[1].dropLast()) else { return nil }
        guard parts[2].hasSuffix(" switches"), let switchCount = Int(parts[2].dropLast(" switches".count)) else { return nil }
        return (parts[0], minutes, switchCount)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
