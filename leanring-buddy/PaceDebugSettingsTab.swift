//
//  PaceDebugSettingsTab.swift
//  leanring-buddy
//
//  Settings → Debug tab. Renders the per-turn tool-call captures from
//  `CompanionManager.recentToolCallDebugRecords` so a command that spoke
//  something and did nothing becomes legible: which lane handled it, which
//  planner produced the audio, the RAW planner output, what parsed, and what
//  dispatched. Read-only diagnostics — session-only, never persisted.
//

import AppKit
import SwiftUI

struct PaceDebugSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tool calls")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Every recent voice or chat turn — the exact transcript, how it routed, per-turn latency, the planner's raw output, what parsed into tool calls, and what dispatch did. This is the place to see why a command that spoke something didn't act. Newest first.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Persisted to ~/Library/Application Support/Pace/tool-call-traces.jsonl (last 500 turns, including the exact planner prompt) for offline inspection.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !companionManager.recentToolCallDebugRecords.isEmpty {
                    paceSettingsButton("Clear", systemName: "xmark.circle") {
                        companionManager.clearToolCallDebugRecords()
                    }
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            if companionManager.recentToolCallDebugRecords.isEmpty {
                Text("No turns captured yet. Say or type a command — it shows up here.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                ForEach(companionManager.recentToolCallDebugRecords) { record in
                    debugRecordCard(record)
                }
            }
        }
    }

    private func debugRecordCard(_ record: PaceToolCallDebugRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                laneBadge(record.lane)
                Text("\"\(record.transcript)\"")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Text(Self.timeFormatter.string(from: record.createdAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            labeledValue("routing", record.routingDetail)
            if let plannerPathDetail = record.plannerPathDetail {
                labeledValue("planner", plannerPathDetail)
            }
            if let screenElementCount = record.screenElementCount {
                labeledValue("screen", "\(screenElementCount) element\(screenElementCount == 1 ? "" : "s") sent to planner")
            }
            if !record.latencyDisplay.isEmpty {
                labeledValue("latency", record.latencyDisplay)
            }

            // The single most diagnostic line when the race misfires: the
            // user heard a screenless Apple FM guess while the screen-aware
            // planner's action parsed separately.
            if let userHeardScreenlessAnswer = record.userHeardScreenlessAnswer,
               !userHeardScreenlessAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledBlock(
                    "you heard (screenless lite)",
                    userHeardScreenlessAnswer,
                    valueColor: DS.Colors.warning
                )
            }

            if !record.rawPlannerOutput.isEmpty {
                labeledBlock("raw planner output", record.rawPlannerOutput)
            }

            labeledBlock(
                "parsed tool calls",
                record.parsedActionsSummary,
                valueColor: record.parsedActionsSummary == "no actions parsed"
                    ? DS.Colors.warning
                    : DS.Colors.textPrimary
            )

            labeledValue("dispatch", record.dispatchSummary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
        )
    }

    private func laneBadge(_ lane: PaceToolCallDebugRecord.Lane) -> some View {
        let tint: Color
        switch lane {
        case .fastPath:
            tint = DS.Colors.accent
        case .textOnly:
            tint = DS.Colors.textSecondary
        case .planner:
            tint = DS.Colors.warning
        }
        return Text(lane.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func labeledBlock(
        _ label: String,
        _ value: String,
        valueColor: Color = DS.Colors.textPrimary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(valueColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.borderSubtle.opacity(0.22))
                .cornerRadius(6)
        }
    }
}
