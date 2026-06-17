//
//  PaceAnnotationCoordinateMapperTests.swift
//  leanring-buddyTests
//
//  Guards the screenshot-pixel → AppKit-global conversion used by both
//  the pointing-cursor path and the tuition-mode annotation drainer.
//  Extracted into one shared helper so the two paths can't drift; this
//  file pins the math.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pace

struct PaceAnnotationCoordinateMapperTests {

    // MARK: - Primary display, 2x retina, no offset

    /// Retina display at the origin: 3024×1964 screenshot pixels →
    /// 1512×982 display points. A point in the middle of the screenshot
    /// maps to the middle of the display (in AppKit y-flipped coords).
    @Test func midPointOnRetinaPrimaryMapsToDisplayCenter() async throws {
        let primaryDisplayCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "primary",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024,
            screenshotHeightInPixels: 1964
        )

        let appKitGlobalPoint = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: CGPoint(x: 1512, y: 982),
            on: primaryDisplayCapture
        )

        #expect(appKitGlobalPoint.x == 756)
        // y-flip: screenshot mid-y (982) → display-local 491 →
        // AppKit-flipped 491. Same value, but driven by the formula.
        #expect(appKitGlobalPoint.y == 491)
    }

    /// Pixel (0,0) — top-left of the screenshot — maps to the AppKit
    /// top-left of the display, which is the HIGHEST y on a
    /// bottom-left-origin coordinate system.
    @Test func topLeftPixelMapsToHighestAppKitY() async throws {
        let primaryDisplayCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "primary",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024,
            screenshotHeightInPixels: 1964
        )

        let appKitGlobalPoint = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: .zero,
            on: primaryDisplayCapture
        )

        #expect(appKitGlobalPoint.x == 0)
        #expect(appKitGlobalPoint.y == 982)
    }

    // MARK: - Clamping

    /// A pixel coord outside the screenshot bounds is clamped to the
    /// edge — protects against a planner that hallucinates a coordinate
    /// off the visible screen.
    @Test func pointBeyondScreenshotBoundsIsClamped() async throws {
        let primaryDisplayCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "primary",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            screenshotWidthInPixels: 3024,
            screenshotHeightInPixels: 1964
        )

        let outOfBoundsPoint = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: CGPoint(x: 99999, y: 99999),
            on: primaryDisplayCapture
        )
        // Clamped to (3024, 1964) → display-local (1512, 982) → AppKit y-flipped (1512, 0).
        #expect(outOfBoundsPoint.x == 1512)
        #expect(outOfBoundsPoint.y == 0)

        let negativePoint = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: CGPoint(x: -50, y: -50),
            on: primaryDisplayCapture
        )
        // Clamped to (0, 0) → display-local (0, 0) → AppKit y-flipped (0, 982).
        #expect(negativePoint.x == 0)
        #expect(negativePoint.y == 982)
    }

    // MARK: - Multi-monitor: secondary display offset to the right

    /// Secondary display positioned at AppKit origin (1512, 0) — to the
    /// right of the primary. A coordinate at the secondary's middle
    /// should land at (primary width + secondary mid-x, secondary
    /// mid-y).
    @Test func secondaryDisplayOffsetIsAddedToAppKitGlobal() async throws {
        let secondaryDisplayCapture = CompanionScreenCapture(
            imageData: Data(),
            label: "secondary",
            isCursorScreen: false,
            displayWidthInPoints: 1920,
            displayHeightInPoints: 1080,
            displayFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            screenshotWidthInPixels: 1920,
            screenshotHeightInPixels: 1080
        )

        let appKitGlobalPoint = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: CGPoint(x: 960, y: 540),
            on: secondaryDisplayCapture
        )
        // Compare as CGFloat directly — Swift would otherwise see
        // `1512 + 960` as an Int expression and fail to coerce.
        #expect(appKitGlobalPoint.x == CGFloat(2472))
        #expect(appKitGlobalPoint.y == CGFloat(540))
    }
}
