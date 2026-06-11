//
//  LocalServerTTSClientTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct LocalServerTTSConfigurationTests {
    @Test func defaultsApplyWhenNothingConfigured() async throws {
        let configuration = LocalServerTTSConfiguration(
            configuredBaseURLString: nil,
            configuredModelIdentifier: nil,
            configuredVoiceIdentifier: nil,
            configuredSpeedString: nil
        )
        #expect(configuration.baseURL == LocalServerTTSConfiguration.defaultBaseURL)
        #expect(configuration.modelIdentifier == "kokoro")
        #expect(configuration.voiceIdentifier == "af_heart")
        #expect(configuration.speed == 1.0)
    }

    @Test func remoteBaseURLIsRefusedAndFallsBackToLoopbackDefault() async throws {
        let configuration = LocalServerTTSConfiguration(
            configuredBaseURLString: "http://192.168.1.20:8880/v1",
            configuredModelIdentifier: nil,
            configuredVoiceIdentifier: nil,
            configuredSpeedString: nil
        )
        #expect(configuration.baseURL == LocalServerTTSConfiguration.defaultBaseURL)
    }

    @Test func outOfRangeSpeedFallsBackToDefault() async throws {
        for badSpeed in ["0.1", "9", "fast", ""] {
            let configuration = LocalServerTTSConfiguration(
                configuredBaseURLString: nil,
                configuredModelIdentifier: nil,
                configuredVoiceIdentifier: nil,
                configuredSpeedString: badSpeed
            )
            #expect(configuration.speed == 1.0, "expected default speed for \(badSpeed)")
        }
    }

    @Test func speechRequestCarriesAllFields() async throws {
        let configuration = LocalServerTTSConfiguration(
            configuredBaseURLString: "http://localhost:9999/v1",
            configuredModelIdentifier: "kokoro",
            configuredVoiceIdentifier: "af_bella",
            configuredSpeedString: "1.2"
        )
        let request = configuration.speechRequest(for: "hello pace")
        #expect(request.url?.absoluteString == "http://localhost:9999/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(
            with: try #require(request.httpBody)
        ) as? [String: Any]
        #expect(body?["input"] as? String == "hello pace")
        #expect(body?["voice"] as? String == "af_bella")
        #expect(body?["model"] as? String == "kokoro")
        #expect(body?["response_format"] as? String == "wav")
        #expect(body?["speed"] as? Double == 1.2)
    }
}

@MainActor
struct LocalServerTTSClientIntegrationTests {
    private nonisolated static let fixtureScriptPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts")
        .appendingPathComponent("tts-fixture-server.py")
        .path

    private nonisolated static let pythonThreeExecutablePath: String? = [
        "/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    private nonisolated static var isFixtureRunnable: Bool {
        pythonThreeExecutablePath != nil
            && FileManager.default.fileExists(atPath: fixtureScriptPath)
    }

    @Test(.enabled(if: LocalServerTTSClientIntegrationTests.isFixtureRunnable))
    func synthesizesPlaysAndDrainsThroughFixtureServer() async throws {
        let fixturePort = 8899
        let serverProcess = Process()
        serverProcess.executableURL = URL(
            fileURLWithPath: try #require(Self.pythonThreeExecutablePath)
        )
        serverProcess.arguments = [Self.fixtureScriptPath, String(fixturePort)]
        let readinessPipe = Pipe()
        serverProcess.standardOutput = readinessPipe
        try serverProcess.run()
        defer { serverProcess.terminate() }

        // Wait for the READY line so the first request can't race the bind.
        _ = readinessPipe.fileHandleForReading.availableData

        let client = LocalServerTTSClient(
            configuration: LocalServerTTSConfiguration(
                configuredBaseURLString: "http://127.0.0.1:\(fixturePort)/v1",
                configuredModelIdentifier: nil,
                configuredVoiceIdentifier: nil,
                configuredSpeedString: nil
            )
        )

        try await client.speakText("hello pace")
        #expect(client.isPlaying)

        // Silent fixture WAV is 0.15s — drain should finish well within 5s.
        var drainedWithinTimeout = false
        for _ in 0..<50 {
            if !client.isPlaying {
                drainedWithinTimeout = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(drainedWithinTimeout)
    }

    /// Silent BuddyTTSClient stub so fallback tests never speak through the
    /// test machine's speakers.
    private final class SilentRecordingTTSClient: BuddyTTSClient {
        private(set) var spokenTexts: [String] = []
        var isPlaying: Bool { false }

        func speakText(_ text: String) async throws {
            spokenTexts.append(text)
        }

        func stopPlayback() {}
    }

    @Test func unreachableServerDropsUtteranceSilentlyInsteadOfFallingBack() async throws {
        // Policy: NEVER speak through the Apple voice — it was rated worse
        // than no audio. Failed synth retries once on the same text, then
        // splits on punctuation. If every attempt fails, the fragment is
        // dropped (the visible response overlay still shows the text).
        let mustNeverSpeakFallback = SilentRecordingTTSClient()
        let client = LocalServerTTSClient(
            configuration: LocalServerTTSConfiguration(
                configuredBaseURLString: "http://127.0.0.1:59997/v1",
                configuredModelIdentifier: nil,
                configuredVoiceIdentifier: nil,
                configuredSpeedString: nil
            ),
            fallbackClient: mustNeverSpeakFallback
        )
        try await client.speakText("fallback check")

        // Let the drain loop run to completion.
        for _ in 0..<60 {
            if !client.isPlaying { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(mustNeverSpeakFallback.spokenTexts.isEmpty)
        #expect(!client.isPlaying)
    }
}
