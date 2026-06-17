//
//  PacePrivacyDashboardView.swift
//  leanring-buddy
//
//  Privacy dashboard surfaced as a sidebar entry in PaceMainWindow.
//  Renders the existing audit log (`PaceAPIAuditLog`) into a fixed
//  set of sections: a "0 bytes sent off-Mac" headline card, a
//  chronological audit table for every off-device call, a per-tier
//  count breakdown, a permission usage list, and a fixed data-
//  residency claim paragraph.
//
//  IMPORTANT: this view adds NO new tracking. It is a pure read-only
//  visualization layer over the JSONL audit log Pace already writes
//  from every subsystem (planner, vlm, tts, mcp, embeddings, etc.).
//

import AppKit
import Foundation
import SwiftUI

/// Off-device subsystem buckets used by the dashboard. These mirror
/// the `subsystem` values written into `PaceAPIAuditLog` from the
/// call sites that legitimately leave the Mac. Everything else is
/// considered local (planner, vlm, tts to local sidecar, mcp, action,
/// dictation, pipeline, embeddings).
enum PaceOffDeviceTier: String, CaseIterable, Identifiable {
    case directAPI = "Direct API"
    case cloudBridge = "Cloud bridge"
    /// MCP servers that route through a hosted gateway (e.g., Composio).
    /// Distinguished from local-stdio MCP servers (filesystem, fetch,
    /// applescript) which run on-device.
    case mcpHosted = "MCP (hosted)"

    var id: String { rawValue }
}

/// Pure aggregation of `PaceAPIAuditEntry` rows into the structure the
/// dashboard renders. Extracted from the view so it can be unit-tested
/// without SwiftUI.
struct PacePrivacyDashboardAggregator {

    /// MCP server slugs known to route off-device (their tool calls
    /// hit the hosted gateway, not the local Mac). Add a new slug
    /// here when adding any future hosted-MCP catalog entry —
    /// `PaceActionExecutor` also reads this set to decide whether to
    /// flip the off-device tint during a tool call.
    static let knownOffDeviceMCPServerSlugs: Set<String> = ["composio"]

    /// Subsystem -> tier classification. Anything not classified here
    /// is treated as on-device for the dashboard. MCP calls require
    /// the entry's `target` (server-prefixed) to decide whether the
    /// hosted gateway is involved, so the overload that takes a
    /// target is the one production code uses.
    static func tier(forSubsystem subsystem: String) -> PaceOffDeviceTier? {
        tier(forSubsystem: subsystem, target: nil)
    }

    /// Tier classifier that also considers the entry's `target`. MCP
    /// calls all share `subsystem == "mcp"` and the only thing that
    /// distinguishes a local stdio server from a hosted one is the
    /// server-slug prefix in the target — so we look at the target's
    /// `<slug>.` prefix and check it against
    /// `knownOffDeviceMCPServerSlugs`.
    static func tier(forSubsystem subsystem: String, target: String?) -> PaceOffDeviceTier? {
        if subsystem.hasPrefix("planner.directAPI") {
            return .directAPI
        }
        if subsystem == "planner.cloudBridge" || subsystem.hasPrefix("cloudBridge") {
            return .cloudBridge
        }
        if subsystem == "mcp", let target {
            let serverSlugFromTarget = target
                .split(separator: ".", maxSplits: 1)
                .first
                .map(String.init)?
                .lowercased() ?? ""
            if knownOffDeviceMCPServerSlugs.contains(serverSlugFromTarget) {
                return .mcpHosted
            }
        }
        return nil
    }

    struct AggregatedPerTierStats {
        let tier: PaceOffDeviceTier
        let callCount: Int
        let bytesSent: Int
    }

    struct AggregatedSnapshot {
        let totalOffDeviceBytesSent: Int
        let totalOffDeviceCallCount: Int
        let perTierStats: [AggregatedPerTierStats]
        /// Per-target byte totals — useful for the "X KB to claude.ai"
        /// fragment when traffic is non-zero. Sorted descending by bytes.
        let perTargetStats: [(target: String, bytesSent: Int)]
        /// Local-vs-off-device turn counts for the per-tier breakdown
        /// chart. "Turn" here is a coarse approximation: total entries
        /// per bucket (planner/local/cli/fm). Good enough for the
        /// "where do my turns go?" question without us tracking turns
        /// separately.
        let localPlannerEntryCount: Int
        let appleFoundationModelsEntryCount: Int
    }

    /// Build the dashboard snapshot from a flat list of audit entries.
    /// Bytes-sent is `inputCharacterCount` where available — this is
    /// the character count the call site sent up, which is the best
    /// proxy for "bytes that left the Mac" the audit log records.
    static func aggregate(
        auditEntries: [PaceAPIAuditEntry],
        sinceCutoff cutoffTimestamp: Date? = nil
    ) -> AggregatedSnapshot {
        let filteredEntries: [PaceAPIAuditEntry]
        if let cutoffTimestamp {
            filteredEntries = auditEntries.filter { $0.at >= cutoffTimestamp }
        } else {
            filteredEntries = auditEntries
        }

        var perTierByteTotals: [PaceOffDeviceTier: Int] = [:]
        var perTierCallCounts: [PaceOffDeviceTier: Int] = [:]
        var perTargetByteTotals: [String: Int] = [:]
        var totalBytes = 0
        var totalCalls = 0
        var localPlannerEntryCount = 0
        var appleFoundationModelsEntryCount = 0

        for entry in filteredEntries {
            if let tier = tier(forSubsystem: entry.subsystem, target: entry.target) {
                let bytesForEntry = entry.inputCharacterCount ?? 0
                perTierByteTotals[tier, default: 0] += bytesForEntry
                perTierCallCounts[tier, default: 0] += 1
                perTargetByteTotals[entry.target, default: 0] += bytesForEntry
                totalBytes += bytesForEntry
                totalCalls += 1
                continue
            }
            if entry.subsystem == "planner" {
                if entry.target.hasPrefix("apple-fm") || entry.target.contains("foundation") {
                    appleFoundationModelsEntryCount += 1
                } else {
                    localPlannerEntryCount += 1
                }
            }
        }

        let perTierStats = PaceOffDeviceTier.allCases.map { tier in
            AggregatedPerTierStats(
                tier: tier,
                callCount: perTierCallCounts[tier] ?? 0,
                bytesSent: perTierByteTotals[tier] ?? 0
            )
        }

        let perTargetStats = perTargetByteTotals
            .map { (target: $0.key, bytesSent: $0.value) }
            .sorted { $0.bytesSent > $1.bytesSent }

        return AggregatedSnapshot(
            totalOffDeviceBytesSent: totalBytes,
            totalOffDeviceCallCount: totalCalls,
            perTierStats: perTierStats,
            perTargetStats: perTargetStats,
            localPlannerEntryCount: localPlannerEntryCount,
            appleFoundationModelsEntryCount: appleFoundationModelsEntryCount
        )
    }
}

/// Human-friendly byte formatter. Pulled out for testability — the
/// dashboard's headline line ("0 bytes" vs "12 KB") is the single most
/// reviewed pixel of this view.
enum PacePrivacyByteFormatter {
    static func format(bytes: Int) -> String {
        if bytes <= 0 {
            return "0 bytes"
        }
        if bytes < 1024 {
            return "\(bytes) bytes"
        }
        let kilobytes = Double(bytes) / 1024.0
        if kilobytes < 1024 {
            return String(format: "%.1f KB", kilobytes)
        }
        let megabytes = kilobytes / 1024.0
        return String(format: "%.2f MB", megabytes)
    }
}

struct PacePrivacyDashboardView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var auditEntries: [PaceAPIAuditEntry] = []
    @State private var auditSearchQuery: String = ""
    @State private var auditTierFilter: PaceOffDeviceTier? = nil
    @State private var snapshot = PacePrivacyDashboardAggregator.AggregatedSnapshot(
        totalOffDeviceBytesSent: 0,
        totalOffDeviceCallCount: 0,
        perTierStats: [],
        perTargetStats: [],
        localPlannerEntryCount: 0,
        appleFoundationModelsEntryCount: 0
    )

    private let lookbackInHours: Int = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headlineCardSection
                auditTableSection
                perTierBreakdownSection
                permissionsAuditSection
                dataResidencyClaimSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refresh)
    }

    // MARK: - Headline card

    private var headlineCardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy")
                .font(.system(size: 22, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(headlineCardPrimaryText)
                    .font(.system(size: 18, weight: .semibold))
                Text(headlineCardSecondaryText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    private var headlineCardPrimaryText: String {
        let formattedBytes = PacePrivacyByteFormatter.format(bytes: snapshot.totalOffDeviceBytesSent)
        if snapshot.totalOffDeviceBytesSent <= 0 {
            return "In the last \(lookbackInHours)h, Pace sent 0 bytes off this Mac."
        }
        let topTarget = snapshot.perTargetStats.first?.target ?? "an external API"
        return "In the last \(lookbackInHours)h, Pace sent \(formattedBytes) off this Mac to \(topTarget)."
    }

    private var headlineCardSecondaryText: String {
        if snapshot.totalOffDeviceCallCount == 0 {
            return "Every planner, VLM, OCR, TTS, and MCP call stayed on this device. Numbers update live as Pace works."
        }
        let perTierFragments = snapshot.perTierStats
            .filter { $0.callCount > 0 }
            .map { "\($0.tier.rawValue): \($0.callCount) call(s) · \(PacePrivacyByteFormatter.format(bytes: $0.bytesSent))" }
        return perTierFragments.joined(separator: " · ")
    }

    // MARK: - Audit log table

    private var auditTableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Off-device audit log")
                .font(.system(size: 14, weight: .semibold))
            Text("Every byte Pace sent off this Mac in the last \(lookbackInHours)h. Searchable. No message content — only sizes and outcomes.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Search target / outcome…", text: $auditSearchQuery)
                    .textFieldStyle(.roundedBorder)
                Picker("Tier", selection: $auditTierFilter) {
                    Text("All").tag(PaceOffDeviceTier?.none)
                    ForEach(PaceOffDeviceTier.allCases) { tier in
                        Text(tier.rawValue).tag(PaceOffDeviceTier?.some(tier))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
            }

            if filteredOffDeviceEntries.isEmpty {
                Text(snapshot.totalOffDeviceCallCount == 0
                     ? "No off-device calls recorded."
                     : "No entries match the current filter.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    auditTableHeader
                    Divider()
                    ForEach(Array(filteredOffDeviceEntries.enumerated()), id: \.offset) { _, entry in
                        auditTableRow(entry: entry)
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private var auditTableHeader: some View {
        HStack(spacing: 8) {
            Text("Time").font(.system(size: 11, weight: .semibold)).frame(width: 90, alignment: .leading)
            Text("Tier").font(.system(size: 11, weight: .semibold)).frame(width: 110, alignment: .leading)
            Text("Target").font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            Text("Sent").font(.system(size: 11, weight: .semibold)).frame(width: 70, alignment: .trailing)
            Text("Recv").font(.system(size: 11, weight: .semibold)).frame(width: 70, alignment: .trailing)
            Text("Outcome").font(.system(size: 11, weight: .semibold)).frame(width: 90, alignment: .leading)
        }
        .foregroundColor(.secondary)
        .padding(.vertical, 6)
    }

    private func auditTableRow(entry: PaceAPIAuditEntry) -> some View {
        let tier = PacePrivacyDashboardAggregator.tier(forSubsystem: entry.subsystem)
        return HStack(spacing: 8) {
            Text(entry.at.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            Text(tier?.rawValue ?? entry.subsystem)
                .font(.system(size: 11))
                .frame(width: 110, alignment: .leading)
            Text(entry.target)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(PacePrivacyByteFormatter.format(bytes: entry.inputCharacterCount ?? 0))
                .font(.system(size: 11))
                .frame(width: 70, alignment: .trailing)
            Text(PacePrivacyByteFormatter.format(bytes: entry.outputCharacterCount ?? 0))
                .font(.system(size: 11))
                .frame(width: 70, alignment: .trailing)
            Text(entry.outcome)
                .font(.system(size: 11))
                .foregroundColor(entry.outcome == "ok" ? .secondary : .orange)
                .frame(width: 90, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var filteredOffDeviceEntries: [PaceAPIAuditEntry] {
        let offDeviceEntries = auditEntries.filter {
            PacePrivacyDashboardAggregator.tier(forSubsystem: $0.subsystem) != nil
        }
        let tierFiltered: [PaceAPIAuditEntry]
        if let auditTierFilter {
            tierFiltered = offDeviceEntries.filter {
                PacePrivacyDashboardAggregator.tier(forSubsystem: $0.subsystem) == auditTierFilter
            }
        } else {
            tierFiltered = offDeviceEntries
        }
        let trimmedQuery = auditSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return tierFiltered.reversed() // newest first
        }
        return tierFiltered.filter { entry in
            entry.target.lowercased().contains(trimmedQuery)
                || entry.outcome.lowercased().contains(trimmedQuery)
        }.reversed()
    }

    // MARK: - Per-tier breakdown

    private var perTierBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where your turns ran (last \(lookbackInHours)h)")
                .font(.system(size: 14, weight: .semibold))
            Text("Counts are planner-completion entries grouped by where the model lived.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            let breakdownRows = perTierBreakdownRows
            let totalCallCount = breakdownRows.reduce(0) { $0 + $1.callCount }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(breakdownRows, id: \.label) { row in
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 140, alignment: .leading)
                        ProgressView(
                            value: totalCallCount == 0 ? 0 : Double(row.callCount) / Double(max(totalCallCount, 1))
                        )
                        .progressViewStyle(.linear)
                        Text("\(row.callCount)")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
        }
    }

    private struct PerTierBreakdownRow {
        let label: String
        let callCount: Int
    }

    private var perTierBreakdownRows: [PerTierBreakdownRow] {
        let directAPIStats = snapshot.perTierStats.first { $0.tier == .directAPI }
        let cloudBridgeStats = snapshot.perTierStats.first { $0.tier == .cloudBridge }
        return [
            PerTierBreakdownRow(label: "Local planner", callCount: snapshot.localPlannerEntryCount),
            PerTierBreakdownRow(label: "Apple FM", callCount: snapshot.appleFoundationModelsEntryCount),
            PerTierBreakdownRow(label: "CLI bridge", callCount: cloudBridgeStats?.callCount ?? 0),
            PerTierBreakdownRow(label: "Direct API", callCount: directAPIStats?.callCount ?? 0)
        ]
    }

    // MARK: - Permissions audit

    private var permissionsAuditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions Pace has and uses")
                .font(.system(size: 14, weight: .semibold))
            Text("Cross-references the macOS grants with the audit log so you can see which permissions Pace actually exercises.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(permissionAuditRows, id: \.label) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 160, alignment: .leading)
                        Text(row.grantStatus)
                            .font(.system(size: 12))
                            .foregroundColor(row.isGranted ? .green : .secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(row.lastUsedText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.3)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
        }
    }

    private struct PermissionAuditRow {
        let label: String
        let isGranted: Bool
        let lastUsedText: String

        var grantStatus: String { isGranted ? "Granted" : "Not granted" }
    }

    private var permissionAuditRows: [PermissionAuditRow] {
        func lastUsedText(forSubsystem subsystem: String, fallback: String = "Not used yet") -> String {
            guard let lastTimestamp = PaceAPIAuditLog.shared.lastEntryTimestamp(forSubsystem: subsystem) else {
                return fallback
            }
            return "Last used \(lastTimestamp.formatted(date: .abbreviated, time: .shortened))"
        }
        return [
            PermissionAuditRow(
                label: "Accessibility",
                isGranted: companionManager.hasAccessibilityPermission,
                lastUsedText: lastUsedText(forSubsystem: "action")
            ),
            PermissionAuditRow(
                label: "Screen Recording",
                isGranted: companionManager.hasScreenRecordingPermission,
                lastUsedText: lastUsedText(forSubsystem: "vlm")
            ),
            PermissionAuditRow(
                label: "Microphone",
                isGranted: companionManager.hasMicrophonePermission,
                lastUsedText: lastUsedText(forSubsystem: "dictation")
            ),
            PermissionAuditRow(
                label: "Calendar",
                isGranted: companionManager.hasCalendarPermission,
                lastUsedText: lastUsedText(forSubsystem: "action", fallback: "Not exercised in recent log")
            ),
            PermissionAuditRow(
                label: "Reminders",
                isGranted: companionManager.hasRemindersPermission,
                lastUsedText: lastUsedText(forSubsystem: "action", fallback: "Not exercised in recent log")
            )
        ]
    }

    // MARK: - Data residency claim

    private var dataResidencyClaimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Data residency")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Pace runs every planner, VLM, OCR, TTS, and MCP call on this Mac by default. No transcripts, screenshots, or audio leave the device.")
                Text("Deliberate exceptions, all opt-in:")
                    .padding(.top, 4)
                bulletText("download_file fetches a URL you name into ~/Downloads — no other bytes are sent.")
                bulletText("Cloud bridge (off by default) routes a turn through your already-authenticated Claude Code / Codex / Gemini CLI on this Mac. The CLI itself contacts the upstream provider.")
                bulletText("Direct API mode (off by default) sends the prompt directly to the configured provider with your API key.")
                Text("Off-device calls always show up in the audit log above. Pace never silently uploads anything.")
                    .padding(.top, 4)
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bulletText(_ body: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(body)
        }
    }

    // MARK: - Refresh

    private func refresh() {
        let allEntries = PaceAPIAuditLog.shared.readAllEntries()
        let cutoffTimestamp = Date().addingTimeInterval(-TimeInterval(lookbackInHours) * 3600)
        let windowedEntries = allEntries.filter { $0.at >= cutoffTimestamp }
        auditEntries = windowedEntries
        snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: windowedEntries)
    }
}
