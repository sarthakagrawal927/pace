//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }

    func startStreamingSession(
        contextualPhrases: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession

    /// Optional: pre-load any heavy models so the first push-to-talk
    /// doesn't pay the cold-load cost. `onReady` is invoked on the
    /// MainActor exactly once when the model is fully loaded and the
    /// next session start won't block. Default no-op for backends with
    /// nothing to warm (e.g. Apple Speech).
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void)
}

extension BuddyTranscriptionProvider {
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        // Default: nothing to warm. Fire ready immediately so callers
        // gating PTT on this flag don't get stuck.
        Task { @MainActor in onReady() }
    }
}

enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        makeProvider(
            configuredProviderName: AppBundleConfiguration.stringValue(forKey: "TranscriptionProvider"),
            isWhisperKitRuntimeAvailable: WhisperKitTranscriptionProvider.isRuntimeAvailable
        )
    }

    static func makeProvider(
        configuredProviderName: String?,
        isWhisperKitRuntimeAvailable: Bool
    ) -> any BuddyTranscriptionProvider {
        let normalizedProviderName = configuredProviderName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")

        let provider: any BuddyTranscriptionProvider
        switch normalizedProviderName {
        case "whisperkit", "whisper":
            if isWhisperKitRuntimeAvailable {
                provider = WhisperKitTranscriptionProvider()
            } else {
                print("⚠️ Transcription: WhisperKit requested but runtime is unavailable; falling back to Apple Speech")
                provider = AppleSpeechTranscriptionProvider(displayName: "Apple Speech (WhisperKit fallback)")
            }
        case "applespeech", "apple", .none:
            provider = AppleSpeechTranscriptionProvider()
        default:
            print("⚠️ Transcription: unknown provider '\(configuredProviderName ?? "nil")'; falling back to Apple Speech")
            provider = AppleSpeechTranscriptionProvider()
        }

        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }
}
