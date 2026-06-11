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
    // 60s: mlx-audio's first synth after the sidecar boots (Pace now
    // auto-starts it) is ~20-30s while Kokoro's weights actually load
    // into MLX. Subsequent synths are ~150-400ms. A generous ceiling
    // here means the very first reply after launch still gets the
    // local voice instead of silent drop.
    static let requestTimeoutInSeconds: TimeInterval = 60
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

    private struct PendingUtterance {
        let text: String
    }

    private var pendingUtteranceQueue: [PendingUtterance] = []
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

    /// Polls the sidecar until it's actually reachable, then fires a tiny
    /// synth so Kokoro's MLX weights are resident before the user's first
    /// real sentence arrives. Without the poll, the warmup races the
    /// auto-started sidecar and silently fails — meaning the first real
    /// turn still pays the 20-30s cold-load tax.
    private func warmUpSynthesizer() {
        let warmUpConfiguration = configuration
        let warmUpSession = urlSession
        Task.detached(priority: .userInitiated) {
            let modelsURL = warmUpConfiguration.baseURL.appendingPathComponent("models")
            for attempt in 0..<60 {
                var probeRequest = URLRequest(url: modelsURL)
                probeRequest.timeoutInterval = 2
                if let (_, response) = try? await warmUpSession.data(for: probeRequest),
                   let httpResponse = response as? HTTPURLResponse,
                   (200..<500).contains(httpResponse.statusCode) {
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                _ = attempt
            }
            let warmUpRequest = warmUpConfiguration.speechRequest(for: ".")
            _ = try? await warmUpSession.data(for: warmUpRequest)
        }
    }

    /// True while the client has work to do — pending text, in-flight
    /// synthesis, or audio still playing through either voice.
    var isPlaying: Bool {
        !pendingUtteranceQueue.isEmpty
            || isDrainingPlaybackQueue
            || audioPlayer?.isPlaying == true
            || fallbackClient.isPlaying
    }

    /// Enqueues an utterance. Synthesis and playback are SERIALIZED inside
    /// the drain loop: one request at a time to the sidecar, drained
    /// strictly in arrival order. The previous design fired every
    /// sentence's synthesis in parallel, which made the second voice show
    /// up mid-reply whenever Kokoro queued or slow-rejected a concurrent
    /// request — a single bad sentence dropped to Apple TTS while
    /// neighbors stayed on Kokoro, producing the half-and-half voice mix.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        pendingUtteranceQueue.append(PendingUtterance(text: trimmedText))
        startDrainingPlaybackQueueIfNeeded()
    }

    func stopPlayback() {
        pendingUtteranceQueue = []
        audioPlayer?.stop()
        audioPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        fallbackClient.stopPlayback()
    }

    private func synthesizeAudioData(forText text: String) async -> Data? {
        let synthesisStartedAt = Date()
        let configurationSnapshot = configuration
        let sessionSnapshot = urlSession
        func auditSynthesis(outcome: String, outputByteCount: Int? = nil) {
            PaceAPIAuditLog.shared.record(
                subsystem: "tts",
                operation: "audio.speech",
                target: "\(configurationSnapshot.modelIdentifier)/\(configurationSnapshot.voiceIdentifier)",
                durationMilliseconds: Int(Date().timeIntervalSince(synthesisStartedAt) * 1000),
                outcome: outcome,
                inputCharacterCount: text.count,
                outputCharacterCount: outputByteCount
            )
        }
        do {
            let (audioData, response) = try await sessionSnapshot.data(
                for: configurationSnapshot.speechRequest(for: text)
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

    private func startDrainingPlaybackQueueIfNeeded() {
        guard !isDrainingPlaybackQueue else { return }
        isDrainingPlaybackQueue = true
        Task { [weak self] in
            await self?.drainPlaybackQueue()
        }
    }

    private func drainPlaybackQueue() async {
        defer { isDrainingPlaybackQueue = false }
        while !pendingUtteranceQueue.isEmpty {
            let utterance = pendingUtteranceQueue.removeFirst()
            await speakWithKokoroOrSwallow(text: utterance.text)
        }
    }

    /// Strict "Kokoro or silent" policy. The Apple voice was rated worse
    /// than no audio, so we never speak through it: a failed sentence is
    /// retried (once on the raw text for transients, then by splitting on
    /// a punctuation boundary to dodge mlx-audio's input-shape bugs), and
    /// if both halves still fail the response overlay still shows the
    /// text — only the audio is dropped for that fragment.
    private func speakWithKokoroOrSwallow(text: String) async {
        if let audioData = await synthesizeAudioData(forText: text) {
            await playAudioData(audioData)
            return
        }
        // First retry: same text. Transient transport errors are common
        // and almost always succeed on a clean second try.
        if let retriedAudioData = await synthesizeAudioData(forText: text) {
            await playAudioData(retriedAudioData)
            return
        }
        // Second retry: split the text at a punctuation boundary and try
        // each half independently. mlx-audio's Kokoro path occasionally
        // fails with "broadcast_shapes (1,N,1) and (1,M,9) cannot be
        // broadcast" on specific phoneme sequences; the split text uses
        // a different sequence that usually doesn't trip the bug.
        let (firstHalf, secondHalf) = Self.splitForSynthesisRetry(text)
        if firstHalf != text, let firstHalfAudio = await synthesizeAudioData(forText: firstHalf) {
            await playAudioData(firstHalfAudio)
            if !secondHalf.isEmpty, let secondHalfAudio = await synthesizeAudioData(forText: secondHalf) {
                await playAudioData(secondHalfAudio)
            } else {
                print("🔊 Kokoro: dropping inaudible fragment '\(secondHalf.prefix(60))' — text still in overlay")
            }
            return
        }
        print("🔊 Kokoro: dropping inaudible sentence '\(text.prefix(60))' — text still in overlay")
    }

    /// Splits text near the middle at the LAST punctuation boundary in
    /// the first half — gives synthesis-retry a fighting chance without
    /// chopping mid-word. Falls back to returning (text, "") when no
    /// punctuation is present.
    private static func splitForSynthesisRetry(_ text: String) -> (String, String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > 32 else { return (trimmedText, "") }
        let punctuationSet = CharacterSet(charactersIn: ".,;:!?—-")
        let halfwayCharacterIndex = trimmedText.index(
            trimmedText.startIndex,
            offsetBy: trimmedText.count / 2
        )
        let firstHalfSubstring = trimmedText[..<halfwayCharacterIndex]
        if let lastPunctuationRange = firstHalfSubstring.rangeOfCharacter(
            from: punctuationSet,
            options: .backwards
        ) {
            let firstPart = trimmedText[..<lastPunctuationRange.upperBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let secondPart = trimmedText[lastPunctuationRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (firstPart, secondPart)
        }
        return (trimmedText, "")
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
