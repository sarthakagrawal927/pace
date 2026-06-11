//
//  BuddyTTSClient.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends. Two conformers:
//  LocalTTSClient (AVSpeechSynthesizer, always available) and
//  LocalServerTTSClient (loopback OpenAI-compatible /v1/audio/speech —
//  Kokoro by default — which itself falls back to LocalTTSClient
//  whenever the sidecar is unavailable).
//

import Foundation

@MainActor
protocol BuddyTTSClient: AnyObject {
    /// Speaks `text` and returns when audio playback has started (not
    /// when it has finished). The caller polls `isPlaying` to detect
    /// completion.
    func speakText(_ text: String) async throws

    /// Whether speech audio is currently being played out of the device.
    var isPlaying: Bool { get }

    /// Stops any in-progress speech immediately. Safe to call when
    /// nothing is playing.
    func stopPlayback()
}

enum BuddyTTSClientFactory {
    @MainActor
    static func makeDefault() -> any BuddyTTSClient {
        let configuredProvider = AppBundleConfiguration
            .stringValue(forKey: "TTSProvider")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // `localServer` is the default: when no sidecar is running it
        // degrades to the Apple voice within milliseconds per turn, so the
        // upgrade is free to opt out of and automatic to opt into.
        if configuredProvider == "apple" {
            print("🔊 TTS: using local AVSpeechSynthesizer")
            return LocalTTSClient()
        }
        return LocalServerTTSClient()
    }
}
