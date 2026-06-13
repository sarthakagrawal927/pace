//
//  PaceModelStatusView.swift
//  leanring-buddy
//
//  Notch-panel "model readiness" rows: LM Studio reachability, the two
//  active planner identifiers (main + answers), the ASR provider
//  readiness, and the active TTS voice with upgrade hints. Each row is
//  read-only — swapping the planner today still requires editing
//  Info.plist and rebuilding — but surfacing the values in the panel
//  saves users a debugging round when LM Studio isn't loaded or a
//  better Apple voice should be installed.
//
//  Extracted from CompanionPanelView.swift; the four rows used to live
//  inline as `lmStudioStatusRow` / `activePlannerInfoRow` /
//  `transcriptionProviderInfoRow` / `ttsVoiceInfoRow`. The composition
//  root now embeds this view and lets the inner VStack control the
//  per-row vertical padding, matching the previous visual layout.
//

import SwiftUI

struct PaceModelStatusView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            lmStudioStatusRow
            activePlannerInfoRow
            transcriptionProviderInfoRow
            ttsVoiceInfoRow
        }
    }

    /// Live indicator of whether Pace's configured LM Studio HTTP endpoint
    /// is reachable. Most user "Pace isn't responding" reports trace back
    /// to LM Studio being closed or not having loaded its models yet —
    /// surfacing the state in the panel saves a round of debugging.
    private var lmStudioStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: companionManager.isLMStudioReachable
                  ? "checkmark.seal.fill"
                  : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(companionManager.isLMStudioReachable
                                 ? DS.Colors.success
                                 : DS.Colors.warning)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("LM Studio")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                if !companionManager.isLMStudioReachable {
                    Text("Not running — open LM Studio and load the models. See SETUP_LOCAL.md.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Shows the active planner identifiers. Read-only — swapping the
    /// main planner today requires editing Info.plist and rebuilding.
    /// Short pure-answer turns can use a separate fast in-process model.
    private var activePlannerInfoRow: some View {
        VStack(spacing: 6) {
            plannerInfoLine(
                label: "Planner",
                value: companionManager.activePlannerDisplayName
            )
            plannerInfoLine(
                label: "Answers",
                value: companionManager.activeTextOnlyPlannerDisplayName
            )
        }
        .padding(.vertical, 4)
    }

    private func plannerInfoLine(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
    }

    private var transcriptionProviderInfoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: companionManager.isTranscriptionModelReady ? "waveform" : "hourglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(companionManager.isTranscriptionModelReady ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("ASR")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(companionManager.isTranscriptionModelReady ? "Ready" : "Loading model")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
        .padding(.vertical, 4)
    }

    private var ttsVoiceInfoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: companionManager.activeTTSVoiceSummary.needsUpgrade
                  ? "speaker.wave.2"
                  : "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(companionManager.activeTTSVoiceSummary.needsUpgrade
                                 ? DS.Colors.warning
                                 : DS.Colors.success)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("Voice")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(companionManager.activeTTSVoiceSummary.recommendationText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text(companionManager.activeTTSVoiceSummary.displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
        .padding(.vertical, 4)
    }
}
