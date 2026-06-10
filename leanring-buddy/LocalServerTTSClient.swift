//
//  LocalServerTTSClient.swift
//  leanring-buddy
//
//  High-quality TTS via a loopback OpenAI-compatible /v1/audio/speech
//  server — Kokoro (kokoro-fastapi, port 8880) by default, but any server
//  speaking that API works. Mirrors the LM Studio sidecar pattern: the
//  endpoint is loopback-guarded, and EVERY failure (server down, model
//  missing, decode error, timeout) falls back to the AVSpeechSynthesizer
//  client for that utterance, so the worst case is exactly yesterday's
//  voice. A short unavailability memo skips the connection attempt for
//  subsequent sentences once the server has failed, keeping the fallback
//  path effectively free.
//
//  Sentences arrive one speakText() call at a time from the streaming
//  pipeline; synthesis runs as each call lands (so sentence N+1 renders
//  while N plays) and playback drains strictly in order.
//

import AVFoundation
import Foundation

/// Pure, testable view of the server TTS settings read from Info.plist.
nonisolated struct LocalServerTTSConfiguration: Equatable {
    static let defaultBaseURL = URL(string: "http://localhost:8880/v1")!
    static let defaultModelIdentifier = "kokoro"
    static let defaultVoiceIdentifier = "af_heart"
    static let defaultSpeed = 1.0
    // 20s, not 5s — Kokoro's FIRST synthesis after the model has been
    // paged out can take 10-15s while MLX reloads weights. A tight
    // timeout there sends an entire turn of audio to the Apple fallback.
    static let requestTimeoutInSeconds: TimeInterval = 20
    // 5s, not 30s — when the sidecar truly is down we want to know on
    // the next sentence, not after the whole turn. The brief memo only
    // exists to avoid hammering a dead port mid-sentence-burst.
    static let unavailabilityMemoInSeconds: TimeInterval = 5

    let baseURL: URL
    let modelIdentifier: String
    let voiceIdentifier: String
    let speed: Double

    init(
        configuredBaseURLString: String?,
        configuredModelIdentifier: String?,
        configuredVoiceIdentifier: String?,
        configuredSpeedString: String?
    ) {
        self.baseURL = PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURLString: configuredBaseURLString,
            defaultURL: Self.defaultBaseURL,
            settingName: "LocalTTSServerBaseURL"
        )
        let trimmedModel = configuredModelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelIdentifier = (trimmedModel?.isEmpty == false ? trimmedModel! : Self.defaultModelIdentifier)
        let trimmedVoice = configuredVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceIdentifier = (trimmedVoice?.isEmpty == false ? trimmedVoice! : Self.defaultVoiceIdentifier)
        if let configuredSpeedString,
           let parsedSpeed = Double(configuredSpeedString.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsedSpeed > 0.25, parsedSpeed < 4.0 {
            self.speed = parsedSpeed
        } else {
            self.speed = Self.defaultSpeed
        }
    }

    static func fromBundle() -> LocalServerTTSConfiguration {
        LocalServerTTSConfiguration(
            configuredBaseURLString: AppBundleConfiguration.stringValue(forKey: "LocalTTSServerBaseURL"),
            configuredModelIdentifier: AppBundleConfiguration.stringValue(forKey: "LocalTTSServerModel"),
            configuredVoiceIdentifier: AppBundleConfiguration.stringValue(forKey: "LocalTTSServerVoice"),
            configuredSpeedString: AppBundleConfiguration.stringValue(forKey: "LocalTTSServerSpeed")
        )
    }

    func speechRequest(for text: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeoutInSeconds
        let body: [String: Any] = [
            "model": modelIdentifier,
            "voice": voiceIdentifier,
            "input": text,
            "response_format": "wav",
            "speed": speed,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

@MainActor
final class LocalServerTTSClient: NSObject, BuddyTTSClient {
    private let configuration: LocalServerTTSConfiguration
    private let fallbackClient: any BuddyTTSClient
    private let urlSession: URLSession

    private struct SynthesisJob {
        let text: String
        let task: Task<Data?, Never>
    }

    private var synthesisJobQueue: [SynthesisJob] = []
    private var isDrainingPlaybackQueue = false
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private var serverUnavailableUntil: Date?

    init(
        configuration: LocalServerTTSConfiguration = .fromBundle(),
        fallbackClient: (any BuddyTTSClient)? = nil,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.fallbackClient = fallbackClient ?? LocalTTSClient()
        self.urlSession = urlSession
        super.init()
        print("🔊 Server TTS: \(configuration.baseURL.absoluteString) model=\(configuration.modelIdentifier) voice=\(configuration.voiceIdentifier) (Apple TTS fallback ready)")
        warmUpSynthesizer()
    }

    /// Fire-and-forget warm-up synth at construction so the user's FIRST
    /// real sentence after launch doesn't pay Kokoro's 10-15s cold-load
    /// cost and fall through to the Apple voice. The result audio is
    /// thrown away — only the model load matters.
    private func warmUpSynthesizer() {
        let warmUpConfiguration = configuration
        let warmUpSession = urlSession
        Task.detached(priority: .background) {
            let warmUpRequest = warmUpConfiguration.speechRequest(for: ".")
            _ = try? await warmUpSession.data(for: warmUpRequest)
        }
    }

    var isPlaying: Bool {
        !synthesisJobQueue.isEmpty
            || isDrainingPlaybackQueue
            || audioPlayer?.isPlaying == true
            || fallbackClient.isPlaying
    }

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let serverUnavailableUntil, Date() < serverUnavailableUntil {
            try await fallbackClient.speakText(trimmedText)
            return
        }

        // Synthesis starts immediately so later sentences render while
        // earlier ones play; nil result means "use the fallback voice".
        let synthesisTask = Task<Data?, Never> { [urlSession, configuration] in
            let synthesisStartedAt = Date()
            func auditSynthesis(outcome: String, outputByteCount: Int? = nil) {
                PaceAPIAuditLog.shared.record(
                    subsystem: "tts",
                    operation: "audio.speech",
                    target: "\(configuration.modelIdentifier)/\(configuration.voiceIdentifier)",
                    durationMilliseconds: Int(Date().timeIntervalSince(synthesisStartedAt) * 1000),
                    outcome: outcome,
                    inputCharacterCount: trimmedText.count,
                    outputCharacterCount: outputByteCount
                )
            }
            do {
                let (audioData, response) = try await urlSession.data(
                    for: configuration.speechRequest(for: trimmedText)
                )
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      !audioData.isEmpty else {
                    auditSynthesis(outcome: "bad_response")
                    return nil
                }
                auditSynthesis(outcome: "ok", outputByteCount: audioData.count)
                return audioData
            } catch {
                auditSynthesis(outcome: "transport_error")
                return nil
            }
        }
        synthesisJobQueue.append(SynthesisJob(text: trimmedText, task: synthesisTask))
        startDrainingPlaybackQueueIfNeeded()
    }

    func stopPlayback() {
        for job in synthesisJobQueue {
            job.task.cancel()
        }
        synthesisJobQueue = []
        audioPlayer?.stop()
        audioPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        fallbackClient.stopPlayback()
    }

    private func startDrainingPlaybackQueueIfNeeded() {
        guard !isDrainingPlaybackQueue else { return }
        isDrainingPlaybackQueue = true
        Task { [weak self] in
            await self?.drainPlaybackQueue()
        }
    }

    private func drainPlaybackQueue() async {
        defer { isDrainingPlaybackQueue = false }
        while !synthesisJobQueue.isEmpty {
            let job = synthesisJobQueue.removeFirst()
            guard let audioData = await job.task.value else {
                // Server failed for this sentence: memo the outage so the
                // rest of the turn skips straight to the fallback voice.
                serverUnavailableUntil = Date().addingTimeInterval(
                    LocalServerTTSConfiguration.unavailabilityMemoInSeconds
                )
                print("🔊 Server TTS unavailable — falling back to Apple TTS")
                try? await fallbackClient.speakText(job.text)
                continue
            }
            serverUnavailableUntil = nil
            await playAudioData(audioData)
        }
    }

    private func playAudioData(_ audioData: Data) async {
        guard let player = try? AVAudioPlayer(data: audioData) else {
            print("🔊 Server TTS: undecodable audio payload — skipping sentence")
            return
        }
        audioPlayer = player
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            audioPlayer = nil
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackContinuation = continuation
        }
        audioPlayer = nil
    }
}

extension LocalServerTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.playbackContinuation?.resume()
            self?.playbackContinuation = nil
        }
    }
}
