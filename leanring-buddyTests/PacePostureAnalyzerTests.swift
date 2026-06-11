//
//  PacePostureAnalyzerTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PacePostureAnalyzerTests {
    private let baseDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func sample(
        centerY: Double = 0.55,
        height: Double = 0.30,
        secondsOffset: TimeInterval = 0
    ) -> PacePostureSample {
        PacePostureSample(
            faceCenterY: centerY,
            faceHeight: height,
            capturedAt: baseDate.addingTimeInterval(secondsOffset)
        )
    }

    private func calibratedAnalyzer() -> PacePostureAnalyzer {
        var analyzer = PacePostureAnalyzer()
        for sampleIndex in 0..<PacePostureAnalyzer.calibrationSampleCount {
            _ = analyzer.ingest(sample(secondsOffset: TimeInterval(sampleIndex) * 10))
        }
        return analyzer
    }

    @Test func calibrationCompletesAfterConfiguredSampleCountUsingMedians() async throws {
        var analyzer = PacePostureAnalyzer()
        var events: [PacePostureEvent?] = []
        let centerYValues = [0.54, 0.55, 0.56, 0.95, 0.55]
        for (sampleIndex, centerY) in centerYValues.enumerated() {
            events.append(analyzer.ingest(sample(
                centerY: centerY,
                secondsOffset: TimeInterval(sampleIndex) * 10
            )))
        }
        #expect(events.last == .calibrated)
        #expect(analyzer.isCalibrated)
        // Median resists the 0.95 outlier sample.
        #expect(analyzer.baselineFaceCenterY == 0.55)
    }

    @Test func goodPostureNeverAlerts() async throws {
        var analyzer = calibratedAnalyzer()
        for sampleIndex in 0..<20 {
            let event = analyzer.ingest(sample(secondsOffset: 100 + TimeInterval(sampleIndex) * 10))
            #expect(event == nil)
        }
        #expect(analyzer.latestAssessment == .good)
    }

    @Test func sustainedSinkingAlertsAfterHysteresis() async throws {
        var analyzer = calibratedAnalyzer()
        let slouchedCenterY = 0.55 - PacePostureAnalyzer.sinkingCenterDropThreshold - 0.01

        #expect(analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 100)) == nil)
        #expect(analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 110)) == nil)
        let thirdEvent = analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 120))
        #expect(thirdEvent == .alert(.sinking))
    }

    @Test func leaningInAlertsAndWinsOverSinking() async throws {
        var analyzer = calibratedAnalyzer()
        // Leaning grows the face AND shifts the center — leaning should win.
        let leanHeight = 0.30 * (PacePostureAnalyzer.leaningHeightRatioThreshold + 0.05)
        let shiftedCenterY = 0.55 - PacePostureAnalyzer.sinkingCenterDropThreshold - 0.01

        var lastEvent: PacePostureEvent?
        for sampleIndex in 0..<PacePostureAnalyzer.consecutiveBadSamplesBeforeAlert {
            lastEvent = analyzer.ingest(sample(
                centerY: shiftedCenterY,
                height: leanHeight,
                secondsOffset: 100 + TimeInterval(sampleIndex) * 10
            ))
        }
        #expect(lastEvent == .alert(.leaningIn))
    }

    @Test func recoveryResetsTheBadSampleStreak() async throws {
        var analyzer = calibratedAnalyzer()
        let slouchedCenterY = 0.55 - PacePostureAnalyzer.sinkingCenterDropThreshold - 0.01

        _ = analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 100))
        _ = analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 110))
        // Sitting back up clears the streak…
        _ = analyzer.ingest(sample(secondsOffset: 120))
        // …so two more bad samples are still below the alert threshold.
        #expect(analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 130)) == nil)
        #expect(analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: 140)) == nil)
    }

    @Test func alertsRespectTheCooldownWindow() async throws {
        var analyzer = calibratedAnalyzer()
        let slouchedCenterY = 0.55 - PacePostureAnalyzer.sinkingCenterDropThreshold - 0.01

        var firstAlertOffset: TimeInterval = 100
        for sampleIndex in 0..<PacePostureAnalyzer.consecutiveBadSamplesBeforeAlert {
            firstAlertOffset = 100 + TimeInterval(sampleIndex) * 10
            _ = analyzer.ingest(sample(centerY: slouchedCenterY, secondsOffset: firstAlertOffset))
        }

        // Still slouching right after the alert: inside cooldown, no re-alert
        // even after another full bad streak.
        var insideCooldownEvent: PacePostureEvent?
        for sampleIndex in 1...PacePostureAnalyzer.consecutiveBadSamplesBeforeAlert {
            insideCooldownEvent = analyzer.ingest(sample(
                centerY: slouchedCenterY,
                secondsOffset: firstAlertOffset + TimeInterval(sampleIndex) * 10
            ))
        }
        #expect(insideCooldownEvent == nil)

        // After the cooldown, a continued slouch alerts again (the bad
        // streak persisted through cooldown, so the first sample past the
        // window can fire — collect every event rather than just the last).
        let afterCooldownStart = firstAlertOffset + PacePostureAnalyzer.alertCooldownInSeconds + 1
        var afterCooldownEvents: [PacePostureEvent] = []
        for sampleIndex in 0..<PacePostureAnalyzer.consecutiveBadSamplesBeforeAlert {
            if let event = analyzer.ingest(sample(
                centerY: slouchedCenterY,
                secondsOffset: afterCooldownStart + TimeInterval(sampleIndex) * 10
            )) {
                afterCooldownEvents.append(event)
            }
        }
        #expect(afterCooldownEvents == [.alert(.sinking)])
    }

    @Test func recalibrateClearsBaselineAndStateUntilNewSamplesArrive() async throws {
        var analyzer = calibratedAnalyzer()
        analyzer.recalibrate()
        #expect(!analyzer.isCalibrated)
        #expect(analyzer.latestAssessment == .good)

        // A previously-slouched position becomes the NEW baseline after
        // recalibration — the user chose a new setup.
        var lastEvent: PacePostureEvent?
        for sampleIndex in 0..<PacePostureAnalyzer.calibrationSampleCount {
            lastEvent = analyzer.ingest(sample(
                centerY: 0.40,
                secondsOffset: 500 + TimeInterval(sampleIndex) * 10
            ))
        }
        #expect(lastEvent == .calibrated)
        #expect(analyzer.baselineFaceCenterY == 0.40)
    }
}
