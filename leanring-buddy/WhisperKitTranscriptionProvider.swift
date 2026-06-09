//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  Selectable ASR provider scaffold. The real WhisperKit streaming runtime
//  lands behind this type; until then the factory falls back to Apple Speech.
//

import AVFoundation
import Foundation

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    static let configuredProviderName = "whisperKit"

    /// The project already links WhisperKit, but the streaming session bridge
    /// is intentionally not claimed ready until a real implementation exists.
    static let isRuntimeAvailable = false

    let displayName = "WhisperKit"
    let requiresSpeechRecognitionPermission = false

    func startStreamingSession(
        contextualPhrases: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        throw WhisperKitTranscriptionProviderError(
            message: "WhisperKit transcription is configured but the streaming runtime is not installed in Pace yet."
        )
    }

    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        // A real WhisperKit backend should flip this only after model load and
        // CoreML compile. The scaffold never becomes active because the factory
        // falls back before this provider is returned.
    }
}
