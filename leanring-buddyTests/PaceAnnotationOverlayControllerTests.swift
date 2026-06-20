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
        // Use a deliberately generous window — Task.sleep precision on
        // a busy CI machine slips by tens of milliseconds, so the
        // original 150 ms window was too tight. The behavior we're
        // pinning is "a second setAnnotations restarts the timer,"
        // not "the timer fires within 150ms of nominal" — so longer
        // windows + a larger safety margin keep this stable without
        // weakening the assertion.
        let overlayController = PaceAnnotationOverlayController(autoFadeDelaySeconds: 0.5)
        overlayController.setAnnotations([
            PaceRenderedAnnotation(
                geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                style: .default,
                screenIndex: 1
            )
        ])
        try await Task.sleep(nanoseconds: 300_000_000) // 60% into the first window

        // Re-set BEFORE the first timer fires; the old one must be
        // cancelled and a fresh 500ms window must begin.
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

        // The ORIGINAL window (0.5s from time 0) is now in its 5th
        // tenth. Wait past the original-window expiry to confirm the
        // layer is still present — i.e. the re-set DID cancel the
        // first timer.
        try await Task.sleep(nanoseconds: 300_000_000) // 600ms total elapsed; orig would have fired at 500ms
        #expect(overlayController.activeAnnotations.count == 2)

        // Now wait past the FRESH window's expiry, polling so a busy
        // test runner doesn't flake on MainActor timer delivery.
        for _ in 0..<40 where !overlayController.activeAnnotations.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await Task.yield()
        #expect(overlayController.activeAnnotations.isEmpty)
    }
}
