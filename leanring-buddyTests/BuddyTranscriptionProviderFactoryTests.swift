//
//  BuddyTranscriptionProviderFactoryTests.swift
//  leanring-buddyTests
//

import Testing

@testable import Pace

@MainActor
struct BuddyTranscriptionProviderFactoryTests {
    @Test func defaultProviderUsesAppleSpeechWhenWhisperKitNotInstalled() async throws {
        // No explicit preference + no WhisperKit model on disk →
        // Apple Speech (zero-setup default).
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: nil,
            isWhisperKitRuntimeAvailable: false,
            isWhisperKitModelInstalledOnDisk: false
        )

        #expect(provider.displayName == "Apple Speech")
        #expect(provider.requiresSpeechRecognitionPermission)
    }

    @Test func defaultProviderAutoSelectsWhisperKitWhenModelOnDisk() async throws {
        // No explicit preference + WhisperKit installed → auto-prefer
        // WhisperKit. The install-time presence of the model IS the
        // user's opt-in signal — no Info.plist toggle required.
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: nil,
            isWhisperKitRuntimeAvailable: true,
            isWhisperKitModelInstalledOnDisk: true
        )

        #expect(provider.displayName == "WhisperKit")
        #expect(provider.requiresSpeechRecognitionPermission == false)
    }

    @Test func whisperKitFallsBackToAppleSpeechWhenRuntimeUnavailable() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: "whisperKit",
            isWhisperKitRuntimeAvailable: false,
            isWhisperKitModelInstalledOnDisk: false
        )

        #expect(provider.displayName == "Apple Speech (WhisperKit fallback)")
        #expect(provider.requiresSpeechRecognitionPermission)
    }

    @Test func whisperKitFallsBackToAppleSpeechWhenModelMissing() async throws {
        // Runtime is linked but model isn't on disk → fall back to
        // Apple Speech rather than throw at first session start.
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: "whisperKit",
            isWhisperKitRuntimeAvailable: true,
            isWhisperKitModelInstalledOnDisk: false
        )

        #expect(provider.displayName == "Apple Speech (WhisperKit fallback)")
    }

    @Test func whisperKitCanBeSelectedWhenRuntimeAndModelAvailable() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: "whisper-kit",
            isWhisperKitRuntimeAvailable: true,
            isWhisperKitModelInstalledOnDisk: true
        )

        #expect(provider.displayName == "WhisperKit")
        #expect(provider.requiresSpeechRecognitionPermission == false)
    }

    @Test func explicitAppleSpeechWinsOverInstalledWhisperKit() async throws {
        // If the user explicitly picked Apple Speech in Info.plist,
        // we MUST honour that even when WhisperKit is installed.
        // Auto-select only fires when nothing was specified.
        let provider = BuddyTranscriptionProviderFactory.makeProvider(
            configuredProviderName: "apple",
            isWhisperKitRuntimeAvailable: true,
            isWhisperKitModelInstalledOnDisk: true
        )

        #expect(provider.displayName == "Apple Speech")
    }
}
