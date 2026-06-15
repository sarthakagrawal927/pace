//
//  PaceThreadMemoryTests.swift
//  leanring-buddyTests
//
//  Pure unit tests for the in-memory two-tier conversational thread
//  memory module. The bulk of coverage lives here because the module
//  is intentionally I/O-free — every behavior is observable from its
//  public API.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceThreadMemoryTests {
    // MARK: - Helpers

    private func makeFixedDate(_ secondsSinceEpoch: TimeInterval) -> Date {
        return Date(timeIntervalSince1970: secondsSinceEpoch)
    }

    private func defaultConfiguration() -> PaceThreadMemoryConfiguration {
        PaceThreadMemoryConfiguration(
            verbatimWindowSize: 4,
            sessionIdleThreshold: 20 * 60,
            summaryMaxTokenEstimate: 400
        )
    }

    // MARK: - Verbatim window behavior

    @Test func recordingBelowWindowSizeDoesNotDisplaceAnything() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        for turnIndex in 0..<3 {
            let displaced = threadMemory.record(
                userTurn: "u\(turnIndex)",
                assistantTurn: "a\(turnIndex)",
                turnId: "turn-\(turnIndex)",
                now: makeFixedDate(1_000 + Double(turnIndex))
            )
            #expect(displaced == nil)
        }
        #expect(threadMemory.verbatimWindow().count == 3)
        #expect(threadMemory.verbatimWindow().first?.userText == "u0")
        #expect(threadMemory.verbatimWindow().last?.userText == "u2")
    }

    @Test func fifthTurnPushesFirstPairOutAndReturnsIt() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        var lastDisplacedPair: PaceThreadTurnPair? = nil
        for turnIndex in 0..<5 {
            lastDisplacedPair = threadMemory.record(
                userTurn: "user-text-\(turnIndex)",
                assistantTurn: "assistant-text-\(turnIndex)",
                turnId: "turn-\(turnIndex)",
                now: makeFixedDate(2_000 + Double(turnIndex))
            )
        }
        // First four recorded pairs fit in the window; the fifth
        // pushes out the oldest pair.
        #expect(lastDisplacedPair?.userText == "user-text-0")
        #expect(lastDisplacedPair?.assistantText == "assistant-text-0")
        #expect(threadMemory.verbatimWindow().count == 4)
        #expect(threadMemory.verbatimWindow().first?.userText == "user-text-1")
        #expect(threadMemory.verbatimWindow().last?.userText == "user-text-4")
    }

    // MARK: - Injection prefix

    @Test func injectionPrefixIsNilBeforeAnySummaryUpdate() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        for turnIndex in 0..<5 {
            _ = threadMemory.record(
                userTurn: "u\(turnIndex)",
                assistantTurn: "a\(turnIndex)",
                turnId: "turn-\(turnIndex)",
                now: makeFixedDate(3_000 + Double(turnIndex))
            )
        }
        // Displacement happened, but no summarizer call has landed
        // yet — the planner should see nil.
        #expect(threadMemory.injectionPrefix() == nil)
    }

    @Test func injectionPrefixWrapsAcceptedSummaryInExpectedTags() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let reservedVersion = threadMemory.reserveNextSummaryVersion()
        threadMemory.applySummaryUpdate(
            summary: "user is debugging actor isolation in PaceActionExecutor.",
            summaryVersion: reservedVersion,
            updatedAt: Date()
        )
        let injection = threadMemory.injectionPrefix()
        #expect(injection != nil)
        #expect(injection?.hasPrefix("<conversation_so_far>") == true)
        #expect(injection?.hasSuffix("</conversation_so_far>") == true)
        #expect(injection?.contains("PaceActionExecutor") == true)
    }

    @Test func emptyOrWhitespaceSummaryIsRejected() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let reservedVersion = threadMemory.reserveNextSummaryVersion()
        threadMemory.applySummaryUpdate(
            summary: "   \n  ",
            summaryVersion: reservedVersion,
            updatedAt: Date()
        )
        #expect(threadMemory.injectionPrefix() == nil)
        #expect(threadMemory.currentSummaryText() == nil)
    }

    // MARK: - Out-of-order race

    @Test func outOfOrderSummaryUpdateIsDropped() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let firstReservedVersion = threadMemory.reserveNextSummaryVersion()
        let secondReservedVersion = threadMemory.reserveNextSummaryVersion()

        // The newer call (second reserved version) lands first.
        threadMemory.applySummaryUpdate(
            summary: "newer summary",
            summaryVersion: secondReservedVersion,
            updatedAt: Date()
        )
        // The older call (first reserved version) lands later — must
        // be dropped because the held version is now greater.
        threadMemory.applySummaryUpdate(
            summary: "older stale summary",
            summaryVersion: firstReservedVersion,
            updatedAt: Date()
        )
        #expect(threadMemory.currentSummaryText() == "newer summary")
        #expect(threadMemory.currentSummaryVersionValue() == secondReservedVersion)
    }

    @Test func sameVersionAppliedTwiceDoesNotReplaceContent() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let reservedVersion = threadMemory.reserveNextSummaryVersion()
        threadMemory.applySummaryUpdate(
            summary: "first attempt",
            summaryVersion: reservedVersion,
            updatedAt: Date()
        )
        // Re-applying the same version is a no-op (strict >, not ≥).
        threadMemory.applySummaryUpdate(
            summary: "second attempt with same version",
            summaryVersion: reservedVersion,
            updatedAt: Date()
        )
        #expect(threadMemory.currentSummaryText() == "first attempt")
    }

    @Test func failsafeTruncationCapsRunawaySummary() async throws {
        let configuration = PaceThreadMemoryConfiguration(
            verbatimWindowSize: 4,
            sessionIdleThreshold: 20 * 60,
            // 10 tokens × 4 chars/token = 40 character cap.
            summaryMaxTokenEstimate: 10
        )
        let threadMemory = PaceThreadMemory(configuration: configuration)
        let reservedVersion = threadMemory.reserveNextSummaryVersion()
        let runawaySummary = String(repeating: "x", count: 500)
        threadMemory.applySummaryUpdate(
            summary: runawaySummary,
            summaryVersion: reservedVersion,
            updatedAt: Date()
        )
        let storedSummary = threadMemory.currentSummaryText()
        #expect(storedSummary != nil)
        #expect(storedSummary?.count == 40)
    }

    // MARK: - Idle gate

    @Test func sessionDidIdleReturnsNilBeforeThresholdElapses() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let firstTurnDate = makeFixedDate(10_000)
        _ = threadMemory.record(
            userTurn: "hi",
            assistantTurn: "hey",
            turnId: "turn-0",
            now: firstTurnDate
        )
        // 5 minutes < 20-minute threshold.
        let fiveMinutesLater = firstTurnDate.addingTimeInterval(5 * 60)
        #expect(threadMemory.sessionDidIdle(now: fiveMinutesLater) == nil)
    }

    @Test func sessionDidIdleReturnsIdleTimeoutAfterThreshold() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let firstTurnDate = makeFixedDate(10_000)
        _ = threadMemory.record(
            userTurn: "hi",
            assistantTurn: "hey",
            turnId: "turn-0",
            now: firstTurnDate
        )
        // 21 minutes > 20-minute threshold.
        let twentyOneMinutesLater = firstTurnDate.addingTimeInterval(21 * 60)
        #expect(threadMemory.sessionDidIdle(now: twentyOneMinutesLater) == .idleTimeout)
    }

    @Test func sessionDidIdleReturnsNilWhenStateAlreadyEmpty() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        // Fresh state: never recorded anything. Idle gate must not
        // fire because there is nothing to drop and no session to end.
        #expect(threadMemory.sessionDidIdle(now: makeFixedDate(99_999)) == nil)
    }

    // MARK: - Reset

    @Test func resetSessionDropsSummaryWindowAndBumpsSessionId() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        let originalSessionId = threadMemory.currentSessionId
        for turnIndex in 0..<5 {
            _ = threadMemory.record(
                userTurn: "u\(turnIndex)",
                assistantTurn: "a\(turnIndex)",
                turnId: "turn-\(turnIndex)",
                now: makeFixedDate(20_000 + Double(turnIndex))
            )
        }
        let reservedVersion = threadMemory.reserveNextSummaryVersion()
        threadMemory.applySummaryUpdate(
            summary: "earlier turns about debugging",
            summaryVersion: reservedVersion,
            updatedAt: Date()
        )

        threadMemory.resetSession(cause: .userReset, now: makeFixedDate(99_999))

        #expect(threadMemory.verbatimWindow().isEmpty)
        #expect(threadMemory.injectionPrefix() == nil)
        #expect(threadMemory.currentSummaryText() == nil)
        #expect(threadMemory.currentSessionId != originalSessionId)
    }

    @Test func resetSessionResetsVersionCounterSoLateUpdatesAreDropped() async throws {
        let threadMemory = PaceThreadMemory(configuration: defaultConfiguration())
        // Reserve a version from BEFORE the reset. After reset the
        // counter starts fresh — the stale version is now treated as
        // current and may or may not write, but version 1 from before
        // reset must not survive as the held version.
        let preResetVersion = threadMemory.reserveNextSummaryVersion()
        threadMemory.applySummaryUpdate(
            summary: "summary before reset",
            summaryVersion: preResetVersion,
            updatedAt: Date()
        )
        #expect(threadMemory.currentSummaryText() == "summary before reset")

        threadMemory.resetSession(cause: .userReset, now: Date())
        #expect(threadMemory.currentSummaryText() == nil)
        #expect(threadMemory.currentSummaryVersionValue() == 0)
    }

    // MARK: - Persistence snapshot / restore (resume across relaunch)

    @Test func snapshotThenRestoreReproducesWindowSummaryAndVersion() async throws {
        let source = PaceThreadMemory(configuration: defaultConfiguration())
        for turnIndex in 0..<3 {
            _ = source.record(
                userTurn: "user-\(turnIndex)",
                assistantTurn: "assistant-\(turnIndex)",
                turnId: "turn-\(turnIndex)",
                now: makeFixedDate(2_000 + Double(turnIndex))
            )
        }
        let reservedVersion = source.reserveNextSummaryVersion()
        source.applySummaryUpdate(
            summary: "earlier in the conversation we set up the morning brief",
            summaryVersion: reservedVersion,
            updatedAt: makeFixedDate(2_100)
        )

        let snapshot = source.snapshot(now: makeFixedDate(2_200))

        // A brand-new instance (simulating a relaunched app) restores the
        // exact verbatim window, summary text, and a version counter that
        // still sits strictly ahead of the restored summary version.
        let restored = PaceThreadMemory(configuration: defaultConfiguration())
        restored.restore(from: snapshot)

        #expect(restored.verbatimWindow().map(\.userText) == ["user-0", "user-1", "user-2"])
        #expect(restored.currentSummaryText() == "earlier in the conversation we set up the morning brief")
        #expect(restored.currentSummaryVersionValue() == reservedVersion)
        #expect(restored.reserveNextSummaryVersion() > reservedVersion)
    }

    @Test func restoreTrimsWindowToCurrentConfiguredSize() async throws {
        // Snapshot taken with a window of 4, restored into a memory
        // configured for a window of 2 (user shrank it between sessions).
        // Only the two most-recent pairs survive.
        let wideSource = PaceThreadMemory(configuration: defaultConfiguration())
        for turnIndex in 0..<4 {
            _ = wideSource.record(
                userTurn: "u\(turnIndex)",
                assistantTurn: "a\(turnIndex)",
                turnId: "t\(turnIndex)",
                now: makeFixedDate(3_000 + Double(turnIndex))
            )
        }
        let snapshot = wideSource.snapshot(now: makeFixedDate(3_100))

        let narrowConfiguration = PaceThreadMemoryConfiguration(
            verbatimWindowSize: 2,
            sessionIdleThreshold: 20 * 60,
            summaryMaxTokenEstimate: 400
        )
        let narrowMemory = PaceThreadMemory(configuration: narrowConfiguration)
        narrowMemory.restore(from: snapshot)

        #expect(narrowMemory.verbatimWindow().map(\.userText) == ["u2", "u3"])
    }

    @Test func restoredSnapshotEncodesAndDecodesThroughJSON() async throws {
        let source = PaceThreadMemory(configuration: defaultConfiguration())
        _ = source.record(
            userTurn: "remember my preferred browser is Firefox",
            assistantTurn: "got it, Firefox it is",
            turnId: "turn-json",
            now: makeFixedDate(4_000)
        )
        let snapshot = source.snapshot(now: makeFixedDate(4_050))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(snapshot)
        let decoded = try decoder.decode(PaceThreadMemorySnapshot.self, from: encoded)

        #expect(decoded == snapshot)
    }
}
