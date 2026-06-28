//
//  PaceBargeInVAD.swift
//  leanring-buddy
//
//  Tiny signal-level detector for barge-in tests and future audio-tap
//  wiring. Runtime callers feed normalized RMS samples while TTS is
//  playing; the detector fires only after sustained speech-like energy.
//
//  Echo rejection: when TTS is actively playing, the microphone can
//  pick up the speaker output as "speech." Cursor Voice and Vox both
//  solve this with an echo rejection window — a period after TTS
//  audio starts where mic input is discounted. We use a two-pronged
//  approach:
//    1. An echo suppression window after each TTS utterance starts
//       (default 300ms) where samples are ignored entirely.
//    2. A raised threshold during TTS playback — the mic needs to
//       see louder, more sustained input to count as barge-in while
//       the speaker is active.
//

import Foundation

nonisolated struct PaceBargeInVADConfiguration: Equatable {
    var speechLevelThreshold: Float = 0.12
    var sustainedSpeechDuration: TimeInterval = 0.6
    var maximumInterSampleGap: TimeInterval = 0.25
    /// Echo rejection: samples within this window after TTS starts
    /// are ignored entirely. Covers the direct-to-speaker latency
    /// plus the first syllable or two of TTS output that bleeds into
    /// the mic. Default 300ms — enough to skip the TTS onset spike
    /// without missing a genuine user interruption.
    var echoSuppressionWindowSeconds: TimeInterval = 0.3
    /// Raised threshold applied while TTS is actively playing. The
    /// mic needs to see louder input to count as barge-in when the
    /// speaker is producing sound. 0.20 vs the normal 0.12.
    var echoRaisedThreshold: Float = 0.20
    /// Longer sustained-speech requirement during TTS playback.
    /// Real user barge-in is intentional and sustained; TTS bleed
    /// tends to be bursty. 1.0s vs the normal 0.6s.
    var echoRaisedSustainedDuration: TimeInterval = 1.0
}

nonisolated struct PaceBargeInVAD {
    private let configuration: PaceBargeInVADConfiguration
    private var sustainedSpeechStartedAt: Date?
    private var lastSampleAt: Date?

    /// When TTS playback most recently started. Used for echo
    /// suppression window calculations.
    private var ttsPlaybackStartedAt: Date?

    /// Whether TTS is currently playing. When true, the raised
    /// threshold and sustained duration apply.
    private var ttsIsActive: Bool = false

    init(configuration: PaceBargeInVADConfiguration = PaceBargeInVADConfiguration()) {
        self.configuration = configuration
    }

    mutating func reset() {
        sustainedSpeechStartedAt = nil
        lastSampleAt = nil
        ttsPlaybackStartedAt = nil
        ttsIsActive = false
    }

    /// Notify the VAD that TTS playback has started. Begins the echo
    /// suppression window and raises the threshold for subsequent
    /// samples.
    mutating func setTTSPlaybackActive(_ active: Bool, at sampleDate: Date = Date()) {
        if active {
            ttsPlaybackStartedAt = sampleDate
            ttsIsActive = true
            // Reset any in-progress sustained speech detection —
            // what we were tracking might have been TTS bleed.
            sustainedSpeechStartedAt = nil
        } else {
            ttsIsActive = false
            ttsPlaybackStartedAt = nil
        }
    }

    mutating func observe(normalizedLevel: Float, at sampleDate: Date) -> Bool {
        defer { lastSampleAt = sampleDate }

        if let lastSampleAt,
           sampleDate.timeIntervalSince(lastSampleAt) > configuration.maximumInterSampleGap {
            sustainedSpeechStartedAt = nil
        }

        // Echo suppression window: ignore samples entirely for the
        // first N ms after TTS starts playing.
        if ttsIsActive, let ttsStart = ttsPlaybackStartedAt {
            let timeSinceTTSStart = sampleDate.timeIntervalSince(ttsStart)
            if timeSinceTTSStart < configuration.echoSuppressionWindowSeconds {
                return false
            }
        }

        // Apply raised threshold during TTS playback.
        let effectiveThreshold: Float = ttsIsActive
            ? configuration.echoRaisedThreshold
            : configuration.speechLevelThreshold
        let effectiveSustainedDuration: TimeInterval = ttsIsActive
            ? configuration.echoRaisedSustainedDuration
            : configuration.sustainedSpeechDuration

        guard normalizedLevel >= effectiveThreshold else {
            sustainedSpeechStartedAt = nil
            return false
        }

        if sustainedSpeechStartedAt == nil {
            sustainedSpeechStartedAt = sampleDate
        }

        guard let sustainedSpeechStartedAt else { return false }
        return sampleDate.timeIntervalSince(sustainedSpeechStartedAt) >= effectiveSustainedDuration
    }
}
