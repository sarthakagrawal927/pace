//
//  PaceRestraintGate.swift
//  leanring-buddy
//
//  Pure policy gate for proactive speech. Callers pass the current
//  context; the gate returns speak, stay quiet, or queue without doing
//  any I/O.
//

import Foundation

nonisolated enum PaceProactiveSource: String, Codable, Equatable, CaseIterable {
    case userPushToTalk
    case wakeWord
    case watchNudge
    case episodicRecall
    case timerFire
    case backgroundReminder
    /// The daily morning brief fired by `PaceMorningTriageScheduler`.
    /// Goes through the full gate (active-call check, proactive
    /// cooldown, intent confidence) so it stays silent during Zoom
    /// or while the user is mid-input.
    case morningTriage
}

/// User-tunable assertiveness profile for proactive speech. Default
/// is `.balanced`, which matches the PRD's original cooldown values
/// (10-minute focus / 30-second episodic). The picker lives in
/// Settings → Proactive.
nonisolated enum PaceProactivityProfile: String, Codable, Equatable, CaseIterable {
    /// Most assertive — shorter cooldowns. Pace speaks more often.
    case talkative
    /// Default — matches the PRD baseline. Recommended for most users.
    case balanced
    /// Least assertive — longest cooldowns. Pace speaks less often.
    case reserved
}

nonisolated struct PaceRestraintContext: Equatable {
    let now: Date
    let lastProactiveUtteranceAt: Date?
    let lastEpisodicRecallAt: Date?
    let lastUserInputAt: Date?
    let frontmostAppBundleIdentifier: String?
    let isOnActiveCall: Bool
    let wakeWordConfidence: Double?
    let intent: PaceIntent
    let proactiveSource: PaceProactiveSource
    /// Tunes the proactive cooldowns inside `decide(_:)`. Always
    /// required so the gate's behavior is fully reproducible from a
    /// context value alone; callers that don't care should pass
    /// `.balanced` (the PRD default).
    let profile: PaceProactivityProfile
    /// True when macOS reports a system Focus is active (Do Not
    /// Disturb / Work / Sleep / Personal / Driving / etc.). Treated
    /// as queue-until-idle, same semantics as `isOnActiveCall` —
    /// the user has signalled "do not interrupt me," so a proactive
    /// nudge waits until the Focus ends. Defaults to false so
    /// existing call sites that haven't been updated keep their
    /// pre-Focus-integration behaviour.
    let isInUserFocusMode: Bool

    init(
        now: Date,
        lastProactiveUtteranceAt: Date?,
        lastEpisodicRecallAt: Date?,
        lastUserInputAt: Date?,
        frontmostAppBundleIdentifier: String?,
        isOnActiveCall: Bool,
        wakeWordConfidence: Double?,
        intent: PaceIntent,
        proactiveSource: PaceProactiveSource,
        profile: PaceProactivityProfile,
        isInUserFocusMode: Bool = false
    ) {
        self.now = now
        self.lastProactiveUtteranceAt = lastProactiveUtteranceAt
        self.lastEpisodicRecallAt = lastEpisodicRecallAt
        self.lastUserInputAt = lastUserInputAt
        self.frontmostAppBundleIdentifier = frontmostAppBundleIdentifier
        self.isOnActiveCall = isOnActiveCall
        self.wakeWordConfidence = wakeWordConfidence
        self.intent = intent
        self.proactiveSource = proactiveSource
        self.profile = profile
        self.isInUserFocusMode = isInUserFocusMode
    }
}

nonisolated enum PaceRestraintDecision: Equatable {
    case speak
    case stayQuiet(reason: String)
    case queueUntilIdle(reason: String)
}

nonisolated enum PaceRestraintGate {
    static let activeInputWindowSeconds: TimeInterval = 3
    static let minimumWakeWordConfidence = 0.7

    /// Default cooldowns (the `.balanced` profile). Kept as `static let`s
    /// so existing call-site code that referenced them by name still
    /// resolves — they now describe the `.balanced` row in the
    /// profile-tuned cooldown table below.
    static let proactiveCooldownSeconds: TimeInterval = 10 * 60
    static let episodicRecallCooldownSeconds: TimeInterval = 30

    private static let activeCallBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.apple.facetime",
        "com.tinyspeck.slackmacgap",
        "com.google.chrome",
        "com.apple.Safari",
    ]

    /// Per-profile cooldown tuning. Talkative shortens the focus
    /// cooldown to keep nudges feeling responsive; reserved triples it
    /// so Pace effectively talks once per half-hour at most. Episodic
    /// recall is treated separately because the cost of repeating an
    /// episodic memory hint is qualitatively different from repeating
    /// a watch-style nudge.
    private static func cooldownSeconds(
        forProfile profile: PaceProactivityProfile,
        proactiveSource: PaceProactiveSource
    ) -> TimeInterval {
        switch proactiveSource {
        case .episodicRecall:
            switch profile {
            case .talkative: return 30
            case .balanced:  return 30
            case .reserved:  return 120
            }
        default:
            switch profile {
            case .talkative: return 5 * 60
            case .balanced:  return 10 * 60
            case .reserved:  return 30 * 60
            }
        }
    }

    static func decide(_ context: PaceRestraintContext) -> PaceRestraintDecision {
        switch context.proactiveSource {
        case .userPushToTalk, .timerFire:
            return .speak
        case .wakeWord, .watchNudge, .episodicRecall, .backgroundReminder, .morningTriage:
            break
        }

        if let wakeWordConfidence = context.wakeWordConfidence,
           wakeWordConfidence < minimumWakeWordConfidence {
            return .stayQuiet(reason: "wake word confidence below threshold")
        }

        // Active call OR recent user input both mean "the user is
        // doing something else right now". Park the nudge until they
        // pause; the manager-side drain loop will retry when both
        // signals clear. Treating these as queue-until-idle (vs the
        // old hard stayQuiet) is what lets a fatigue nudge that
        // arrives during a Zoom still speak the moment the call ends.
        if context.isOnActiveCall || frontmostAppLooksLikeActiveCall(context.frontmostAppBundleIdentifier) {
            return .queueUntilIdle(reason: "active call")
        }

        // macOS Focus modes (Do Not Disturb, Work, Sleep, Personal,
        // Driving, etc.) — the user has explicitly signalled "do not
        // interrupt me." Same queue-until-idle semantics as active
        // call so the morning brief / fatigue nudge / posture nudge
        // still speaks the moment the Focus ends, instead of being
        // permanently dropped.
        if context.isInUserFocusMode {
            return .queueUntilIdle(reason: "macOS Focus active")
        }

        // Recent user input: queue the nudge for the .talkative /
        // .balanced profiles so it speaks the moment the user pauses.
        // The .reserved profile is intentionally stricter — under
        // reserved we stay quiet outright rather than even queueing,
        // matching the pre-profile "don't speak over me" behavior the
        // user explicitly opted into.
        if let lastUserInputAt = context.lastUserInputAt,
           context.now.timeIntervalSince(lastUserInputAt) < activeInputWindowSeconds {
            switch context.profile {
            case .talkative, .balanced:
                return .queueUntilIdle(reason: "recent user input")
            case .reserved:
                return .stayQuiet(reason: "recent user input")
            }
        }

        if context.proactiveSource == .episodicRecall,
           let lastEpisodicRecallAt = context.lastEpisodicRecallAt,
           context.now.timeIntervalSince(lastEpisodicRecallAt) < cooldownSeconds(
               forProfile: context.profile,
               proactiveSource: .episodicRecall
           ) {
            return .stayQuiet(reason: "episodic recall cooldown")
        }

        if context.proactiveSource != .episodicRecall,
           let lastProactiveUtteranceAt = context.lastProactiveUtteranceAt,
           context.now.timeIntervalSince(lastProactiveUtteranceAt) < cooldownSeconds(
               forProfile: context.profile,
               proactiveSource: context.proactiveSource
           ) {
            return .stayQuiet(reason: "proactive cooldown")
        }

        if context.intent == .unknown {
            return .stayQuiet(reason: "low confidence intent")
        }

        return .speak
    }

    private static func frontmostAppLooksLikeActiveCall(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalizedIdentifier = bundleIdentifier.lowercased()
        if activeCallBundleIdentifiers.contains(normalizedIdentifier) {
            return true
        }
        return normalizedIdentifier.contains("zoom")
            || normalizedIdentifier.contains("teams")
            || normalizedIdentifier.contains("facetime")
            || normalizedIdentifier.contains("meet")
            || normalizedIdentifier.contains("huddle")
    }
}
