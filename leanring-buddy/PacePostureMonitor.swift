//
//  PacePostureMonitor.swift
//  leanring-buddy
//
//  Thin camera glue for the posture watch. Runs a low-resolution
//  AVCaptureSession on the built-in camera, processes ONE frame every
//  sampling interval through Vision face detection (everything else is
//  dropped immediately), and feeds the pure PacePostureAnalyzer. Frames
//  never leave memory and nothing is recorded — the only outputs are the
//  normalized face-rectangle numbers handed to the analyzer.
//
//  Off by default. Owned by CompanionManager behind the
//  isPostureWatchEnabled preference; alerts surface through the existing
//  TTS/status surfaces, never a new one.
//

import AVFoundation
import Foundation
import Vision

/// Lock-protected throttle state shared between the main actor (start/stop)
/// and the capture queue (per-frame gating). Keeps the per-frame fast path
/// off the main actor entirely.
private final class PacePostureFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false
    private var lastProcessedFrameAt = Date.distantPast
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isActive = active
        lastProcessedFrameAt = .distantPast
    }

    /// Returns true at most once per interval while active.
    func admitFrame(at frameDate: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive,
              frameDate.timeIntervalSince(lastProcessedFrameAt) >= minimumInterval else {
            return false
        }
        lastProcessedFrameAt = frameDate
        return true
    }
}

@MainActor
final class PacePostureMonitor: NSObject {
    static let samplingIntervalInSeconds: TimeInterval = 10

    private let captureSession = AVCaptureSession()
    private let videoOutputQueue = DispatchQueue(label: "com.pace.posture-monitor")
    private let frameGate = PacePostureFrameGate(
        minimumInterval: PacePostureMonitor.samplingIntervalInSeconds
    )
    private var analyzer = PacePostureAnalyzer()
    private(set) var isMonitoring = false

    /// Called on the main actor for calibration completion and posture alerts.
    var onPostureEvent: ((PacePostureEvent) -> Void)?
    /// Latest assessment for status surfaces (panel/settings).
    private(set) var latestAssessment: PacePostureAssessment = .good
    private(set) var isCalibrated = false

    func start() {
        guard !isMonitoring else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRunSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard granted else {
                        print("📷 Posture watch: camera permission denied")
                        return
                    }
                    self?.configureAndRunSession()
                }
            }
        default:
            print("📷 Posture watch: camera permission denied or restricted")
        }
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        frameGate.setActive(false)
        analyzer.recalibrate()
        isCalibrated = false
        latestAssessment = .good
        let session = captureSession
        videoOutputQueue.async {
            session.stopRunning()
        }
        print("📷 Posture watch stopped")
    }

    func recalibrate() {
        analyzer.recalibrate()
        isCalibrated = false
        latestAssessment = .good
        print("📷 Posture watch: recalibrating from the next samples")
    }

    private func configureAndRunSession() {
        guard !isMonitoring else { return }

        if captureSession.inputs.isEmpty {
            // Mac built-in cameras commonly report `.unspecified` position,
            // so prefer front but fall back to the default video device.
            let cameraDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front
            ) ?? AVCaptureDevice.default(for: .video)
            guard let cameraDevice,
                  let cameraInput = try? AVCaptureDeviceInput(device: cameraDevice),
                  captureSession.canAddInput(cameraInput) else {
                print("📷 Posture watch: no usable camera")
                return
            }
            captureSession.beginConfiguration()
            captureSession.sessionPreset = .vga640x480
            captureSession.addInput(cameraInput)

            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }
            captureSession.commitConfiguration()
        }

        isMonitoring = true
        frameGate.setActive(true)
        let session = captureSession
        videoOutputQueue.async {
            session.startRunning()
        }
        print("📷 Posture watch started (1 frame / \(Int(Self.samplingIntervalInSeconds))s)")
    }

    private func handleFaceObservation(faceCenterY: Double, faceHeight: Double) {
        let sample = PacePostureSample(
            faceCenterY: faceCenterY,
            faceHeight: faceHeight,
            capturedAt: Date()
        )
        guard let postureEvent = analyzer.ingest(sample) else {
            latestAssessment = analyzer.latestAssessment
            return
        }
        latestAssessment = analyzer.latestAssessment
        if case .calibrated = postureEvent {
            isCalibrated = true
        }
        onPostureEvent?(postureEvent)
    }
}

extension PacePostureMonitor: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Throttle on the video queue before any work: all but one frame
        // per sampling interval are dropped without touching Vision.
        guard frameGate.admitFrame(at: Date()) else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let faceDetectionRequest = VNDetectFaceRectanglesRequest()
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? requestHandler.perform([faceDetectionRequest])) != nil,
              let faceObservation = faceDetectionRequest.results?.max(
                by: { $0.boundingBox.height < $1.boundingBox.height }
              ) else {
            return
        }

        let faceCenterY = Double(faceObservation.boundingBox.midY)
        let faceHeight = Double(faceObservation.boundingBox.height)
        Task { @MainActor [weak self] in
            self?.handleFaceObservation(faceCenterY: faceCenterY, faceHeight: faceHeight)
        }
    }
}
