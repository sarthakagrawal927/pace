//
//  PaceQuickTogglesView.swift
//  leanring-buddy
//
//  Notch-panel quick-toggle rows: Read My Screen, Cursor Annotations,
//  Approve Risky Actions, Watch Mode. Each toggle reads/writes through
//  the existing CompanionManager setter so the storage layer
//  (PaceUserPreferencesStore) stays the single source of truth.
//  Extracted from CompanionPanelView.swift; the panel composition root
//  now embeds this view between the model/status info rows and the
//  permissions list.
//

import SwiftUI

struct PaceQuickTogglesView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            readScreenToggleRow
            cursorAnnotationsToggleRow
            tuitionModeToggleRow
            actionApprovalToggleRow
            watchModeToggleRow
        }
    }

    private var tuitionModeToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(companionManager.isTuitionModeEnabled ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Tuition Mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Pace draws and explains instead of clicking")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isTuitionModeEnabled },
                set: { companionManager.setIsTuitionModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var readScreenToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Read My Screen")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.useLocalVLMForScreenContext },
                set: { companionManager.setUseLocalVLMForScreenContext($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var cursorAnnotationsToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Cursor Annotations")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.areCursorAnnotationsEnabled },
                set: { companionManager.setCursorAnnotationsEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var actionApprovalToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Approve Risky Actions")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Ask before non-undoable or external changes")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.requiresActionApproval },
                set: { companionManager.setRequiresActionApproval($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var watchModeToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(companionManager.isWatchModeEnabled ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Watch Mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(companionManager.latestWatchModeSummary ?? "Report meaningful screen changes")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isWatchModeEnabled },
                set: { companionManager.setWatchModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }
}
