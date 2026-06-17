//
//  PaceAnnotationOverlayController.swift
//  leanring-buddy
//
//  Holds the currently visible tuition-mode annotation layer.
//  CompanionManager owns one instance; the overlay's
//  `PaceAnnotationLayerView` observes the @Published list and re-renders.
//
//  Annotations are produced by the planner via `draw_annotation` and
//  removed via `clear_annotations`, the next user turn (PTT-release), or
//  the 30 s auto-fade. Geometry stored here is already in AppKit-global
//  coordinates — the screenshot-pixel → AppKit conversion happens at
//  drain time in `PaceAnnotationActionDrainer.drain(...)` so the
//  overlay does not need the per-screen capture metadata.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Annotation geometry as it will be rendered. Coordinates are in
/// AppKit-global screen space (bottom-left origin); the overlay then
/// runs the same `convertScreenPointToSwiftUICoordinates` it already
/// uses for the blue cursor to map each vertex to its SwiftUI local
/// frame on the matching `NSScreen`.
enum PaceAnnotationAppKitGeometry: Equatable {
    /// AppKit `CGRect` (origin = bottom-left of the rect).
    case rect(CGRect)
    case ellipse(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(tail: CGPoint, head: CGPoint)
    case polygon([CGPoint])
}

/// One rendered annotation: post-conversion geometry, style, and which
/// 1-based screen index it lives on. Identifiable so SwiftUI's ForEach
/// can diff entries during the fade-in/out transition.
struct PaceRenderedAnnotation: Identifiable, Equatable {
    let id: UUID
    let geometry: PaceAnnotationAppKitGeometry
    let style: PaceAnnotationStyle
    let screenIndex: Int

    init(
        id: UUID = UUID(),
        geometry: PaceAnnotationAppKitGeometry,
        style: PaceAnnotationStyle,
        screenIndex: Int
    ) {
        self.id = id
        self.geometry = geometry
        self.style = style
        self.screenIndex = screenIndex
    }
}

/// Owns the visible annotation list plus the 30-second auto-fade timer.
/// Pure state container: knows nothing about pixel-to-AppKit conversion
/// (the drainer handles that) or rendering (the overlay handles that).
@MainActor
final class PaceAnnotationOverlayController: ObservableObject {

    /// Active annotations. SwiftUI overlay layers observe this directly.
    /// Empty array = nothing drawn.
    @Published private(set) var activeAnnotations: [PaceRenderedAnnotation] = []

    /// Seconds before auto-fading the annotation layer. Lifecycle PRD
    /// says "next user turn OR 30 s, whichever first" — this is the
    /// 30 s leg. Injected so tests can supply a tiny delay.
    private let autoFadeDelaySeconds: TimeInterval

    /// Outstanding auto-fade `Task`. Cancelled on every `clear` and
    /// replaced on every `setAnnotations`, so back-to-back draw calls
    /// always get a fresh 30 s window.
    private var pendingAutoFadeTask: Task<Void, Never>?

    init(autoFadeDelaySeconds: TimeInterval = 30.0) {
        self.autoFadeDelaySeconds = autoFadeDelaySeconds
    }

    /// Replace the active layer with these annotations and (re)start the
    /// auto-fade timer. Called by `PaceAnnotationActionDrainer` after
    /// it has converted the planner's screenshot pixels to AppKit
    /// globals for the matching screen.
    func setAnnotations(_ renderedAnnotations: [PaceRenderedAnnotation]) {
        activeAnnotations = renderedAnnotations
        scheduleAutoFade()
    }

    /// Wipe all annotations. `reason` is logged but not exposed in the
    /// UI — the user just sees them disappear.
    func clear(reason: String) {
        pendingAutoFadeTask?.cancel()
        pendingAutoFadeTask = nil
        guard !activeAnnotations.isEmpty else { return }
        print("🧽 Clearing \(activeAnnotations.count) annotation(s): \(reason)")
        activeAnnotations = []
    }

    /// Convenience: called by CompanionManager at PTT-release of the
    /// next user turn. Lifecycle PRD: tuition annotations persist
    /// across the turn that produced them but never bleed into the
    /// turn that follows.
    func clearOnNextUserTurn() {
        clear(reason: "next user turn")
    }

    private func scheduleAutoFade() {
        pendingAutoFadeTask?.cancel()
        let delay = autoFadeDelaySeconds
        pendingAutoFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clear(reason: "30 s auto-fade")
        }
    }
}

// MARK: - Pixel → AppKit coordinate mapper

/// Pure helper for the screenshot-pixel → AppKit-global conversion that
/// `CompanionManager` already used for the pointing cursor. Extracted so
/// the annotation drainer can reuse the same math without re-deriving
/// it; both paths now share one tested function.
///
/// Mirrors the inline arithmetic at the pointing call site in
/// `CompanionManager`: clamp to screenshot bounds, scale into display
/// points, flip y to AppKit's bottom-left origin, translate into the
/// display's frame.
nonisolated enum PaceAnnotationCoordinateMapper {

    /// Convert a screenshot-pixel point on the given capture into the
    /// AppKit-global coordinate (bottom-left origin) used by overlay
    /// rendering and `NSEvent.mouseLocation`.
    static func convertScreenshotPixelToAppKitGlobal(
        screenshotPixelPoint pixelPoint: CGPoint,
        on screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        let clampedPixelX = max(0, min(pixelPoint.x, screenshotWidth))
        let clampedPixelY = max(0, min(pixelPoint.y, screenshotHeight))
        let displayLocalX = clampedPixelX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedPixelY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }
}

// MARK: - Action drainer

/// Pulls `.drawAnnotation` and `.clearAnnotations` actions out of a
/// parsed plan, executes them against the overlay controller, and
/// returns the plan with those actions stripped. The remaining plan is
/// forwarded to `PaceActionExecutor` unchanged — the executor never has
/// to know the overlay exists.
///
/// Mirrors the structural pattern of the streaming-mail-draft handling
/// in `CompanionManager`: detect a special action shape, side-effect it
/// inline, return a leaner plan to the next stage.
@MainActor
enum PaceAnnotationActionDrainer {

    struct DrainOutcome {
        /// Original parse result with annotation actions stripped from
        /// both `actions` and `executionPlan`. `spokenText` and
        /// `firstClickVisualisationLocation` flow through unchanged.
        /// Steps that become empty after draining are dropped so the
        /// executor doesn't run no-op groups.
        let drainedParseResult: PaceActionTagParseResult
        /// `true` when at least one annotation action was drained — the
        /// caller can use this to decide whether to log a tool-call
        /// debug record.
        let didDrainAnyAnnotationAction: Bool
    }

    /// Walk the plan in order; for each `.drawAnnotation` and
    /// `.clearAnnotations`, side-effect the controller and drop the
    /// action. The controller's lifecycle (auto-fade + next-turn clear)
    /// is handled inside it — this only does the dispatch.
    static func drain(
        parseResult: PaceActionTagParseResult,
        into overlayController: PaceAnnotationOverlayController,
        screenCaptures: [CompanionScreenCapture]
    ) -> DrainOutcome {
        var didDrainAny = false
        var remainingSteps: [PaceActionExecutionStep] = []

        for step in parseResult.executionPlan.steps {
            var remainingActionsInStep: [PaceParsedAction] = []
            for action in step.actions {
                switch action {
                case .drawAnnotation(let annotationRequest):
                    applyDrawAnnotation(
                        annotationRequest,
                        into: overlayController,
                        screenCaptures: screenCaptures
                    )
                    didDrainAny = true
                case .clearAnnotations:
                    overlayController.clear(reason: "planner clear_annotations")
                    didDrainAny = true
                default:
                    remainingActionsInStep.append(action)
                }
            }
            if !remainingActionsInStep.isEmpty {
                remainingSteps.append(PaceActionExecutionStep(actions: remainingActionsInStep))
            }
        }

        let drainedActions = parseResult.actions.filter { action in
            switch action {
            case .drawAnnotation, .clearAnnotations:
                return false
            default:
                return true
            }
        }

        let drainedParseResult = PaceActionTagParseResult(
            spokenText: parseResult.spokenText,
            actions: drainedActions,
            executionPlan: PaceActionExecutionPlan(steps: remainingSteps),
            firstClickVisualisationLocation: parseResult.firstClickVisualisationLocation
        )
        return DrainOutcome(
            drainedParseResult: drainedParseResult,
            didDrainAnyAnnotationAction: didDrainAny
        )
    }

    /// Convert one annotation request into rendered AppKit geometry and
    /// push it onto the controller. Picks the matching screen capture
    /// using the request's 1-based `screenNumber`, falling back to the
    /// cursor screen (matches `[POINT]` semantics).
    private static func applyDrawAnnotation(
        _ annotationRequest: PaceAnnotationRequest,
        into overlayController: PaceAnnotationOverlayController,
        screenCaptures: [CompanionScreenCapture]
    ) {
        guard let targetScreenCapture = resolveTargetScreenCapture(
            requestedScreenNumber: annotationRequest.screenNumber,
            screenCaptures: screenCaptures
        ) else {
            print("⚠️ draw_annotation skipped: no matching screen capture")
            return
        }

        // 1-based screen index, matching the planner's `screen` field
        // and the existing `[POINT]` screen numbering. Use the index of
        // the resolved capture in the screenCaptures array.
        guard let resolvedScreenIndex = screenCaptures.firstIndex(where: {
            $0.displayFrame == targetScreenCapture.displayFrame
        }).map({ $0 + 1 }) else {
            return
        }

        let renderedAnnotations = annotationRequest.shapes.map { shape in
            PaceRenderedAnnotation(
                geometry: convertShapeToAppKitGeometry(shape, on: targetScreenCapture),
                style: shape.style,
                screenIndex: resolvedScreenIndex
            )
        }
        overlayController.setAnnotations(renderedAnnotations)
    }

    /// 1-based screen number → matching capture. Falls back to the
    /// cursor screen when the requested number is missing or out of
    /// range — same fallback as the `[POINT]` pipeline.
    private static func resolveTargetScreenCapture(
        requestedScreenNumber: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        if let requestedScreenNumber,
           requestedScreenNumber >= 1,
           requestedScreenNumber <= screenCaptures.count {
            return screenCaptures[requestedScreenNumber - 1]
        }
        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }

    /// Walk each shape vertex through
    /// `PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal`
    /// and assemble the matching AppKit-global geometry case.
    private static func convertShapeToAppKitGeometry(
        _ shape: PaceAnnotationShape,
        on screenCapture: CompanionScreenCapture
    ) -> PaceAnnotationAppKitGeometry {
        switch shape {
        case .rect(let pixelX, let pixelY, let widthPixels, let heightPixels, _):
            return .rect(convertScreenshotPixelRectToAppKit(
                x: pixelX,
                y: pixelY,
                width: widthPixels,
                height: heightPixels,
                on: screenCapture
            ))
        case .ellipse(let pixelX, let pixelY, let widthPixels, let heightPixels, _):
            return .ellipse(convertScreenshotPixelRectToAppKit(
                x: pixelX,
                y: pixelY,
                width: widthPixels,
                height: heightPixels,
                on: screenCapture
            ))
        case .line(let firstX, let firstY, let secondX, let secondY, _):
            return .line(
                start: PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
                    screenshotPixelPoint: CGPoint(x: firstX, y: firstY),
                    on: screenCapture
                ),
                end: PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
                    screenshotPixelPoint: CGPoint(x: secondX, y: secondY),
                    on: screenCapture
                )
            )
        case .arrow(let tailX, let tailY, let headX, let headY, _):
            return .arrow(
                tail: PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
                    screenshotPixelPoint: CGPoint(x: tailX, y: tailY),
                    on: screenCapture
                ),
                head: PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
                    screenshotPixelPoint: CGPoint(x: headX, y: headY),
                    on: screenCapture
                )
            )
        case .polygon(let pixelPoints, _):
            let appKitPoints = pixelPoints.map { pixelPoint in
                PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
                    screenshotPixelPoint: pixelPoint,
                    on: screenCapture
                )
            }
            return .polygon(appKitPoints)
        }
    }

    /// Convert a screenshot-pixel rect (top-left origin, +y goes down)
    /// into an AppKit-global rect (bottom-left origin). Since AppKit's
    /// y grows upward, the rect's BOTTOM-LEFT corner is the pixel
    /// rect's TOP-LEFT corner after the y-flip. Both corners are
    /// independently mapped to avoid any drift.
    private static func convertScreenshotPixelRectToAppKit(
        x pixelX: Double,
        y pixelY: Double,
        width widthPixels: Double,
        height heightPixels: Double,
        on screenCapture: CompanionScreenCapture
    ) -> CGRect {
        let pixelTopLeft = CGPoint(x: pixelX, y: pixelY)
        let pixelBottomRight = CGPoint(x: pixelX + widthPixels, y: pixelY + heightPixels)
        let appKitTopLeft = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: pixelTopLeft,
            on: screenCapture
        )
        let appKitBottomRight = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: pixelBottomRight,
            on: screenCapture
        )
        // AppKit y-flip: the pixel top-left is the AppKit top-left
        // (higher y), and the pixel bottom-right is the AppKit
        // bottom-right (lower y). CGRect wants bottom-left origin +
        // positive width/height.
        let rectOriginX = min(appKitTopLeft.x, appKitBottomRight.x)
        let rectOriginY = min(appKitTopLeft.y, appKitBottomRight.y)
        let rectWidth = abs(appKitBottomRight.x - appKitTopLeft.x)
        let rectHeight = abs(appKitTopLeft.y - appKitBottomRight.y)
        return CGRect(
            x: rectOriginX,
            y: rectOriginY,
            width: rectWidth,
            height: rectHeight
        )
    }
}
