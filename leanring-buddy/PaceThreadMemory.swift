//
//  PaceThreadMemory.swift
//  leanring-buddy
//
//  Two-tier in-context memory state for the planner. The verbatim
//  window of the last K turn pairs is the source of truth for nearby
//  context. The rolling summary captures everything older as a single
//  compact paragraph that ships in the system prompt as
//  `<conversation_so_far>...</conversation_so_far>`.
//
//  This file owns no I/O. It holds pure in-memory state and exposes a
//  testable API. The detached FM call that produces the summary lives
//  in `PaceThreadSummarizer.swift`. The call-site wiring that records
//  turns, prepends the injection block, and gates the idle timeout
//  lives in `CompanionManager`.
//
//  Lifetime: session-scoped and ephemeral. Never persisted to disk.
//  The user can audit and reset via Settings → Memory → Thread
//  summary, but the summary itself never leaves process memory.
//

import Foundation

// MARK: - Configuration

nonisolated struct PaceThreadMemoryConfiguration: Equatable {
    /// Number of recent turn pairs the planner sees verbatim. Anything
    /// older has already been folded into the rolling summary. Clamp
    /// at the Settings layer enforces 1...8 — wider windows defeat the
    /// point of the summary and bloat planner input.
    let verbatimWindowSize: Int

    /// How long the session can stay quiet before it's considered
    /// ended. On the next turn (or via the low-frequency timer in
    /// `CompanionManager`) the verbatim window + summary are dropped
    /// and `currentSessionId` is bumped.
    let sessionIdleThreshold: TimeInterval

    /// Soft cap the summarizer aims for; `applySummaryUpdate` also
    /// enforces a hard truncation as a fail-safe so a runaway summary
    /// can't grow unbounded.
    let summaryMaxTokenEstimate: Int

    static let `default` = PaceThreadMemoryConfiguration(
        verbatimWindowSize: 4,
        sessionIdleThreshold: 20 * 60,
        summaryMaxTokenEstimate: 400
    )
}

// MARK: - Turn pair

struct PaceThreadTurnPair: Equatable {
    let turnId: String
    let userText: String
    let assistantText: String
    let recordedAt: Date
}

// MARK: - Session end cause

enum PaceThreadSessionEndCause: Equatable {
    case idleTimeout
    case userReset
}

// MARK: - PaceThreadMemory

@MainActor
final class PaceThreadMemory {
    /// Token-character estimate ratio used by the fail-safe truncation
    /// in `applySummaryUpdate`. Four characters per token is the rough
    /// English heuristic the rest of Pace uses.
    private static let approximateCharactersPerToken = 4

    private let configuration: PaceThreadMemoryConfiguration

    private var currentSummary: String?
    private var currentSummaryVersion: Int = 0
    private var verbatimWindowStorage: [PaceThreadTurnPair] = []
    private var lastTurnRecordedAt: Date?
    private(set) var currentSessionId: String

    /// Monotonically increases each time the summarizer is asked to
    /// produce a new summary. The caller snapshots this value BEFORE
    /// firing the detached FM call and tags the resulting
    /// `applySummaryUpdate` with the snapshot. Out-of-order results
    /// are dropped.
    private(set) var nextSummaryVersionToAssign: Int = 1

    init(configuration: PaceThreadMemoryConfiguration = .default) {
        self.configuration = configuration
        self.currentSessionId = PaceThreadMemory.makeNewSessionId()
    }

    // MARK: - Read APIs

    /// The verbatim window in the order the planner expects (oldest
    /// first). Callers map this into `BuddyPlannerClient`'s positional
    /// `conversationHistory` parameter.
    func verbatimWindow() -> [PaceThreadTurnPair] {
        return verbatimWindowStorage
    }

    /// The leading addendum to inject into the system prompt. Returns
    /// nil until at least one turn has fallen out of the verbatim
    /// window AND a summarization update has landed. The wrapper tags
    /// match `CompanionSystemPrompt`'s expected layout.
    func injectionPrefix() -> String? {
        guard let summaryText = currentSummary else { return nil }
        let trimmedSummary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return nil }
        return "<conversation_so_far>\n\(trimmedSummary)\n</conversation_so_far>"
    }

    /// The raw summary text without wrapper tags. Used by the
    /// Settings debug surface (Show current summary).
    func currentSummaryText() -> String? {
        return currentSummary
    }

    /// Current version counter exposed for the Settings debug view.
    func currentSummaryVersionValue() -> Int {
        return currentSummaryVersion
    }

    // MARK: - Write APIs

    /// Append a completed turn pair. If the verbatim window overflows,
    /// the oldest pair slides off and is returned so the caller can
    /// hand it to the detached summarizer. Returning the displaced
    /// pair (instead of triggering summarization here) keeps this
    /// module I/O-free and lets `CompanionManager` own the detached
    /// task lifecycle.
    func record(
        userTurn: String,
        assistantTurn: String,
        turnId: String,
        now: Date
    ) -> PaceThreadTurnPair? {
        let newTurnPair = PaceThreadTurnPair(
            turnId: turnId,
            userText: userTurn,
            assistantText: assistantTurn,
            recordedAt: now
        )
        verbatimWindowStorage.append(newTurnPair)
        lastTurnRecordedAt = now

        guard verbatimWindowStorage.count > configuration.verbatimWindowSize else {
            return nil
        }
        return verbatimWindowStorage.removeFirst()
    }

    /// Reserve the next monotonic version number BEFORE firing a
    /// detached summarizer call. The returned value is what the
    /// caller must pass back into `applySummaryUpdate`. Bumping the
    /// counter here means two summarizer calls that race never get
    /// the same version, so out-of-order arrivals are detectable.
    func reserveNextSummaryVersion() -> Int {
        let reservedVersion = nextSummaryVersionToAssign
        nextSummaryVersionToAssign += 1
        return reservedVersion
    }

    /// Apply a summarizer result. Drops the update if a newer version
    /// has already landed (out-of-order race). Enforces the
    /// fail-safe character cap derived from
    /// `summaryMaxTokenEstimate`.
    func applySummaryUpdate(
        summary: String,
        summaryVersion: Int,
        updatedAt _: Date
    ) {
        guard summaryVersion > currentSummaryVersion else {
            return
        }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            return
        }
        let characterCap = configuration.summaryMaxTokenEstimate
            * PaceThreadMemory.approximateCharactersPerToken
        let truncatedSummary: String
        if trimmedSummary.count > characterCap {
            truncatedSummary = String(trimmedSummary.prefix(characterCap))
        } else {
            truncatedSummary = trimmedSummary
        }
        currentSummary = truncatedSummary
        currentSummaryVersion = summaryVersion
    }

    // MARK: - Session lifecycle

    /// Returns `.idleTimeout` iff the time since the last recorded
    /// turn exceeds the configured threshold. Caller invokes on every
    /// turn start AND from a low-frequency timer so the menu-bar
    /// surface can drop "session live" indicators without needing a
    /// new turn.
    func sessionDidIdle(now: Date) -> PaceThreadSessionEndCause? {
        guard let lastTurnRecordedAt else { return nil }
        let secondsSinceLastTurn = now.timeIntervalSince(lastTurnRecordedAt)
        guard secondsSinceLastTurn >= configuration.sessionIdleThreshold else {
            return nil
        }
        // Only signal idle once per actual session — when we have
        // state to drop. Empty state means we already reset.
        guard !verbatimWindowStorage.isEmpty || currentSummary != nil else {
            return nil
        }
        return .idleTimeout
    }

    /// Drop all session state. Used by the idle gate AND the Settings
    /// "Reset thread now" button. Bumps `currentSessionId` so the
    /// next turn starts fresh and any in-flight detached summarizer
    /// calls (tagged with the prior version sequence) will have their
    /// late `applySummaryUpdate` calls dropped by the version check —
    /// because we also reset `nextSummaryVersionToAssign`.
    func resetSession(cause _: PaceThreadSessionEndCause, now: Date) {
        currentSummary = nil
        currentSummaryVersion = 0
        nextSummaryVersionToAssign = 1
        verbatimWindowStorage.removeAll()
        lastTurnRecordedAt = nil
        currentSessionId = PaceThreadMemory.makeNewSessionId()
        _ = now // surface the parameter for log/audit callers
    }

    // MARK: - Helpers

    private static func makeNewSessionId() -> String {
        return "thread-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
