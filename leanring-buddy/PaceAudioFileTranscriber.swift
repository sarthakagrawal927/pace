//
//  PaceAudioFileTranscriber.swift
//  leanring-buddy
//
//  Transcribes an audio file (m4a, mp3, wav, aiff, caf, flac) at a
//  given URL using whichever local ASR backend is best for the
//  file's length. The transcription itself runs on Apple's
//  AVAudioFile + WhisperKit (when available) or Apple
//  SFSpeechRecognizer (fallback). Fully on-device — the file is
//  read once into a Float buffer, decoded to text, never uploaded.
//
//  Why two backends:
//
//    - WhisperKit handles long audio (minutes to hours) at ~9x
//      realtime on Apple Silicon's ANE, and produces materially
//      better transcripts than Apple Speech on technical or
//      domain vocabulary. It's the right tool for "transcribe
//      this meeting recording I dropped into Pace."
//
//    - Apple SFSpeechRecognizer has a 1-minute file cap but is
//      universally available (no model download) so it's the
//      right fallback for short clips when WhisperKit isn't
//      installed.
//
//  Pure async function — no MainActor isolation. Throws on
//  unreadable file / unsupported format / backend failure rather
//  than silently returning an empty transcript, because the caller
//  (planner tool dispatch, future drag-drop UI) needs to know
//  whether to surface an error to the user.
//

import AVFoundation
import Foundation
import Speech
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

nonisolated enum PaceAudioFileTranscriberError: LocalizedError {
    case fileNotFound(URL)
    case unreadableAudio(underlyingErrorDescription: String)
    case backendsAllFailed(whisperKitError: String?, appleSpeechError: String?)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let fileURL):
            return "Audio file not found at \(fileURL.path)."
        case .unreadableAudio(let underlyingErrorDescription):
            return "Couldn't read audio: \(underlyingErrorDescription)."
        case .backendsAllFailed(let whisperKitError, let appleSpeechError):
            let whisperKitDetails = whisperKitError.map { "WhisperKit: \($0)" } ?? "WhisperKit: not available"
            let appleSpeechDetails = appleSpeechError.map { "Apple Speech: \($0)" } ?? "Apple Speech: not attempted"
            return "All ASR backends failed. \(whisperKitDetails) / \(appleSpeechDetails)"
        }
    }
}

enum PaceAudioFileTranscriber {

    /// Transcribe an audio file. Tries WhisperKit first if the
    /// runtime + model are present; falls back to Apple Speech.
    ///
    /// Throws on hard failure. Returns a single concatenated string —
    /// no segment timestamps for v1 because Pace's surfaces (planner
    /// observation, drag-drop result text) consume plain text.
    static func transcribeAudioFile(at fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PaceAudioFileTranscriberError.fileNotFound(fileURL)
        }

        let pcmSamples = try decodeAudioToMonoFloatSamplesAt16kHz(fileURL: fileURL)
        guard !pcmSamples.isEmpty else { return "" }

        var whisperKitError: String?
        #if canImport(WhisperKit)
        do {
            return try await transcribeWithWhisperKit(pcmSamples: pcmSamples)
        } catch {
            whisperKitError = error.localizedDescription
            // Fall through to Apple Speech.
        }
        #endif

        var appleSpeechError: String?
        do {
            return try await transcribeWithAppleSpeech(fileURL: fileURL)
        } catch {
            appleSpeechError = error.localizedDescription
        }

        throw PaceAudioFileTranscriberError.backendsAllFailed(
            whisperKitError: whisperKitError,
            appleSpeechError: appleSpeechError
        )
    }

    // MARK: - Audio decoding

    /// Decode any AVAudioFile-supported format down to a mono 16 kHz
    /// Float buffer — the format WhisperKit consumes directly. Used
    /// for the WhisperKit path; Apple Speech consumes the original
    /// URL directly so it gets to do its own resampling internally.
    nonisolated static func decodeAudioToMonoFloatSamplesAt16kHz(fileURL: URL) throws -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        let sourceFormat = audioFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "couldn't construct 16 kHz mono target format"
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "couldn't construct converter from \(sourceFormat) to 16 kHz mono"
            )
        }

        let sourceFrameCount = AVAudioFrameCount(audioFile.length)
        guard sourceFrameCount > 0 else { return [] }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "couldn't allocate source buffer for \(sourceFrameCount) frames"
            )
        }

        do {
            try audioFile.read(into: sourceBuffer)
        } catch {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        // Output capacity: floor (frames * targetRate / sourceRate)
        // plus padding for the converter's tail.
        let resampledFrameCapacity = AVAudioFrameCount(
            Double(sourceBuffer.frameLength) * (16_000.0 / sourceFormat.sampleRate) + 1024
        )
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: resampledFrameCapacity
        ) else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "couldn't allocate target buffer"
            )
        }

        var converterError: NSError?
        var hasPushedSource = false
        let conversionStatus = converter.convert(to: targetBuffer, error: &converterError) { _, outStatus in
            if hasPushedSource {
                outStatus.pointee = .endOfStream
                return nil
            }
            hasPushedSource = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let converterError {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: converterError.localizedDescription
            )
        }
        guard conversionStatus != .error else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "AVAudioConverter reported .error status"
            )
        }

        guard let floatChannelData = targetBuffer.floatChannelData else { return [] }
        let frameCount = Int(targetBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameCount))
    }

    // MARK: - WhisperKit backend

    #if canImport(WhisperKit)
    nonisolated private static func transcribeWithWhisperKit(pcmSamples: [Float]) async throws -> String {
        guard FileManager.default.fileExists(atPath: WhisperKitTranscriptionProvider.modelFolderURL.path) else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "WhisperKit model not installed at \(WhisperKitTranscriptionProvider.modelFolderURL.path)"
            )
        }
        let pipelineConfig = WhisperKitConfig(
            model: WhisperKitTranscriptionProvider.modelName,
            modelFolder: WhisperKitTranscriptionProvider.modelFolderURL.path,
            download: false
        )
        let pipeline = try await WhisperKit(pipelineConfig)
        var decodingOptions = DecodingOptions()
        // language: nil → auto-detect. Long-form files may not be
        // English (a podcast, a Spanish-language meeting recording);
        // letting WhisperKit detect the language is the right default.
        decodingOptions.language = nil
        decodingOptions.temperature = 0
        let results = try await pipeline.transcribe(audioArray: pcmSamples, decodeOptions: decodingOptions)
        return results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    // MARK: - Apple Speech backend

    nonisolated private static func transcribeWithAppleSpeech(fileURL: URL) async throws -> String {
        // SFSpeechRecognizer.recognitionTask completion-callback API
        // wrapped in a continuation. Failures bubble up through the
        // throwing continuation so the caller can decide whether to
        // try yet another backend.
        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw PaceAudioFileTranscriberError.unreadableAudio(
                underlyingErrorDescription: "Apple SFSpeechRecognizer not available for the current locale"
            )
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        // Force on-device — same posture as the live STT path. No
        // bytes leave the Mac.
        request.requiresOnDeviceRecognition = true
        // Asking for partial results lets us terminate the task on
        // the first final segment instead of polling.
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeOnce: (Result<String, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                let transcribedText = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resumeOnce(.success(transcribedText))
            }
        }
    }
}
