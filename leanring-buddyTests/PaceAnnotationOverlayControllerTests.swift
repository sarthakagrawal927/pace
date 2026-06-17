//
//  PaceAnnotationOverlayControllerTests.swift
//  leanring-buddyTests
//
//  Lifecycle tests for the tuition-mode annotation controller.
//  Use a small `autoFadeDelaySeconds` so the auto-fade timer fires
//  inside a unit-test budget.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceAnnotationOverlayControllerTests {

    @Test func setAnnotationsPopulatesActiveLayer() async throws {
        let overlayController = PaceAnnotationOverlayController(autoFadeDelaySeconds: 10)
        let renderedAnnotation = PaceRenderedAnnotation(
            geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
            style: .default,
            screenIndex: 1
        )
        overlayController.setAnnotations([renderedAnnotation])
        #expect(overlayController.activeAnnotations.count == 1)
    }

    @Test func clearEmptiesActiveLayer() async throws {
        let overlayController = PaceAnnotationOverlayController(autoFadeDelaySeconds: 10)
        overlayController.setAnnotations([
            PaceRenderedAnnotation(
                geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                style: .default,
                screenIndex: 1
            )
        ])
        overlayController.clear(reason: "test")
        #expect(overlayController.activeAnnotations.isEmpty)
    }

    @Test func clearOnNextUserTurnIsAnAliasForClear() async throws {
        let overlayController = PaceAnnotationOverlayController(autoFadeDelaySeconds: 10)
        overlayController.setAnnotations([
            PaceRenderedAnnotation(
                geometry: .line(start: .zero, end: CGPoint(x: 10, y: 10)),
                style: .default,
                screenIndex: 2
            )
        ])
        overlayController.clearOnNextUserTurn()
        #expect(overlayController.activeAnnotations.isEmpty)
    }

    @Test func autoFadeTimerFiresAndWipesLayer() async throws {
        // Injected 0.05 s so the test never blocks long. The
        // production default (30 s) is documented in
        // PaceAnnotationOverlayController. Wait 10× the fade delay
        // plus a yield so the MainActor-bound task definitely fires
        // before we assert.
        let overlayController = PaceAnnotationOverlayController(autoFadeDelaySeconds: 0.05)
        overlayController.setAnnotations([
            PaceRenderedAnnotation(
                geometry: .ellipse(CGRect(x: 0, y: 0, width: 20, height: 20)),
                style: .default,
                screenIndex: 1
            )
        ])
        try await Task.sleep(nanoseconds: 500_000_000)
        await Task.yield()
        #expect(overlayController.activeAnnotations.isEmpty)
    }

    @Test func newSetAnnotationsResetsAutoFadeWindow() async throws {
        let overlayController = PaceAnnotationOverlayController(autoFadeDelaySeconds: 0.15)
        overlayController.setAnnotations([
            PaceRenderedAnnotation(
                geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                style: .default,
                screenIndex: 1
            )
        ])
        try await Task.sleep(nanoseconds: 100_000_000)
        // Re-set just before the prior timer would have fired. The
        // first task should be cancelled and a fresh 150 ms window
        // started.
        overlayController.setAnnotations([
            PaceRenderedAnnotation(
                geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                style: .default,
                screenIndex: 1
            ),
            PaceRenderedAnnotation(
                geometry: .rect(CGRect(x: 20, y: 0, width: 10, height: 10)),
                style: .default,
                screenIndex: 1
            )
        ])
        // The original 150 ms window has now elapsed (we slept 100 ms
        // + a re-set), but the fresh window restarted at the re-set
        // moment, so the layer should still be present.
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(overlayController.activeAnnotations.count == 2)

        // Now wait past the fresh window and the layer should clear.
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(overlayController.activeAnnotations.isEmpty)
    }
}
