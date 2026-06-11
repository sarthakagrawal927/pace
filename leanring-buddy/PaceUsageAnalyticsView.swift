//
//  PaceUsageAnalyticsView.swift
//  leanring-buddy
//
//  Usage analytics dashboard. Reads the local audit-log JSONL stream
//  (~/Library/Application Support/Pace/api-audit.jsonl) and renders
//  per-subsystem counts, error rates, and p50/p95 latency for the last
//  24h. Same data the audit-summary script shows from the command line.
//

import Foundation
import SwiftUI

struct PaceSubsystemUsageStats: Identifiable, Equatable {
    let id: String
    let subsystem: String
    let target: String
    let callCount: Int
    let errorPercent: Int
    let p50Milliseconds: Int
    let p95Milliseconds: Int
}

struct PaceUsageAnalyticsView: View {
    @State private var statsRows: [PaceSubsystemUsageStats] = []
    @State private var lastRefreshAt: Date?
    @State private var totalTurnsInWindow: Int = 0

    private let lookbackInHours: Int = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Last \(lookbackInHours)h — \(totalTurnsInWindow) turn(s) tracked")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            if statsRows.isEmpty {
                VStack {
                    Spacer()
                    Text("No audit entries yet in the last \(lookbackInHours) hours.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Table(statsRows) {
                    TableColumn("Subsystem") { row in
                        Text(row.subsystem)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Target") { row in
                        Text(row.target).font(.system(size: 12, design: .monospaced))
                    }
                    TableColumn("Calls") { row in
                        Text("\(row.callCount)")
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Error %") { row in
                        Text("\(row.errorPercent)%")
                            .foregroundColor(row.errorPercent > 0 ? .orange : .secondary)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("p50 ms") { row in
                        Text("\(row.p50Milliseconds)")
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("p95 ms") { row in
                        Text("\(row.p95Milliseconds)")
                    }
                    .width(min: 60, ideal: 70)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let auditLogURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace/api-audit.jsonl")
        guard let auditLogURL,
              let auditLogContents = try? String(contentsOf: auditLogURL, encoding: .utf8) else {
            statsRows = []
            totalTurnsInWindow = 0
            return
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFractional = ISO8601DateFormatter()
        let cutoffDate = Date().addingTimeInterval(-Double(lookbackInHours) * 3600)

        var statsBucket: [String: [(durationMilliseconds: Int, isError: Bool)]] = [:]
        var seenTurnIds: Set<String> = []
        var keyToHumanLabel: [String: (subsystem: String, target: String)] = [:]
        for line in auditLogContents.split(separator: "\n") {
            guard let entryData = line.data(using: .utf8),
                  let entryDictionary = try? JSONSerialization.jsonObject(with: entryData) as? [String: Any] else {
                continue
            }
            guard let timestampString = entryDictionary["at"] as? String,
                  let timestampDate = isoFormatter.date(from: timestampString)
                    ?? isoFormatterNoFractional.date(from: timestampString),
                  timestampDate >= cutoffDate else {
                continue
            }
            if let turnId = entryDictionary["turnId"] as? String {
                seenTurnIds.insert(turnId)
            }
            let subsystem = (entryDictionary["subsystem"] as? String) ?? "?"
            let target = (entryDictionary["target"] as? String) ?? "?"
            let bucketKey = "\(subsystem)|\(target)"
            keyToHumanLabel[bucketKey] = (subsystem, target)
            let durationMilliseconds = (entryDictionary["durationMilliseconds"] as? Int) ?? 0
            let isError = (entryDictionary["outcome"] as? String) != "ok"
            statsBucket[bucketKey, default: []].append((durationMilliseconds, isError))
        }

        statsRows = statsBucket.map { bucketKey, samples in
            let durations = samples.map(\.durationMilliseconds).sorted()
            let errorCount = samples.filter(\.isError).count
            let label = keyToHumanLabel[bucketKey]!
            return PaceSubsystemUsageStats(
                id: bucketKey,
                subsystem: label.subsystem,
                target: label.target,
                callCount: samples.count,
                errorPercent: Int(Double(errorCount) / Double(samples.count) * 100.0),
                p50Milliseconds: percentile(durations, fraction: 0.50),
                p95Milliseconds: percentile(durations, fraction: 0.95)
            )
        }.sorted { $0.callCount > $1.callCount }

        totalTurnsInWindow = seenTurnIds.count
        lastRefreshAt = Date()
    }

    private func percentile(_ sortedSamples: [Int], fraction: Double) -> Int {
        guard !sortedSamples.isEmpty else { return 0 }
        let bucketIndex = min(sortedSamples.count - 1, Int(Double(sortedSamples.count) * fraction))
        return sortedSamples[bucketIndex]
    }
}
