//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  WhisperKit (large-v3-turbo on ANE) streaming ASR behind
//  BuddyTranscriptionProvider. Qualified 2026-06-08: ~1s warm load,
//  ~9x realtime, transcribes "Pace" correctly without phrase biasing —
//  which is why contextualPhrases is accepted but unused for now.
//
//  Streaming strategy: push-to-talk utterances are short (seconds, not
//  minutes), so the session accumulates 16 kHz mono samples and
//  re-transcribes the WHOLE buffer on a ~1.2s cadence for live partials,
//  then runs one final pass when the user releases the key. Simpler and
//  more robust than incremental windowing at these lengths; revisit if
//  PTT ever allows >60s holds.
//

import AVFoundation
import Foundation
import WhisperKit

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    static let configuredProviderName = "whisperKit"
    static let isRuntimeAvailable = true

    /// Model placed by the WhisperKit qualification spike. `download: false`
    /// keeps Pace zero-network even on a misconfigured machine — a missing
    /// model is a thrown error, never a silent download.
    static let modelName = "openai_whisper-large-v3-v20240930_turbo"
    static var modelFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(modelName)
    }

    let displayName = "WhisperKit"
    let requiresSpeechRecognitionPermission = false

    // One pipeline per app lifetime (1.5 GB of CoreML assets); concurrent
    // first-callers await the same load.
    private static let runtime = WhisperKitRuntimeCache()

    func startStreamingSession(
        contextualPhrases: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let pipeline = try await Self.runtime.pipeline()
        return WhisperKitStreamingSession(
            pipeline: pipeline,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        Task.detached(priority: .utility) {
            // Best-effort: a failed warm-up surfaces as a thrown error on the
            // first real session instead.
            _ = try? await Self.runtime.pipeline()
            await MainActor.run { onReady() }
        }
    }
}

/// Serializes WhisperKit construction so the 1.5 GB model loads exactly once.
private actor WhisperKitRuntimeCache {
    private var loadTask: Task<WhisperKit, Error>?

    func pipeline() async throws -> WhisperKit {
        if let loadTask {
            return try await loadTask.value
        }
        let task = Task<WhisperKit, Error> {
            let folder = WhisperKitTranscriptionProvider.modelFolderURL
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw WhisperKitTranscriptionProviderError(
                    message: "WhisperKit model not found at \(folder.path). Run the model install step (see pace-model-manifest)."
                )
            }
            let config = WhisperKitConfig(
                model: WhisperKitTranscriptionProvider.modelName,
                modelFolder: folder.path,
                download: false
            )
            return try await WhisperKit(config)
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            // Allow a retry after transient failures (e.g. first-launch
            // CoreML compile interrupted) instead of caching the error.
            loadTask = nil
            throw error
        }
    }
}

private final class WhisperKitStreamingSession: BuddyStreamingTranscriptionSession {
    /// Final pass on a full PTT utterance runs ~9x realtime on ANE; 30s of
    /// audio decodes in ~3.5s. Leave headroom before the caller's fallback.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6

    private static let targetSampleRate = 16_000.0
    private static let partialCadenceSeconds = 1.2

    private let pipeline: WhisperKit
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    // Audio arrives on the capture thread; transcription runs on Tasks.
    private let sampleLock = NSLock()
    private var samples: [Float] = []
    private var finalRequested = false

    private var partialTask: Task<Void, Never>?
    private var isTranscribing = false
    private var lastPartialAt = Date.distantPast

    init(pipeline: WhisperKit,
         onTranscriptUpdate: @escaping (String) -> Void,
         onFinalTranscriptReady: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void) {
        self.pipeline = pipeline
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let resampled = AudioProcessor.resampleAudio(
            fromBuffer: audioBuffer,
            toSampleRate: Self.targetSampleRate,
            channelCount: 1
        ), let channel = resampled.floatChannelData else {
            return  // drop unconvertible buffers; next buffer recovers
        }
        let frameCount = Int(resampled.frameLength)
        let incoming = Array(UnsafeBufferPointer(start: channel[0], count: frameCount))

        sampleLock.lock()
        guard !finalRequested else { sampleLock.unlock(); return }
        samples.append(contentsOf: incoming)
        sampleLock.unlock()

        schedulePartialIfDue()
    }

    func requestFinalTranscript() {
        sampleLock.lock()
        finalRequested = true
        let snapshot = samples
        sampleLock.unlock()
        partialTask?.cancel()

        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcribe(snapshot)
                self.onFinalTranscriptReady(text)
            } catch {
                self.onError(error)
            }
        }
    }

    func cancel() {
        sampleLock.lock()
        finalRequested = true
        samples.removeAll()
        sampleLock.unlock()
        partialTask?.cancel()
    }

    private func schedulePartialIfDue() {
        guard Date().timeIntervalSince(lastPartialAt) >= Self.partialCadenceSeconds,
              !isTranscribing else { return }
        lastPartialAt = Date()
        isTranscribing = true

        sampleLock.lock()
        let snapshot = samples
        let cancelled = finalRequested
        sampleLock.unlock()
        guard !cancelled, !snapshot.isEmpty else { isTranscribing = false; return }

        partialTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTranscribing = false }
            do {
                let text = try await self.transcribe(snapshot)
                if !Task.isCancelled, !text.isEmpty {
                    self.onTranscriptUpdate(text)
                }
            } catch {
                // Partial failures are non-fatal — the final pass decides.
            }
        }
    }

    private func transcribe(_ audio: [Float]) async throws -> String {
        guard !audio.isEmpty else { return "" }
        var options = DecodingOptions()
        options.language = "en"          // Pace doctrine: English-only v1
        options.temperature = 0
        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        return results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
