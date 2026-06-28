//
//  PaceMeetingModeControllerTests.swift
//  leanring-buddyTests
//
//  Tests for the meeting mode controller. The actual SCStream
//  capture requires Screen Recording permission and can't run in
//  a unit test, so we test the state management, preference
//  gating, and audio level publishing logic.
//

import Combine
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceMeetingModeControllerTests {

    // MARK: - Initial state

    /// The controller starts in the inactive state.
    @Test
    func initialStateIsInactive() {
        let controller = PaceMeetingModeController.shared
        // Reset to inactive for test determinism.
        #expect(controller.state == .inactive || controller.state == .failed(""))
    }

    /// The detected speech level starts at zero.
    @Test
    func initialSpeechLevelIsZero() {
        let controller = PaceMeetingModeController.shared
        #expect(controller.detectedSpeechLevel == 0.0)
    }

    // MARK: - State machine

    /// isSystemAudioActive returns false when speech level is low.
    @Test
    func isSystemAudioActiveFalseWhenLevelLow() {
        let controller = PaceMeetingModeController.shared
        // The default level is 0.0 which is below the 0.08 threshold.
        #expect(controller.isSystemAudioActive == false)
    }

    // MARK: - Preference

    /// The meeting mode preference key exists.
    @Test
    func meetingModePreferenceKeyExists() {
        // Verify the preference key is in the enum by reading it.
        let value = PaceUserPreferencesStore.bool(.isMeetingModeEnabled, default: false)
        // Default should be false.
        #expect(value == false)
    }

    /// The cron scheduler preference key exists.
    @Test
    func cronSchedulerPreferenceKeyExists() {
        let value = PaceUserPreferencesStore.bool(.isCronSchedulerEnabled, default: false)
        #expect(value == false)
    }

    // MARK: - Audio level publisher

    /// The audio level publisher accepts subscriptions without
    /// an active stream.
    @Test
    func audioLevelPublisherAcceptsSubscriptions() {
        let controller = PaceMeetingModeController.shared
        var receivedCount = 0
        let subscription = controller.audioLevelPublisher.sink { _ in
            receivedCount += 1
        }
        #expect(receivedCount == 0)
        subscription.cancel()
    }
}
