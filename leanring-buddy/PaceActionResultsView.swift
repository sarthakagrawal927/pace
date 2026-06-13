//
//  PaceActionResultsView.swift
//  leanring-buddy
//
//  Notch-panel "Recent Actions" section. Renders up to three recent
//  PaceActionRunRecord entries from CompanionManager. Extracted from
//  CompanionPanelView.swift so the action history surface can evolve
//  (icons, hover preview, "show more") without bloating the root
//  panel composition.
//

import SwiftUI

struct PaceActionResultsView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("RECENT ACTIONS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                if companionManager.recentActionResults.isEmpty {
                    Text("None")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            if !companionManager.recentActionResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(companionManager.recentActionResults.prefix(3)) { actionResult in
                        actionResultRow(actionResult)
                    }
                }
            }
        }
    }

    private func actionResultRow(_ actionResult: PaceActionRunRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color(for: actionResult.status))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(actionResult.status.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color(for: actionResult.status))

                    Text(actionResult.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(actionResult.detail)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func color(for status: PaceActionRunStatus) -> Color {
        switch status {
        case .planned:
            return DS.Colors.accent
        case .completed:
            return DS.Colors.success
        case .failed, .skipped:
            return DS.Colors.warning
        case .denied:
            return DS.Colors.textTertiary
        }
    }
}
