//
//  PaceGeneralSettingsTab.swift
//  leanring-buddy
//
//  Settings → General tab content. Default landing surface: read-my-
//  screen, approve risky actions, cursor annotations, watch mode,
//  always listening, the four nudge toggles, posture watch, and the
//  morning brief subsection (toggle + hour/minute pickers + send-it-now
//  preview button).
//

import SwiftUI

struct PaceGeneralSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            paceSettingsToggleRow(
                title: "Read my screen",
                subtitle: "Use local screen context when a turn needs it.",
                isOn: Binding(
                    get: { companionManager.useLocalVLMForScreenContext },
                    set: { companionManager.setUseLocalVLMForScreenContext($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Approve risky actions",
                subtitle: "Ask before non-undoable local changes, message drafts, shortcuts, and MCP calls.",
                isOn: Binding(
                    get: { companionManager.requiresActionApproval },
                    set: { companionManager.setRequiresActionApproval($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Cursor annotations",
                subtitle: "Show transcript, response, and pointer labels near the cursor.",
                isOn: Binding(
                    get: { companionManager.areCursorAnnotationsEnabled },
                    set: { companionManager.setCursorAnnotationsEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Tuition mode",
                subtitle: "Pace teaches instead of acts: it draws shapes on screen and explains the step, rather than clicking through for you. Turn off when you want it to just do the thing.",
                isOn: Binding(
                    get: { companionManager.isTuitionModeEnabled },
                    set: { companionManager.setIsTuitionModeEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Watch mode",
                subtitle: companionManager.latestWatchModeSummary ?? "Watch for meaningful screen changes.",
                isOn: Binding(
                    get: { companionManager.isWatchModeEnabled },
                    set: { companionManager.setWatchModeEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Always listening",
                subtitle: "Opt-in ambient command mode. Push-to-talk remains available.",
                isOn: Binding(
                    get: { companionManager.isAlwaysListeningEnabled },
                    set: { companionManager.setAlwaysListeningEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Focus nudges",
                subtitle: "Offer a short break prompt after long active foreground sessions.",
                isOn: Binding(
                    get: { companionManager.areFocusFatigueNudgesEnabled },
                    set: { companionManager.setFocusFatigueNudgesEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Calendar nudges",
                subtitle: "Opt-in five-minute lead-time prompts for meeting-like events.",
                isOn: Binding(
                    get: { companionManager.areCalendarNudgesEnabled },
                    set: { companionManager.setCalendarNudgesEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Watch observation nudges",
                subtitle: "Opt-in prompts when watch mode sees local error/build-failure cues.",
                isOn: Binding(
                    get: { companionManager.areWatchObservationNudgesEnabled },
                    set: { companionManager.setWatchObservationNudgesEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Posture watch (camera)",
                subtitle: companionManager.latestPostureStatus
                    ?? "Gentle spoken nudge when you slouch or lean in. One camera frame every ten seconds, analyzed on-device, never stored.",
                isOn: Binding(
                    get: { companionManager.isPostureWatchEnabled },
                    set: { companionManager.setPostureWatchEnabled($0) }
                )
            )
            if companionManager.isPostureWatchEnabled {
                HStack {
                    Spacer()
                    paceSettingsButton("Recalibrate posture", systemName: "figure.seated.side") {
                        companionManager.recalibratePostureWatch()
                    }
                }
                .padding(.top, 6)
            }

            morningBriefSubsection
                .padding(.top, 18)
        }
    }

    // MARK: - Morning brief subsection

    /// Settings → General → Morning brief. Toggle + hour/minute pickers
    /// + a "Send it now" preview button. The toggle is opt-in (default
    /// OFF in `PaceUserPreferencesStore`); the preview button always
    /// works so users can tune brief content before committing to a
    /// daily fire time.
    private var morningBriefSubsection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Morning brief")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            paceSettingsToggleRow(
                title: "Daily morning brief",
                subtitle: "Calm 30-second spoken brief at the configured weekday time. Gated by the same active-call rules as other proactive features.",
                isOn: Binding(
                    get: { companionManager.isMorningTriageEnabled },
                    set: { companionManager.setMorningTriageEnabled($0) }
                )
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fire time")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Local time, weekdays only. Saturday and Sunday are skipped.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Picker(
                    "Hour",
                    selection: Binding(
                        get: { companionManager.morningTriageHourOfDay },
                        set: { companionManager.setMorningTriageHourOfDay($0) }
                    )
                ) {
                    ForEach(0..<24, id: \.self) { hourOfDayCandidate in
                        Text(String(format: "%02d", hourOfDayCandidate))
                            .tag(hourOfDayCandidate)
                    }
                }
                .labelsHidden()
                .frame(width: 60)

                Text(":")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                Picker(
                    "Minute",
                    selection: Binding(
                        get: { companionManager.morningTriageMinuteOfHour },
                        set: { companionManager.setMorningTriageMinuteOfHour($0) }
                    )
                ) {
                    ForEach(0..<60, id: \.self) { minuteOfHourCandidate in
                        Text(String(format: "%02d", minuteOfHourCandidate))
                            .tag(minuteOfHourCandidate)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            HStack {
                Spacer()
                paceSettingsButton("Send it now", systemName: "paperplane") {
                    companionManager.deliverMorningBriefPreviewNow()
                }
            }
            .padding(.top, 8)
        }
    }
}
