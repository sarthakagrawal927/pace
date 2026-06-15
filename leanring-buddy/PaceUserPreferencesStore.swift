//
//  PaceUserPreferencesStore.swift
//  leanring-buddy
//
//  Typed key namespace + load/save helpers for user-toggleable
//  preferences. Replaces three hand-rolled `UserDefaults
//  .object(forKey:) == nil ? default : bool(forKey:)` patterns scattered
//  across `CompanionManager` — each with its own stringly-typed key.
//
//  The `@Published` properties stay on `CompanionManager` so the
//  existing SwiftUI bindings keep working. This store owns only the
//  storage-layer concern: key strings, defaults, and (for one
//  preference) the Info.plist seed on first launch.
//
//  Adding a new boolean preference is two lines: add a case to
//  `PaceUserPreferenceKey`, and decide its default by calling either
//  `bool(_:default:)` or `boolWithInfoPlistSeed(_:infoPlistKey:)`.
//

import Foundation

enum PaceUserPreferenceKey: String {
    case useLocalVLMForScreenContext
    case isWalkingAvatarEnabled
    case isPaceCursorEnabled
    case areCursorAnnotationsEnabled
    case requiresActionApproval
    case isPostureWatchEnabled
    case isAlwaysListeningEnabled
    case areFocusFatigueNudgesEnabled
    case areCalendarNudgesEnabled
    case areWatchObservationNudgesEnabled
    /// Master switch for the rolling-summary + verbatim-window in-
    /// context memory. Default ON — see PRD
    /// docs/prds/conversational-thread-memory.md.
    case isThreadMemoryEnabled
    /// How many turn pairs the planner sees verbatim before older
    /// turns get folded into the rolling summary. Clamped 1...8.
    case threadMemoryVerbatimWindowSize
    /// How long the thread can stay quiet before its summary +
    /// verbatim window are dropped. Clamped 5...60 minutes.
    case threadMemoryIdleMinutes
    /// Reveals the live summary text in Settings for transparency /
    /// debugging. Default OFF — the summary is never user-facing.
    case isThreadMemoryDebugViewEnabled
    /// Opt-in handoff: when a thread session ends, feed the final
    /// rolling summary to the episodic-fact extractor. Default OFF
    /// because the summarizer is loose; the episodic extractor is
    /// precise. Coupling them risks low-confidence facts.
    case isThreadEndingEpisodicHandoffEnabled
    /// Master switch for the daily morning brief proactive feature.
    /// Default OFF — see PRD docs/prds/morning-triage.md.
    case isMorningTriageEnabled
    /// Hour-of-day component (0...23) at which the morning brief
    /// fires on weekdays. Clamped on read.
    case morningTriageHourOfDay
    /// Minute-of-hour component (0...59) at which the morning brief
    /// fires on weekdays. Clamped on read.
    case morningTriageMinuteOfHour
    /// User-tunable assertiveness profile for proactive speech. The
    /// raw string maps to a `PaceProactivityProfile` case via the
    /// store's typed accessor; unrecognized values fall back to
    /// `.balanced`. Default `.balanced` matches the original PRD
    /// cooldown values. See PRD docs/prds/restraint-and-proactivity.md.
    case proactivityProfile
    /// Opt-in: include sensitive-topic episodic facts (#health,
    /// #finance, #relationship) in the LOCAL CONTEXT block injected
    /// into the planner prompt. Default OFF — sensitive facts are
    /// still stored, just not surfaced into prompts until the user
    /// flips this in Settings → Memory. See PRD episodic-memory.md.
    case injectSensitiveEpisodicTopics
    /// Wave 4 speed lever: when ON, screen-action / screen-description
    /// turns race Apple FM (text-only, no screen context) against the
    /// full VLM-fed local planner — whichever streams first wins the
    /// TTS pipeline. Default ON because it is RAM-neutral (FM is
    /// already in-process) and the perceived latency win is large.
    /// Users disable it from Settings → Planner if they prefer the
    /// VLM-fed answer regardless of latency. See Wave 4 plan.
    case enableSpeculativePlannerRace
    /// Unified-memory recall (docs/prds/unified-memory.md, Phase 3): when
    /// ON, the LOCAL CONTEXT block is AUGMENTED with semantically-ranked
    /// entries from the unified memory index (durable facts + relevant past
    /// turns) alongside the lexical connector/history block. Default ON;
    /// safe because it degrades to lexical-only when embeddings are
    /// unavailable. Users can turn it off in Settings → Memory.
    case useUnifiedMemoryRecall
}

enum PaceUserPreferencesStore {
    /// Read a boolean preference. Returns `defaultValue` if the key has
    /// never been written.
    static func bool(_ key: PaceUserPreferenceKey, default defaultValue: Bool) -> Bool {
        guard let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool else {
            return defaultValue
        }
        return stored
    }

    /// Read a boolean preference, falling back to an Info.plist string
    /// value if the user has never touched the toggle. Used for one-off
    /// "seed from build config on first launch" cases.
    static func boolWithInfoPlistSeed(
        _ key: PaceUserPreferenceKey,
        infoPlistKey: String
    ) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
            return stored
        }
        let infoPlistRawValue = AppBundleConfiguration
            .stringValue(forKey: infoPlistKey)?
            .lowercased()
        return infoPlistRawValue == "true"
            || infoPlistRawValue == "1"
            || infoPlistRawValue == "yes"
    }

    static func setBool(_ value: Bool, for key: PaceUserPreferenceKey) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    /// Read an integer preference clamped to an inclusive range.
    /// Returns `defaultValue` (also clamped) if the key was never
    /// written. Used by the thread-memory picker controls so a bad
    /// UserDefaults value can never push the verbatim window above
    /// 8 or below 1.
    static func clampedInt(
        _ key: PaceUserPreferenceKey,
        default defaultValue: Int,
        in clampingRange: ClosedRange<Int>
    ) -> Int {
        let clampedDefault = min(max(defaultValue, clampingRange.lowerBound), clampingRange.upperBound)
        guard let storedRawValue = UserDefaults.standard.object(forKey: key.rawValue) as? Int else {
            return clampedDefault
        }
        return min(max(storedRawValue, clampingRange.lowerBound), clampingRange.upperBound)
    }

    static func setInt(_ value: Int, for key: PaceUserPreferenceKey) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    /// Read the user-tunable proactivity profile, falling back to
    /// `.balanced` on a missing or unrecognized value. The default is
    /// the PRD baseline (10-min focus cooldown, 30-sec episodic
    /// cooldown) so an upgrade-in-place changes nothing until the
    /// user opens Settings → Proactive.
    static func proactivityProfile() -> PaceProactivityProfile {
        let storedRawValue = UserDefaults.standard.string(forKey: PaceUserPreferenceKey.proactivityProfile.rawValue)
        guard let storedRawValue,
              let resolvedProfile = PaceProactivityProfile(rawValue: storedRawValue) else {
            return .balanced
        }
        return resolvedProfile
    }

    /// Persist the user-tunable proactivity profile.
    static func setProactivityProfile(_ profile: PaceProactivityProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: PaceUserPreferenceKey.proactivityProfile.rawValue)
    }
}

/// Storage-layer namespace for the smoke-test output channels written by
/// `PaceRuntimeSmokeTestHooks` and read out-of-process by
/// `scripts/smoke-runtime-hooks.sh` via the `defaults` CLI. These are NOT
/// user-toggleable preferences (no @Published binding, no Settings UI) —
/// they're a runtime breadcrumb trail for the smoke runner. They live in
/// `PaceUserPreferencesStore` because this file owns the codebase's only
/// UserDefaults key strings, so consolidating them here removes the
/// scattered stringly-typed keys the previous hand-rolled `DefaultsKey`
/// enum in `PaceRuntimeSmokeTestHooks` was hiding.
///
/// The raw key strings are intentionally byte-identical to what the smoke
/// script reads — changing them would break the external test harness.
enum PaceSmokeTestStateStore {

    // MARK: Key strings (must match scripts/smoke-runtime-hooks.sh)

    private enum SmokeKey: String {
        case ready = "PaceSmoke.ready"
        case lastPanelCommand = "PaceSmoke.lastPanelCommand"
        case lastSettingsCommand = "PaceSmoke.lastSettingsCommand"
        case lastCursorAnnotationsEnabled = "PaceSmoke.lastCursorAnnotationsEnabled"
        case lastApprovalAllowed = "PaceSmoke.lastApprovalAllowed"
        case lastClarificationState = "PaceSmoke.lastClarificationState"
        case lastClarifiedTranscript = "PaceSmoke.lastClarifiedTranscript"
    }

    // MARK: Writers (the smoke hook installer calls these)

    static func markSmokeHooksReady() {
        UserDefaults.standard.set(true, forKey: SmokeKey.ready.rawValue)
    }

    static func recordLastPanelCommand(_ commandName: String) {
        UserDefaults.standard.set(commandName, forKey: SmokeKey.lastPanelCommand.rawValue)
    }

    static func recordLastSettingsCommand(_ commandName: String) {
        UserDefaults.standard.set(commandName, forKey: SmokeKey.lastSettingsCommand.rawValue)
    }

    static func recordLastCursorAnnotationsEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: SmokeKey.lastCursorAnnotationsEnabled.rawValue)
    }

    static func recordLastApprovalAllowed(_ didAllow: Bool) {
        UserDefaults.standard.set(didAllow, forKey: SmokeKey.lastApprovalAllowed.rawValue)
    }

    static func recordLastClarificationState(_ stateName: String) {
        UserDefaults.standard.set(stateName, forKey: SmokeKey.lastClarificationState.rawValue)
    }

    static func recordLastClarifiedTranscript(_ transcript: String) {
        UserDefaults.standard.set(transcript, forKey: SmokeKey.lastClarifiedTranscript.rawValue)
    }
}
