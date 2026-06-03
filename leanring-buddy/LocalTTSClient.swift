//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  On-device TTS via Apple's AVSpeechSynthesizer. No network calls,
//  free, private, and offline. The sole BuddyTTSClient conformer
//  today — install a Premium English voice (System Settings →
//  Accessibility → Spoken Content → System Voice → Manage Voices) for
//  the best quality.
//

import AVFoundation
import Foundation

@MainActor
final class LocalTTSClient: NSObject, BuddyTTSClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    // Tracks whether we have an utterance currently being spoken. We can't
    // rely solely on AVSpeechSynthesizer.isSpeaking because there's a brief
    // window between calling speak() and the audio actually starting where
    // isSpeaking returns false but playback is imminent. Without our own flag,
    // CompanionManager's `while ttsClient.isPlaying` poll would exit early.
    private var isCurrentlySpeakingOrPending = false

    /// The voice identifier to use. Defaults to the system "enhanced" or
    /// "premium" English voice when available, which is markedly better
    /// than the legacy compact voice.
    private let preferredVoiceIdentifier: String?
    private let speechProsody: LocalTTSProsody

    /// Cached `bestAvailableVoice()` result. `AVSpeechSynthesisVoice
    /// .speechVoices()` does a synchronous metadata scan that can take
    /// 50-200ms — calling it on every `speakText()` invocation (which
    /// happens once per sentence-chunk while streaming) shows up as
    /// the "Potential Structural Swift Concurrency Issue: unsafeForcedSync
    /// called from Swift Concurrent context" warning AND as visible
    /// per-chunk jank. Computed once on first use.
    private var memoizedBestVoice: AVSpeechSynthesisVoice?
    private var hasResolvedBestVoice: Bool = false

    /// The shared delegate that flips `isCurrentlySpeakingOrPending`
    /// back to false when AVSpeechSynthesizer finishes its queue. One
    /// observer for the synthesiser's whole lifetime (not per utterance)
    /// so completion callbacks aren't lost when streaming multiple
    /// utterances back to back.
    private var playbackCompletionObserver: LocalTTSPlaybackCompletionObserver?

    override init() {
        // Allow callers to override via Info.plist for experimentation.
        let configuredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoiceIdentifier")
        self.preferredVoiceIdentifier = configuredVoiceIdentifier
        self.speechProsody = LocalTTSProsody.fromBundleConfiguration()
        super.init()

        // Install the playback observer exactly once. AVSpeechSynthesizer
        // calls delegate methods on an arbitrary thread, so the observer
        // hops back to MainActor before touching this object's state.
        let observer = LocalTTSPlaybackCompletionObserver { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Only clear the pending flag if the synthesiser also
                // reports no more queued utterances — otherwise we'd
                // flip false between chunks of the same response.
                if !self.speechSynthesizer.isSpeaking {
                    self.isCurrentlySpeakingOrPending = false
                }
            }
        }
        self.playbackCompletionObserver = observer
        self.speechSynthesizer.delegate = observer
    }

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Mark pending immediately so isPlaying returns true between this
        // call and the synthesizer actually starting audio output.
        isCurrentlySpeakingOrPending = true

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.rate = speechProsody.rate
        utterance.pitchMultiplier = speechProsody.pitchMultiplier
        utterance.volume = speechProsody.volume
        utterance.preUtteranceDelay = speechProsody.preUtteranceDelay
        utterance.postUtteranceDelay = speechProsody.postUtteranceDelay
        let pickedVoice = resolveCachedBestVoice()
        utterance.voice = pickedVoice
        printVoiceUpgradeHintOnceIfCompact(pickedVoice: pickedVoice)

        speechSynthesizer.speak(utterance)
        print("🔊 Local TTS: speaking \(trimmedText.count) chars")
    }

    /// Returns the best-available voice, computing it on first call and
    /// caching the result. The `AVSpeechSynthesisVoice.speechVoices()`
    /// scan inside `bestAvailableVoice()` is too expensive to do per
    /// utterance with sentence-level streaming.
    private func resolveCachedBestVoice() -> AVSpeechSynthesisVoice? {
        if hasResolvedBestVoice {
            return memoizedBestVoice
        }
        memoizedBestVoice = bestAvailableVoice()
        hasResolvedBestVoice = true
        return memoizedBestVoice
    }

    var isPlaying: Bool {
        isCurrentlySpeakingOrPending || speechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isCurrentlySpeakingOrPending = false
    }

    private func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        PaceTTSVoiceResolver.bestAvailableVoice(preferredVoiceIdentifier: preferredVoiceIdentifier)
    }

    /// Prints a one-time, plain-language hint to the Xcode console when
    /// the system is falling back to a compact voice (the default
    /// "Samantha" tier that often sounds shrill / robotic). Users hear
    /// this and assume the app is broken; pointing them at Premium
    /// voices in System Settings fixes it without code change.
    private var hasPrintedVoiceUpgradeHint: Bool = false
    private func printVoiceUpgradeHintOnceIfCompact(pickedVoice: AVSpeechSynthesisVoice?) {
        guard !hasPrintedVoiceUpgradeHint else { return }
        guard let pickedVoice else { return }
        switch pickedVoice.quality {
        case .premium, .enhanced:
            print("🔊 Local TTS voice: \(pickedVoice.name) (\(pickedVoice.quality == .premium ? "Premium" : "Enhanced"))")
        default:
            print("🔊 Local TTS voice: \(pickedVoice.name) (Compact, softened with Pace prosody)")
            print("    → For a bigger quality jump, open System Settings → Accessibility → Spoken Content")
            print("      → System Voice → Manage Voices → English (US) and download either:")
            print("        - \"Samantha\" at Enhanced quality (~150 MB, quick stopgap), OR")
            print("        - \"Ava\" at Premium quality (~500 MB, much better neural voice).")
            print("      Restart Pace after the download finishes.")
        }
        hasPrintedVoiceUpgradeHint = true
    }
}

private struct LocalTTSProsody {
    let rate: Float
    let pitchMultiplier: Float
    let volume: Float
    let preUtteranceDelay: TimeInterval
    let postUtteranceDelay: TimeInterval

    static func fromBundleConfiguration() -> LocalTTSProsody {
        // The defaults are tuned for the compact macOS voices this machine
        // currently has installed: a touch slower, lower pitched, and less
        // piercing than AVSpeechUtterance's stock conversational setting.
        return LocalTTSProsody(
            rate: configuredFloat(
                forKey: "LocalTTSSpeechRate",
                defaultValue: 0.48,
                minimumValue: 0.35,
                maximumValue: 0.58
            ),
            pitchMultiplier: configuredFloat(
                forKey: "LocalTTSPitchMultiplier",
                defaultValue: 0.94,
                minimumValue: 0.75,
                maximumValue: 1.15
            ),
            volume: configuredFloat(
                forKey: "LocalTTSVolume",
                defaultValue: 0.94,
                minimumValue: 0.25,
                maximumValue: 1.0
            ),
            preUtteranceDelay: TimeInterval(configuredFloat(
                forKey: "LocalTTSPreUtteranceDelay",
                defaultValue: 0.0,
                minimumValue: 0.0,
                maximumValue: 0.25
            )),
            postUtteranceDelay: TimeInterval(configuredFloat(
                forKey: "LocalTTSPostUtteranceDelay",
                defaultValue: 0.02,
                minimumValue: 0.0,
                maximumValue: 0.25
            ))
        )
    }

    private static func configuredFloat(
        forKey key: String,
        defaultValue: Float,
        minimumValue: Float,
        maximumValue: Float
    ) -> Float {
        guard let configuredStringValue = AppBundleConfiguration.stringValue(forKey: key),
              let configuredFloatValue = Float(configuredStringValue) else {
            return defaultValue
        }

        return min(max(configuredFloatValue, minimumValue), maximumValue)
    }
}

private final class LocalTTSPlaybackCompletionObserver: NSObject, AVSpeechSynthesizerDelegate {
    private let onPlaybackFinishedOrCancelled: () -> Void

    init(onPlaybackFinishedOrCancelled: @escaping () -> Void) {
        self.onPlaybackFinishedOrCancelled = onPlaybackFinishedOrCancelled
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onPlaybackFinishedOrCancelled()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onPlaybackFinishedOrCancelled()
    }
}
