//
//  PaceBargeInEchoRejectionTests.swift
//  leanring-buddyTests
//
//  Tests for the echo rejection window added to PaceBargeInVAD.
//  Verifies that TTS bleed does not trigger false barge-in, while
//  genuine user speech during TTS playback still fires.
//

import Foundation
import Testing
@testable import Pace

struct PaceBargeInEchoRejectionTests {

    // MARK: - Echo suppression window

    /// Samples within the echo suppression window (default 300ms)
    /// must be ignored entirely — even if they're very loud.
    @Test
    func echoSuppressionWindowIgnoresLoudSamples() {
        var detector = PaceBargeInVAD()
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)

        // Feed loud samples within the 300ms suppression window.
        #expect(detector.observe(normalizedLevel: 0.9, at: ttsStart.addingTimeInterval(0.05)) == false)
        #expect(detector.observe(normalizedLevel: 0.9, at: ttsStart.addingTimeInterval(0.10)) == false)
        #expect(detector.observe(normalizedLevel: 0.9, at: ttsStart.addingTimeInterval(0.20)) == false)
        #expect(detector.observe(normalizedLevel: 0.9, at: ttsStart.addingTimeInterval(0.29)) == false)
    }

    /// After the echo suppression window expires, samples above the
    /// raised threshold should start accumulating again.
    @Test
    func samplesAfterEchoWindowAreProcessed() {
        var detector = PaceBargeInVAD()
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)

        // After 300ms, the suppression window is over. Samples above
        // the raised threshold (0.20) should be processed.
        let afterWindow = ttsStart.addingTimeInterval(0.35)
        #expect(detector.observe(normalizedLevel: 0.25, at: afterWindow) == false)
    }

    // MARK: - Raised threshold during TTS

    /// During TTS playback, the threshold is raised from 0.12 to 0.20.
    /// A sample at 0.15 (above normal threshold but below raised)
    /// should NOT accumulate during TTS.
    @Test
    func raisedThresholdRejectsBorderlineSamplesDuringTTS() {
        var detector = PaceBargeInVAD()
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)

        // 0.15 is above the normal threshold (0.12) but below the
        // raised threshold (0.20). During TTS it should not fire.
        let afterWindow = ttsStart.addingTimeInterval(0.35)
        #expect(detector.observe(normalizedLevel: 0.15, at: afterWindow) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: afterWindow.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: afterWindow.addingTimeInterval(0.4)) == false)
        // Even after sustained duration, borderline samples don't fire.
        #expect(detector.observe(normalizedLevel: 0.15, at: afterWindow.addingTimeInterval(1.1)) == false)
    }

    /// During TTS playback, loud sustained speech (above raised
    /// threshold for the raised sustained duration) SHOULD fire.
    /// This is a genuine user interruption.
    @Test
    func loudSustainedSpeechDuringTTSFires() {
        var detector = PaceBargeInVAD()
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)

        // After the echo window, feed loud sustained speech.
        // Use 0.2s gaps (within the 0.25s max inter-sample gap).
        let afterWindow = ttsStart.addingTimeInterval(0.35)
        // Raised threshold is 0.20, raised sustained duration is 1.0s.
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.4)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.6)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.8)) == false)
        // Cross the 1.0s raised sustained duration.
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(1.05)) == true)
    }

    // MARK: - TTS state transitions

    /// When TTS is deactivated, the threshold and sustained duration
    /// return to normal values.
    @Test
    func deactivatingTTSRestoresNormalThreshold() {
        var detector = PaceBargeInVAD()
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)
        detector.setTTSPlaybackActive(false, at: ttsStart.addingTimeInterval(1.0))

        // Now a sample at 0.15 (above normal threshold 0.12) should
        // be processed normally. Use 0.2s gaps (within 0.25s max).
        let afterDeactivation = ttsStart.addingTimeInterval(1.1)
        #expect(detector.observe(normalizedLevel: 0.15, at: afterDeactivation) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: afterDeactivation.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: afterDeactivation.addingTimeInterval(0.4)) == false)
        // Cross the 0.6s normal sustained duration.
        #expect(detector.observe(normalizedLevel: 0.15, at: afterDeactivation.addingTimeInterval(0.65)) == true)
    }

    /// Setting TTS active resets any in-progress sustained speech
    /// detection — what we were tracking might have been TTS bleed.
    @Test
    func settingTTSActiveResetsSustainedSpeechWindow() {
        var detector = PaceBargeInVAD()
        let start = Date()

        // Accumulate some sustained speech (without TTS).
        // Use 0.2s gaps (within 0.25s max).
        #expect(detector.observe(normalizedLevel: 0.20, at: start) == false)
        #expect(detector.observe(normalizedLevel: 0.20, at: start.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.20, at: start.addingTimeInterval(0.4)) == false)

        // TTS starts — the accumulated window should reset.
        detector.setTTSPlaybackActive(true, at: start.addingTimeInterval(0.5))

        // After the echo window + raised sustained duration, it should
        // fire (not immediately from the pre-TTS accumulation).
        // Use 0.2s gaps.
        let afterWindow = start.addingTimeInterval(0.5 + 0.35)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.4)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.6)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(0.8)) == false)
        #expect(detector.observe(normalizedLevel: 0.30, at: afterWindow.addingTimeInterval(1.05)) == true)
    }

    // MARK: - Reset

    /// Reset clears all state including TTS state.
    @Test
    func resetClearsTTSState() {
        var detector = PaceBargeInVAD()
        detector.setTTSPlaybackActive(true)
        #expect(detector.observe(normalizedLevel: 0.9, at: Date()) == false)

        detector.reset()

        // After reset, TTS state is cleared so normal threshold applies.
        // Use 0.2s gaps (within 0.25s max).
        let start = Date()
        #expect(detector.observe(normalizedLevel: 0.15, at: start) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: start.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: start.addingTimeInterval(0.4)) == false)
        // Cross the 0.6s normal sustained duration.
        #expect(detector.observe(normalizedLevel: 0.15, at: start.addingTimeInterval(0.65)) == true)
    }

    // MARK: - No TTS active (backward compatibility)

    /// When TTS is never activated, the VAD behaves exactly like the
    /// original — normal threshold, normal sustained duration.
    @Test
    func noTTSStatePreservesOriginalBehavior() {
        var detector = PaceBargeInVAD()
        let start = Date()

        // Normal threshold is 0.12, normal sustained is 0.6s.
        #expect(detector.observe(normalizedLevel: 0.15, at: start) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: start.addingTimeInterval(0.2)) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: start.addingTimeInterval(0.4)) == false)
        #expect(detector.observe(normalizedLevel: 0.15, at: start.addingTimeInterval(0.62)) == true)
    }

    // MARK: - Custom configuration

    /// Custom echo suppression window is respected.
    @Test
    func customEchoSuppressionWindow() {
        let config = PaceBargeInVADConfiguration(
            echoSuppressionWindowSeconds: 0.5
        )
        var detector = PaceBargeInVAD(configuration: config)
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)

        // 0.4s is within the custom 0.5s window — should be ignored.
        #expect(detector.observe(normalizedLevel: 0.9, at: ttsStart.addingTimeInterval(0.4)) == false)
        // 0.55s is past the window — should be processed.
        #expect(detector.observe(normalizedLevel: 0.25, at: ttsStart.addingTimeInterval(0.55)) == false)
    }

    /// Custom raised threshold is respected.
    @Test
    func customRaisedThreshold() {
        let config = PaceBargeInVADConfiguration(
            echoSuppressionWindowSeconds: 0.0,
            echoRaisedThreshold: 0.5
        )
        var detector = PaceBargeInVAD(configuration: config)
        let ttsStart = Date()

        detector.setTTSPlaybackActive(true, at: ttsStart)

        // 0.3 is below the custom raised threshold of 0.5.
        #expect(detector.observe(normalizedLevel: 0.3, at: ttsStart.addingTimeInterval(0.1)) == false)
        // 0.6 is above the custom raised threshold.
        #expect(detector.observe(normalizedLevel: 0.6, at: ttsStart.addingTimeInterval(0.2)) == false)
    }
}
