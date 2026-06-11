//
//  PacePostureAnalyzer.swift
//  leanring-buddy
//
//  Pure posture-classification logic for the camera posture watch.
//  Works on face-rectangle observations (Vision normalized coordinates,
//  bottom-left origin): sinking in the chair lowers the face center,
//  leaning into the screen grows the face height. A calibration window
//  establishes the user's good-posture baseline; hysteresis plus an
//  alert cooldown keep the nudges rare and intentional. Isolation-free
//  so every rule is unit-testable without a camera.
//

import Foundation

nonisolated struct PacePostureSample: Equatable {
    /// Face center Y in Vision normalized coordinates (0 = bottom of frame).
    let faceCenterY: Double
    /// Face bounding-box height in Vision normalized coordinates.
    let faceHeight: Double
    let capturedAt: Date
}

nonisolated enum PacePostureAssessment: String, Equatable {
    case good
    case sinking
    case leaningIn

    var displayName: String {
        switch self {
        case .good:
            return "good posture"
        case .sinking:
            return "slouching"
        case .leaningIn:
            return "leaning into the screen"
        }
    }

    var spokenNudge: String {
        switch self {
        case .good:
            return ""
        case .sinking:
            return "posture check — you're slouching. sit up a little."
        case .leaningIn:
            return "posture check — you're leaning into the screen. ease back a bit."
        }
    }
}

nonisolated enum PacePostureEvent: Equatable {
    case calibrated
    case alert(PacePostureAssessment)
}

nonisolated struct PacePostureAnalyzer {
    static let calibrationSampleCount = 5
    /// Normalized drop in face center below baseline that counts as sinking.
    static let sinkingCenterDropThreshold = 0.07
    /// Face height growth over baseline that counts as leaning in.
    static let leaningHeightRatioThreshold = 1.28
    /// Bad samples in a row before an alert fires (one-off shifts are fine).
    static let consecutiveBadSamplesBeforeAlert = 3
    static let alertCooldownInSeconds: TimeInterval = 180

    private var calibrationSamples: [PacePostureSample] = []
    private(set) var baselineFaceCenterY: Double?
    private(set) var baselineFaceHeight: Double?
    private var consecutiveBadSampleCount = 0
    private var lastAlertAt: Date?
    private(set) var latestAssessment: PacePostureAssessment = .good

    var isCalibrated: Bool {
        baselineFaceCenterY != nil && baselineFaceHeight != nil
    }

    /// Feeds one camera sample. Returns an event when calibration completes
    /// or a posture alert should be surfaced; nil otherwise.
    mutating func ingest(_ sample: PacePostureSample) -> PacePostureEvent? {
        guard isCalibrated else {
            calibrationSamples.append(sample)
            guard calibrationSamples.count >= Self.calibrationSampleCount else { return nil }
            baselineFaceCenterY = Self.median(calibrationSamples.map(\.faceCenterY))
            baselineFaceHeight = Self.median(calibrationSamples.map(\.faceHeight))
            calibrationSamples = []
            return .calibrated
        }

        let assessment = assess(sample)
        latestAssessment = assessment

        guard assessment != .good else {
            consecutiveBadSampleCount = 0
            return nil
        }

        consecutiveBadSampleCount += 1
        guard consecutiveBadSampleCount >= Self.consecutiveBadSamplesBeforeAlert else { return nil }

        if let lastAlertAt,
           sample.capturedAt.timeIntervalSince(lastAlertAt) < Self.alertCooldownInSeconds {
            return nil
        }
        lastAlertAt = sample.capturedAt
        consecutiveBadSampleCount = 0
        return .alert(assessment)
    }

    /// Drops the baseline so the next samples re-calibrate. Used when the
    /// user repositions their setup or toggles the feature back on.
    mutating func recalibrate() {
        calibrationSamples = []
        baselineFaceCenterY = nil
        baselineFaceHeight = nil
        consecutiveBadSampleCount = 0
        lastAlertAt = nil
        latestAssessment = .good
    }

    private func assess(_ sample: PacePostureSample) -> PacePostureAssessment {
        guard let baselineFaceCenterY, let baselineFaceHeight else { return .good }
        // Leaning checked first: moving toward the camera also shifts the
        // face center, and the larger face is the more specific signal.
        if baselineFaceHeight > 0,
           sample.faceHeight / baselineFaceHeight >= Self.leaningHeightRatioThreshold {
            return .leaningIn
        }
        if baselineFaceCenterY - sample.faceCenterY >= Self.sinkingCenterDropThreshold {
            return .sinking
        }
        return .good
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middleIndex = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middleIndex - 1] + sorted[middleIndex]) / 2
        }
        return sorted[middleIndex]
    }
}
