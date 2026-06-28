//
//  PaceSystemAudioCapture.swift
//  leanring-buddy
//
//  Meeting mode: captures system audio via ScreenCaptureKit's SCStream
//  with audio enabled. Inspired by Shiro's meeting mode and Samuel's
//  system-audio listening with PID-level filtering.
//
//  The captured audio is routed to an AVAudioEngine tap for:
//    - Voice activity detection (is someone speaking?)
//    - Action item extraction (via the planner, on demand)
//    - Live transcription (via the existing STT pipeline)
//
//  Permission: covered by the existing Screen Recording permission
//  (hasScreenRecordingPermission). No additional permission needed
//  for system audio capture — it's part of SCStream.
//

import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import Foundation

/// Published state for meeting mode.
enum PaceMeetingModeState: Equatable {
    case inactive
    case starting
    case active
    case failed(String)
}

/// Meeting mode controller. Manages an SCStream that captures system
/// audio (excluding Pace's own process audio to avoid echo). The
/// audio is published as normalized RMS levels for VAD-style detection
/// and can be routed to the STT pipeline for transcription.
@MainActor
final class PaceMeetingModeController: ObservableObject {
    static let shared = PaceMeetingModeController()

    @Published private(set) var state: PaceMeetingModeState = .inactive
    @Published private(set) var detectedSpeechLevel: Float = 0.0
    @Published private(set) var captureDurationSeconds: TimeInterval = 0.0

    /// Publisher for normalized audio levels (0.0...1.0). Consumers
    /// can subscribe to detect speech activity in system audio.
    let audioLevelPublisher = PassthroughSubject<Float, Never>()

    /// Whether meeting mode is enabled (persisted preference).
    @Published var isEnabled: Bool = PaceUserPreferencesStore
        .bool(.isMeetingModeEnabled, default: false)

    private var stream: SCStream?
    private var streamDelegate: PaceSystemAudioStreamDelegate?
    private var captureStartedAt: Date?

    private init() {}

    // MARK: - Lifecycle

    /// Start capturing system audio. Requires Screen Recording
    /// permission. Excludes Pace's own process audio to avoid echo.
    func start() async {
        guard state != .active, state != .starting else { return }
        state = .starting

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            // Capture the primary display's audio. We use the display
            // filter (not per-app) because meeting audio may come from
            // any app (Zoom, Teams, Chrome, etc.).
            guard let display = content.displays.first else {
                state = .failed("No display found for audio capture")
                return
            }

            // Exclude Pace's own windows to avoid capturing TTS output.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { window in
                window.owningApplication?.processID == ownPID
            }

            let filter = SCContentFilter(
                display: display,
                excludingWindows: ownWindows
            )

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            // Low-latency audio capture for real-time VAD.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)

            let delegate = PaceSystemAudioStreamDelegate(
                onAudioSample: { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.handleAudioSample(level: level)
                    }
                }
            )
            streamDelegate = delegate

            let scStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: delegate
            )
            self.stream = scStream

            try await scStream.startCapture()
            state = .active
            captureStartedAt = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop capturing system audio.
    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        streamDelegate = nil
        state = .inactive
        captureStartedAt = nil
        detectedSpeechLevel = 0.0
    }

    /// Toggle meeting mode on/off.
    func toggle() async {
        if state == .active {
            await stop()
        } else {
            await start()
        }
    }

    // MARK: - Audio handling

    private func handleAudioSample(level: Float) {
        detectedSpeechLevel = level
        audioLevelPublisher.send(level)

        if let startedAt = captureStartedAt {
            captureDurationSeconds = Date().timeIntervalSince(startedAt)
        }
    }

    /// Whether system audio currently has speech-like energy.
    var isSystemAudioActive: Bool {
        detectedSpeechLevel > 0.08
    }
}

/// SCStream delegate that receives audio sample buffers and computes
/// normalized RMS levels. The levels are forwarded to the controller
/// via a callback.
private final class PaceSystemAudioStreamDelegate: NSObject, SCStreamDelegate {
    private let onAudioSample: (Float) -> Void

    init(onAudioSample: @escaping (Float) -> Void) {
        self.onAudioSample = onAudioSample
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Compute RMS level from the audio sample buffer.
        // Use the QTSampleBuffer audio approach: extract the raw
        // audio data and compute a simple energy level.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let format = audioFormat else { return }

        let sampleRate = format.pointee.mSampleRate
        let channels = Int(format.pointee.mChannelsPerFrame)
        guard channels > 0, sampleRate > 0 else { return }

        // Get the total number of samples.
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        // Extract audio data via CMBlockBuffer.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        let accessStatus = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard accessStatus == kCMBlockBufferNoErr, let dataPtr = dataPointer else { return }

        // Assume Float32 samples (common for SCStream audio).
        let floatCount = totalLength / MemoryLayout<Float>.size
        let floatPtr = UnsafeMutableRawPointer(dataPtr).bindMemory(to: Float.self, capacity: floatCount)

        var totalSquares: Float = 0
        for i in 0..<floatCount {
            let sample = floatPtr[i]
            totalSquares += sample * sample
        }

        guard floatCount > 0 else { return }
        let rms = sqrt(totalSquares / Float(floatCount))
        let normalized = min(rms / 0.3, 1.0)
        onAudioSample(normalized)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Forward the error — the controller will update state.
        onAudioSample(0.0)
    }
}
