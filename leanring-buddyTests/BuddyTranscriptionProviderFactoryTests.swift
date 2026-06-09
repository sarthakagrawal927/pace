//
//  BuddyTranscriptionProviderFactoryTests.swift
//  leanring-buddyTests
//

import Testing

@testable import Pace

struct BuddyTranscriptionProviderFactoryTests {
    @Test func defaultProviderUsesAppleSpeech() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: nil,
            isWhisperKitRuntimeAvailable: false
        )

        #expect(provider.displayName == "Apple Speech")
        #expect(provider.requiresSpeechRecognitionPermission)
    }

    @Test func whisperKitFallsBackToAppleSpeechWhenRuntimeUnavailable() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: "whisperKit",
            isWhisperKitRuntimeAvailable: false
        )

        #expect(provider.displayName == "Apple Speech (WhisperKit fallback)")
        #expect(provider.requiresSpeechRecognitionPermission)
    }

    @Test func whisperKitCanBeSelectedWhenRuntimeAvailable() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: "whisper-kit",
            isWhisperKitRuntimeAvailable: true
        )

        #expect(provider.displayName == "WhisperKit")
        #expect(provider.requiresSpeechRecognitionPermission == false)
    }
}
