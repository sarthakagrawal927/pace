//
//  PaceScreenImageDifferTests.swift
//  leanring-buddyTests
//
//  Locks in the cheap image-diff gate that lets watch-mode style flows
//  ignore tiny visual noise before spending OCR/VLM work.
//

import AppKit
import Testing
@testable import Pace

@MainActor
struct PaceScreenImageDifferTests {

    @Test func identicalImagesHaveNoMeaningfulDiff() async throws {
        let imageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: nil
        )
        let firstFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: imageData))
        let secondFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: imageData))

        let diff = try #require(PaceScreenImageDiffer.diff(
            from: firstFingerprint,
            to: secondFingerprint
        ))

        #expect(diff.meanPixelDelta == 0)
        #expect(diff.changedPixelRatio == 0)
        #expect(!diff.isMeaningful)
    }

    @Test func tinyChangeIsNotMeaningful() async throws {
        let originalImageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: nil
        )
        let tinyChangeImageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: CGRect(x: 10, y: 10, width: 1, height: 1)
        )
        let originalFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: originalImageData))
        let tinyChangeFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: tinyChangeImageData))

        let diff = try #require(PaceScreenImageDiffer.diff(
            from: originalFingerprint,
            to: tinyChangeFingerprint
        ))

        #expect(diff.changedPixelRatio < 0.04)
        #expect(!diff.isMeaningful)
    }

    @Test func largeChangeIsMeaningful() async throws {
        let originalImageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: nil
        )
        let largeChangeImageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: CGRect(x: 0, y: 0, width: 24, height: 24)
        )
        let originalFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: originalImageData))
        let largeChangeFingerprint = try #require(PaceScreenImageDiffer.fingerprint(for: largeChangeImageData))

        let diff = try #require(PaceScreenImageDiffer.diff(
            from: originalFingerprint,
            to: largeChangeFingerprint
        ))

        #expect(diff.changedPixelRatio >= 0.04)
        #expect(diff.isMeaningful)
    }

    @Test func watchDetectorEmitsOnlyMeaningfulThrottledChanges() async throws {
        let originalImageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: nil
        )
        let changedImageData = try makeTestImageData(
            width: 64,
            height: 36,
            changedRect: CGRect(x: 0, y: 0, width: 24, height: 24)
        )

        let configuration = PaceScreenWatchConfiguration(
            sampleIntervalInSeconds: 1,
            minimumSecondsBetweenEvents: 10
        )
        var detector = PaceScreenWatchChangeDetector(configuration: configuration)

        let baselineEvents = detector.meaningfulChanges(
            in: [makeCapture(imageData: originalImageData)],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(baselineEvents.isEmpty)

        let firstChangeEvents = detector.meaningfulChanges(
            in: [makeCapture(imageData: changedImageData)],
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(firstChangeEvents.count == 1)

        let throttledEvents = detector.meaningfulChanges(
            in: [makeCapture(imageData: originalImageData)],
            now: Date(timeIntervalSince1970: 2)
        )
        #expect(throttledEvents.isEmpty)

        let laterEvents = detector.meaningfulChanges(
            in: [makeCapture(imageData: changedImageData)],
            now: Date(timeIntervalSince1970: 12)
        )
        #expect(laterEvents.count == 1)
    }

    @Test func watchEventCategoriesScaleWithDiffSize() async throws {
        #expect(PaceScreenWatchChangeDetector.category(
            for: PaceScreenImageDiff(meanPixelDelta: 8, changedPixelRatio: 0.05)
        ) == .focusedRegionChange)

        #expect(PaceScreenWatchChangeDetector.category(
            for: PaceScreenImageDiff(meanPixelDelta: 16, changedPixelRatio: 0.15)
        ) == .contentUpdate)

        #expect(PaceScreenWatchChangeDetector.category(
            for: PaceScreenImageDiff(meanPixelDelta: 32, changedPixelRatio: 0.40)
        ) == .majorScreenChange)
    }

    private func makeTestImageData(
        width: Int,
        height: Int,
        changedRect: CGRect?
    ) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytesPerRow = bitmap.bytesPerRow
        let bytesPerPixel = 4
        let bitmapData = try #require(bitmap.bitmapData)

        for yPosition in 0..<height {
            for xPosition in 0..<width {
                let pointIsChanged = changedRect?.contains(
                    CGPoint(x: xPosition, y: yPosition)
                ) ?? false
                let colorValue: UInt8 = pointIsChanged ? 255 : 20
                let byteOffset = yPosition * bytesPerRow + xPosition * bytesPerPixel
                bitmapData[byteOffset] = colorValue
                bitmapData[byteOffset + 1] = colorValue
                bitmapData[byteOffset + 2] = colorValue
                bitmapData[byteOffset + 3] = 255
            }
        }

        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeCapture(imageData: Data) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: imageData,
            label: "test screen",
            isCursorScreen: true,
            displayWidthInPoints: 64,
            displayHeightInPoints: 36,
            displayFrame: CGRect(x: 0, y: 0, width: 64, height: 36),
            screenshotWidthInPixels: 64,
            screenshotHeightInPixels: 36
        )
    }
}
