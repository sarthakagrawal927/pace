//
//  PaceMemoryRetrievalSummaryView.swift
//  leanring-buddy
//
//  Notch-panel "Local Memory" section. Renders the two summary lines
//  (durable memory + retrieval index status) so the user sees what
//  Pace knows locally without leaving the panel. Extracted from
//  CompanionPanelView.swift; both summary strings come from
//  CompanionManager already.
//

import SwiftUI

struct PaceMemoryRetrievalSummaryView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LOCAL MEMORY")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text(companionManager.localMemorySummary)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text(companionManager.localRetrievalSummary)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
        }
    }
}
