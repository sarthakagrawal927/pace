//
//  CompanionManager+ProactivitySettings.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A5):
//  always-listening toggle, proactive nudge generator toggles, and proactivity profile setter.
//

import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Proactivity profile

    func setAlwaysListeningEnabled(_ enabled: Bool) {
        isAlwaysListeningEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .isAlwaysListeningEnabled)
    }
    func setFocusFatigueNudgesEnabled(_ enabled: Bool) {
        areFocusFatigueNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areFocusFatigueNudgesEnabled)
        proactivityPipeline.setGeneratorEnabled(
            identifier: proactivityPipeline.focusFatigueNudgeGeneratorIdentifier,
            enabled: enabled
        )
    }
    func setCalendarNudgesEnabled(_ enabled: Bool) {
        areCalendarNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areCalendarNudgesEnabled)
        proactivityPipeline.setGeneratorEnabled(
            identifier: proactivityPipeline.calendarPreMeetingNudgeGeneratorIdentifier,
            enabled: enabled
        )
    }
    func setWatchObservationNudgesEnabled(_ enabled: Bool) {
        areWatchObservationNudgesEnabled = enabled
        PaceUserPreferencesStore.setBool(enabled, for: .areWatchObservationNudgesEnabled)
        proactivityPipeline.setGeneratorEnabled(
            identifier: proactivityPipeline.watchModeObservationNudgeGeneratorIdentifier,
            enabled: enabled
        )
    }
    func setProactivityProfile(_ profile: PaceProactivityProfile) {
        proactivityProfile = profile
    }
}
