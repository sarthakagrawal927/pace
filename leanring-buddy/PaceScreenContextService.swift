//
//  PaceScreenContextService.swift
//  leanring-buddy
//
//  Extracted from CompanionManager during the Wave 7b refactor (Pace
//  v0.3.12 follow-up). Owns the per-screen VLM analysis cache, the
//  AX + OCR + VLM coordinator, and the push-to-talk-press prewarm
//  task. Behavior is byte-identical to the pre-extraction logic that
//  lived in CompanionManager — this is a pure code move.
//
//  CompanionManager now talks to this service through a small
//  surface: prewarm at PTT press / deeplink chat, build the planner
//  prompt at agent-loop time, look up the cached description for the
//  watch-mode nudge generator, and invalidate the cache when needed.
//

import AppKit
import CryptoKit
import Foundation

// MARK: - Cache identity / cached analysis

/// Per-screen VLM analysis cached by the analyzer identity plus pixel hash.
/// As long as the model/runtime/display and screen pixels haven't changed,
/// repeat questions reuse the cached element map — zero VLM cost.
///
/// Moved out of CompanionManager so the service owns its own cache key.
struct PaceScreenAnalysisCacheIdentity: Equatable {
    let analyzerDisplayName: String
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect

    init(
        analyzerDisplayName: String,
        capture: CompanionScreenCapture
    ) {
        self.analyzerDisplayName = analyzerDisplayName
        self.screenshotWidthInPixels = capture.screenshotWidthInPixels
        self.screenshotHeightInPixels = capture.screenshotHeightInPixels
        self.displayWidthInPoints = capture.displayWidthInPoints
        self.displayHeightInPoints = capture.displayHeightInPoints
        self.displayFrame = capture.displayFrame
    }
}

struct PaceCachedScreenAnalysis {
    let identity: PaceScreenAnalysisCacheIdentity
    let pixelHash: String
    let visualFingerprint: PaceScreenVisualFingerprint?
    let analysis: LocalVLMScreenAnalysis
    let capturedAt: Date
}

// MARK: - Prewarmed context envelope (returned by the prewarm Task)

/// Snapshot returned by the pre-warm task. Held briefly between
/// PTT press and transcript arrival; consumed once by the agent
/// loop's first step then cleared.
///
/// Public so CompanionManager's agent loop can hold the awaited
/// result while it builds the planner prompt.
struct PaceScreenContextPrewarmedSnapshot {
    let screenCaptures: [CompanionScreenCapture]
    let enrichedAnalysesByScreenLabel: [String: LocalVLMScreenAnalysis]
}

/// Reason the prewarm was kicked off — printed in diagnostics so a
/// reader of the log can tell whether the screen-context warm-up was
/// triggered by the PTT key, a deeplink chat turn, or app start.
enum PaceScreenContextPrewarmReason: String {
    case appLaunch
    case pushToTalkPress
    case deepLinkChat
}

// MARK: - PaceScreenContextService

/// `@MainActor` coordinator that owns:
///  * the per-screen VLM analysis cache
///  * the PTT-press prewarm Task
///  * the AX + OCR + VLM merge logic
///  * the planner-prompt formatting helpers
///
/// All behavior is verbatim from CompanionManager. Constructor takes
/// the existing client instances and a `() -> Bool` flag-provider so
/// the service doesn't read UserDefaults directly — CompanionManager
/// still owns the user-facing preference state.
@MainActor
final class PaceScreenContextService {

    // MARK: Dependencies

    private let screenAnalysisClient: any PaceScreenAnalysisClient
    private let visionOCRClient: PaceVisionOCRClient
    private let axScreenReader: PaceAXScreenReader
    private let isReadMyScreenEnabled: () -> Bool

    // MARK: State (moved verbatim from CompanionManager)

    /// Task started at PTT press that captures the screen and runs the
    /// VLM + OCR in parallel. By the time the user finishes speaking
    /// (~2-5s typical), the result is usually ready. The agent loop
    /// awaits this instead of doing the work serially after the
    /// transcript arrives. nil when not started or when pre-warm is
    /// disabled (e.g. "Read My Screen" toggle off).
    private var prewarmedScreenContextTask: Task<PaceScreenContextPrewarmedSnapshot?, Never>?

    /// Per-screen VLM analysis cache keyed by screen label (e.g.
    /// "primary focus", "screen 2"). Hash of the screenshot's JPEG
    /// bytes is checked on each turn: hash match → reuse cached
    /// analysis for free; hash mismatch → re-run VLM only on the
    /// changed screens, in parallel with the rest.
    private var perScreenAnalysisCache: [String: PaceCachedScreenAnalysis] = [:]

    // MARK: Init

    init(
        screenAnalysisClient: any PaceScreenAnalysisClient,
        visionOCRClient: PaceVisionOCRClient,
        axScreenReader: PaceAXScreenReader,
        isReadMyScreenEnabled: @escaping () -> Bool
    ) {
        self.screenAnalysisClient = screenAnalysisClient
        self.visionOCRClient = visionOCRClient
        self.axScreenReader = axScreenReader
        self.isReadMyScreenEnabled = isReadMyScreenEnabled
    }

    // MARK: - Public surface

    /// Kicks off the screen-context pre-warm at PTT press. By the time
    /// the user releases (~2-5s of speech), the VLM + OCR have usually
    /// finished — so the planner can start immediately without waiting.
    /// Cancellable: a quick press-release replaces the task with a new
    /// one or nil.
    @discardableResult
    func prewarmScreenContext(
        reason: PaceScreenContextPrewarmReason
    ) -> Task<PaceScreenContextPrewarmedSnapshot?, Never>? {
        prewarmedScreenContextTask?.cancel()
        guard isReadMyScreenEnabled() else {
            prewarmedScreenContextTask = nil
            print("👁️  Skipping prewarm — Read My Screen is off (reason=\(reason.rawValue))")
            return nil
        }
        // Snapshot the dependencies so the detached task doesn't have
        // to hop back to MainActor for them.
        let vlmClient = screenAnalysisClient
        let ocrClient = visionOCRClient
        let newTask = Task { [weak self] () -> PaceScreenContextPrewarmedSnapshot? in
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first else {
                    return nil
                }

                // Hash check — reuse cached analysis if the screen
                // hasn't changed since last turn. Cache lookups are
                // MainActor-bound so we hop briefly.
                let pixelHash = Self.computePixelHash(for: cursorScreenCapture.imageData)
                let visualFingerprint = PaceScreenImageDiffer.fingerprint(for: cursorScreenCapture.imageData)
                let cacheIdentity = PaceScreenAnalysisCacheIdentity(
                    analyzerDisplayName: vlmClient.displayName,
                    capture: cursorScreenCapture
                )
                let cachedAnalysis = await MainActor.run { () -> LocalVLMScreenAnalysis? in
                    guard let self else { return nil }
                    guard let cached = self.perScreenAnalysisCache[cursorScreenCapture.label] else {
                        return nil
                    }
                    guard cached.identity == cacheIdentity else {
                        print("👁️  Prewarm cache MISS for \(cursorScreenCapture.label) — analyzer or display changed")
                        return nil
                    }
                    if cached.pixelHash == pixelHash {
                        print("👁️  Prewarm cache HIT for \(cursorScreenCapture.label)")
                        return cached.analysis
                    }
                    if let cachedVisualFingerprint = cached.visualFingerprint,
                       let visualFingerprint,
                       let visualDiff = PaceScreenImageDiffer.diff(
                        from: cachedVisualFingerprint,
                        to: visualFingerprint
                       ),
                       !visualDiff.isMeaningful {
                        self.perScreenAnalysisCache[cursorScreenCapture.label] = PaceCachedScreenAnalysis(
                            identity: cacheIdentity,
                            pixelHash: pixelHash,
                            visualFingerprint: visualFingerprint,
                            analysis: cached.analysis,
                            capturedAt: Date()
                        )
                        print(String(format: "👁️  Prewarm visual diff cache HIT for %@ — %.3f changed, %.1f mean delta", cursorScreenCapture.label, visualDiff.changedPixelRatio, visualDiff.meanPixelDelta))
                        return cached.analysis
                    }
                    return nil
                }

                if let cachedAnalysis {
                    return PaceScreenContextPrewarmedSnapshot(
                        screenCaptures: [cursorScreenCapture],
                        enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: cachedAnalysis]
                    )
                }

                // Fast tier: try the AX tree of the focused window
                // before standing up the VLM. AX is 10-100x faster
                // than the VLM and covers most AppKit / SwiftUI /
                // Catalyst apps cleanly. Fires in parallel with OCR
                // so we still get verbatim text enrichment.
                // Scaled to the cursor screen's actual screenshot
                // dimensions so the planner sees coordinates in the
                // same pixel space the executor uses for clicks
                // (downsampled to maxDimension=1280, not Retina-native).
                // Capture the AX reader into a local before the concurrent
                // async-let so the closure doesn't re-capture the Task's weak
                // `self` (which Swift 6 flags as a captured-var reference in
                // concurrently-executing code).
                let axScreenReaderForPrewarm = await MainActor.run { [weak self] in self?.axScreenReader }
                async let axElementsFuture: [LocalVLMScreenElement] = MainActor.run {
                    axScreenReaderForPrewarm?.readFocusedWindow(scalingToScreenshot: cursorScreenCapture) ?? []
                }
                async let earlyOCRBoxesFuture = ocrClient.recognizeText(
                    in: cursorScreenCapture.imageData,
                    screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                )
                let axElements = await axElementsFuture
                if !axElements.isEmpty {
                    let earlyOCRBoxes = (try? await earlyOCRBoxesFuture) ?? []
                    let synthesizedAnalysisFromAX = LocalVLMScreenAnalysis(
                        elements: axElements,
                        description: ""
                    )
                    let enrichedFromAX = PaceScreenContextMerger.enrich(
                        vlmAnalysis: synthesizedAnalysisFromAX,
                        with: earlyOCRBoxes
                    )
                    print("👁️  Prewarm AX HIT: \(axElements.count) elements + \(earlyOCRBoxes.count) OCR boxes — skipping VLM")
                    await MainActor.run { [weak self] in
                        self?.perScreenAnalysisCache[cursorScreenCapture.label] = PaceCachedScreenAnalysis(
                            identity: cacheIdentity,
                            pixelHash: pixelHash,
                            visualFingerprint: visualFingerprint,
                            analysis: enrichedFromAX,
                            capturedAt: Date()
                        )
                    }
                    return PaceScreenContextPrewarmedSnapshot(
                        screenCaptures: [cursorScreenCapture],
                        enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: enrichedFromAX]
                    )
                }

                print("👁️  Prewarm AX returned nothing — falling back to VLM + OCR…")
                // Reuse the OCR future from the AX attempt above —
                // it's been running concurrently and we don't want to
                // double-spend on the same screenshot.
                async let vlmAnalysisFuture = vlmClient.analyzeScreenshot(
                    screenshotImageData: cursorScreenCapture.imageData,
                    userIntent: "general screen analysis"
                )

                let vlmAnalysis: LocalVLMScreenAnalysis
                do {
                    vlmAnalysis = try await vlmAnalysisFuture
                } catch {
                    print("⚠️ Prewarm VLM failed: \(error.localizedDescription)")
                    // Fall back to OCR-only context
                    let ocrBoxesFallback = (try? await earlyOCRBoxesFuture) ?? []
                    let descriptionFromOCR = ocrBoxesFallback.prefix(8)
                        .map { $0.text }
                        .joined(separator: " · ")
                    let ocrOnlyAnalysis = LocalVLMScreenAnalysis(
                        elements: PaceScreenContextMerger.enrich(
                            vlmAnalysis: LocalVLMScreenAnalysis(elements: [], description: ""),
                            with: ocrBoxesFallback
                        ).elements,
                        description: descriptionFromOCR.isEmpty
                            ? "VLM failed; OCR text only."
                            : "VLM failed. OCR text snippets: \(descriptionFromOCR)"
                    )
                    return PaceScreenContextPrewarmedSnapshot(
                        screenCaptures: [cursorScreenCapture],
                        enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: ocrOnlyAnalysis]
                    )
                }

                let ocrBoxes = (try? await earlyOCRBoxesFuture) ?? []
                let enriched = PaceScreenContextMerger.enrich(
                    vlmAnalysis: vlmAnalysis,
                    with: ocrBoxes
                )

                // Update cache for next turn.
                await MainActor.run { [weak self] in
                    self?.perScreenAnalysisCache[cursorScreenCapture.label] = PaceCachedScreenAnalysis(
                        identity: cacheIdentity,
                        pixelHash: pixelHash,
                        visualFingerprint: visualFingerprint,
                        analysis: enriched,
                        capturedAt: Date()
                    )
                }
                print("👁️  Prewarm complete: \(enriched.elements.count) elements (\(ocrBoxes.count) OCR boxes merged)")

                return PaceScreenContextPrewarmedSnapshot(
                    screenCaptures: [cursorScreenCapture],
                    enrichedAnalysesByScreenLabel: [cursorScreenCapture.label: enriched]
                )
            } catch {
                print("⚠️ Prewarm failed: \(error.localizedDescription)")
                return nil
            }
        }
        prewarmedScreenContextTask = newTask
        return newTask
    }

    /// Awaits and consumes the in-flight prewarm task (if any). The
    /// agent loop calls this at the top of its first step so it can
    /// reuse the PTT-press capture instead of grabbing a fresh
    /// screenshot. Returns nil if no prewarm task is in flight.
    ///
    /// After this call, the prewarm task handle is cleared — the next
    /// `prewarmScreenContext(reason:)` starts fresh.
    func consumeInFlightPrewarmedSnapshot() async -> PaceScreenContextPrewarmedSnapshot? {
        guard let prewarmedTask = prewarmedScreenContextTask else { return nil }
        let snapshot = await prewarmedTask.value
        prewarmedScreenContextTask = nil
        return snapshot
    }

    /// True when a prewarm task is currently in flight (or its result
    /// is still cached for consumption). The agent loop uses this to
    /// decide whether to await the prewarm vs. capture a fresh screen.
    var hasInFlightPrewarmedTask: Bool {
        return prewarmedScreenContextTask != nil
    }

    /// Build the planner-prompt prefix for the current turn. Mirrors
    /// the verbatim logic from CompanionManager: respects the "Read
    /// My Screen" toggle, prefers the prewarmed context when supplied
    /// or in-flight, then falls back to the synchronous VLM/AX+OCR
    /// path. Returns the transcript unchanged when no screen context
    /// is available.
    func buildUserPromptWithLocalVLMContextIfEnabled(
        transcript: String,
        screenCaptures: [CompanionScreenCapture],
        prewarmedContext: PaceScreenContextPrewarmedSnapshot? = nil
    ) async -> String {
        guard isReadMyScreenEnabled() else {
            print("👁️  VLM skipped — 'Read My Screen' toggle is off")
            return transcript
        }

        if let prewarmedContext,
           !prewarmedContext.screenCaptures.isEmpty {
            print("👁️  Pre-warm context supplied by first-step capture path")
            return buildPromptFromEnrichedAnalyses(
                transcript: transcript,
                captures: prewarmedContext.screenCaptures,
                enrichedAnalysesByLabel: prewarmedContext.enrichedAnalysesByScreenLabel
            )
        }

        // First try: did the PTT-press pre-warm finish? If yes, we
        // consume its result and skip the synchronous VLM + OCR work
        // entirely — perceived VLM latency drops to ~0.
        if let prewarmedTask = prewarmedScreenContextTask {
            print("👁️  Awaiting pre-warm result…")
            let awaitStartedAt = Date()
            let prewarmed = await prewarmedTask.value
            prewarmedScreenContextTask = nil
            let awaitedDuration = Date().timeIntervalSince(awaitStartedAt)
            if let prewarmed, !prewarmed.screenCaptures.isEmpty {
                print(String(format: "👁️  Pre-warm consumed in %.2fs", awaitedDuration))
                return buildPromptFromEnrichedAnalyses(
                    transcript: transcript,
                    captures: prewarmed.screenCaptures,
                    enrichedAnalysesByLabel: prewarmed.enrichedAnalysesByScreenLabel
                )
            }
            print("⚠️ Pre-warm returned nothing — falling back to synchronous VLM")
        }

        guard !screenCaptures.isEmpty else {
            print("⚠️ VLM skipped — no screen captures available")
            return transcript
        }

        // Synchronous fallback: pre-warm wasn't started or failed.
        // Cursor-screen-only by design — user is almost always asking
        // about the screen they're looking at.
        let orderedCaptures: [CompanionScreenCapture] = {
            if let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) {
                return [cursorScreenCapture]
            }
            if let firstCapture = screenCaptures.first {
                return [firstCapture]
            }
            return []
        }()

        // Bucket captures into cache hits (free, reuse stored analysis)
        // and misses (need a fresh VLM call). Hash is SHA256 of the JPEG
        // bytes — stable across runs, cheap (~5ms for 1MB).
        var perCaptureCachedAnalysis: [Int: LocalVLMScreenAnalysis] = [:]
        var capturesToAnalyze: [(captureIndex: Int, capture: CompanionScreenCapture, pixelHash: String, visualFingerprint: PaceScreenVisualFingerprint?)] = []

        for (captureIndex, capture) in orderedCaptures.enumerated() {
            let pixelHash = Self.computePixelHash(for: capture.imageData)
            let visualFingerprint = PaceScreenImageDiffer.fingerprint(for: capture.imageData)
            let cacheIdentity = PaceScreenAnalysisCacheIdentity(
                analyzerDisplayName: screenAnalysisClient.displayName,
                capture: capture
            )
            if let cached = perScreenAnalysisCache[capture.label] {
                guard cached.identity == cacheIdentity else {
                    print("👁️  Cache MISS for \(capture.label) — analyzer or display changed")
                    capturesToAnalyze.append((captureIndex, capture, pixelHash, visualFingerprint))
                    continue
                }
                if cached.pixelHash == pixelHash {
                    perCaptureCachedAnalysis[captureIndex] = cached.analysis
                    print("👁️  Cache HIT for \(capture.label) — reusing \(cached.analysis.elements.count) elements")
                    continue
                }

                if let cachedVisualFingerprint = cached.visualFingerprint,
                   let visualFingerprint,
                   let visualDiff = PaceScreenImageDiffer.diff(
                    from: cachedVisualFingerprint,
                    to: visualFingerprint
                   ),
                   !visualDiff.isMeaningful {
                    perCaptureCachedAnalysis[captureIndex] = cached.analysis
                    perScreenAnalysisCache[capture.label] = PaceCachedScreenAnalysis(
                        identity: cacheIdentity,
                        pixelHash: pixelHash,
                        visualFingerprint: visualFingerprint,
                        analysis: cached.analysis,
                        capturedAt: Date()
                    )
                    print(String(format: "👁️  Visual diff cache HIT for %@ — %.3f changed, %.1f mean delta", capture.label, visualDiff.changedPixelRatio, visualDiff.meanPixelDelta))
                    continue
                }
            }

            capturesToAnalyze.append((captureIndex, capture, pixelHash, visualFingerprint))
        }

        // Try the AX-tree first on the cursor screen (cheap, ~50ms);
        // if it returns elements we skip the VLM for this in-loop
        // re-analysis the same way the PTT-press pre-warm does. The
        // 2B VLM was failing on every in-loop call last test run,
        // leaving the planner with no screen context and looping on
        // useless scrolls — AX fixes that.
        var capturesStillNeedingVLM: [(captureIndex: Int, capture: CompanionScreenCapture, pixelHash: String, visualFingerprint: PaceScreenVisualFingerprint?)] = []
        var freshAnalysesByCaptureIndex: [Int: LocalVLMScreenAnalysis] = [:]
        if !capturesToAnalyze.isEmpty {
            let axScreenReaderForLoopBody = self.axScreenReader
            let visionOCRClientForLoopBody = self.visionOCRClient
            for (captureIndex, capture, pixelHash, visualFingerprint) in capturesToAnalyze {
                let axElements = axScreenReaderForLoopBody.readFocusedWindow(
                    scalingToScreenshot: capture
                )
                if !axElements.isEmpty {
                    let ocrBoxes = (try? await visionOCRClientForLoopBody.recognizeText(
                        in: capture.imageData,
                        screenshotWidthInPixels: capture.screenshotWidthInPixels,
                        screenshotHeightInPixels: capture.screenshotHeightInPixels
                    )) ?? []
                    let axBackedAnalysis = PaceScreenContextMerger.enrich(
                        vlmAnalysis: LocalVLMScreenAnalysis(elements: axElements, description: ""),
                        with: ocrBoxes
                    )
                    print("👁️  In-loop AX HIT for \(capture.label): \(axElements.count) elements + \(ocrBoxes.count) OCR boxes — skipping VLM")
                    freshAnalysesByCaptureIndex[captureIndex] = axBackedAnalysis
                    perScreenAnalysisCache[capture.label] = PaceCachedScreenAnalysis(
                        identity: PaceScreenAnalysisCacheIdentity(
                            analyzerDisplayName: screenAnalysisClient.displayName,
                            capture: capture
                        ),
                        pixelHash: pixelHash,
                        visualFingerprint: visualFingerprint,
                        analysis: axBackedAnalysis,
                        capturedAt: Date()
                    )
                } else {
                    capturesStillNeedingVLM.append((captureIndex, capture, pixelHash, visualFingerprint))
                }
            }
        }

        // Anything AX couldn't see falls back to the VLM. With the
        // FM planner this is rarely hit; the LM Studio VLM path
        // stays around for Electron / games / broken-AX apps.
        if !capturesStillNeedingVLM.isEmpty {
            print("👁️  Running VLM + OCR on \(capturesStillNeedingVLM.count) screen(s) (AX missed)…")
            let screenAnalysisClientForGroup = screenAnalysisClient
            let visionOCRClientForGroup = visionOCRClient
            let analyses = await withTaskGroup(
                of: (Int, String, LocalVLMScreenAnalysis?, String, PaceScreenVisualFingerprint?).self
            ) { taskGroup in
                for (captureIndex, capture, pixelHash, visualFingerprint) in capturesStillNeedingVLM {
                    taskGroup.addTask { [screenAnalysisClientForGroup, visionOCRClientForGroup] in
                        // VLM + OCR concurrent. OCR finishes much faster
                        // (~100-200ms); we wait on the VLM and then merge.
                        async let vlmAnalysisFuture = screenAnalysisClientForGroup.analyzeScreenshot(
                            screenshotImageData: capture.imageData,
                            userIntent: transcript
                        )
                        async let ocrBoxesFuture = visionOCRClientForGroup.recognizeText(
                            in: capture.imageData,
                            screenshotWidthInPixels: capture.screenshotWidthInPixels,
                            screenshotHeightInPixels: capture.screenshotHeightInPixels
                        )
                        do {
                            let vlmAnalysis = try await vlmAnalysisFuture
                            let ocrBoxes = (try? await ocrBoxesFuture) ?? []
                            let enriched = PaceScreenContextMerger.enrich(
                                vlmAnalysis: vlmAnalysis,
                                with: ocrBoxes
                            )
                            return (captureIndex, capture.label, enriched, pixelHash, visualFingerprint)
                        } catch {
                            print("⚠️ VLM failed for \(capture.label): \(error.localizedDescription)")
                            return (captureIndex, capture.label, nil, pixelHash, visualFingerprint)
                        }
                    }
                }
                var collected: [(Int, String, LocalVLMScreenAnalysis?, String, PaceScreenVisualFingerprint?)] = []
                for await result in taskGroup {
                    collected.append(result)
                }
                return collected
            }
            for (captureIndex, label, maybeAnalysis, pixelHash, visualFingerprint) in analyses {
                guard let analysis = maybeAnalysis else { continue }
                freshAnalysesByCaptureIndex[captureIndex] = analysis
                perScreenAnalysisCache[label] = PaceCachedScreenAnalysis(
                    identity: PaceScreenAnalysisCacheIdentity(
                        analyzerDisplayName: screenAnalysisClient.displayName,
                        capture: orderedCaptures[captureIndex]
                    ),
                    pixelHash: pixelHash,
                    visualFingerprint: visualFingerprint,
                    analysis: analysis,
                    capturedAt: Date()
                )
                print("👁️  VLM analysed \(label): \(analysis.elements.count) elements")
            }
        }

        // Merge cached + fresh analyses back into the original capture order.
        var perScreenPromptSections: [String] = []
        for (captureIndex, capture) in orderedCaptures.enumerated() {
            let analysis = perCaptureCachedAnalysis[captureIndex]
                ?? freshAnalysesByCaptureIndex[captureIndex]
            guard let analysis else { continue }
            perScreenPromptSections.append(Self.formatScreenAnalysisForPrompt(
                screenLabel: capture.label,
                analysis: analysis
            ))
        }

        if perScreenPromptSections.isEmpty {
            print("⚠️ All VLM calls failed — falling back to raw transcript")
            return transcript
        }

        let joinedScreenSections = perScreenPromptSections.joined(separator: "\n\n")
        return """
        On-device screen analysis (auto-extracted by a local vision model on each connected display):

        \(joinedScreenSections)

        User said: \(transcript)
        """
    }

    /// Pulls the most-recent per-screen VLM/OCR description out of
    /// the cache for the watch-mode nudge generator. Returns nil
    /// when no entry exists, when the entry is older than
    /// `maxAgeSeconds` relative to `referenceDate`, or when the
    /// cached description string is empty. Identical freshness gate
    /// to the pre-extraction CompanionManager helpers.
    func cachedDescriptionIfFresh(
        screenLabel: String,
        maxAgeSeconds: TimeInterval = 120,
        referenceDate: Date = Date()
    ) -> String? {
        guard let cachedScreenAnalysis = perScreenAnalysisCache[screenLabel] else { return nil }
        guard referenceDate.timeIntervalSince(cachedScreenAnalysis.capturedAt) <= maxAgeSeconds else {
            return nil
        }
        let cachedDescription = cachedScreenAnalysis.analysis.description
        return cachedDescription.isEmpty ? nil : cachedDescription
    }

    /// The full cached element map for a screen, if recent enough. Used by
    /// Set-of-Mark click recovery to re-mark the same screenshot the failed
    /// click was planned against. See PRD docs/prds/set-of-mark-click-recovery.md.
    func cachedAnalysisIfFresh(
        screenLabel: String,
        maxAgeSeconds: TimeInterval = 120,
        referenceDate: Date = Date()
    ) -> LocalVLMScreenAnalysis? {
        guard let cachedScreenAnalysis = perScreenAnalysisCache[screenLabel] else { return nil }
        guard referenceDate.timeIntervalSince(cachedScreenAnalysis.capturedAt) <= maxAgeSeconds else {
            return nil
        }
        return cachedScreenAnalysis.analysis
    }

    /// Set-of-Mark grounding passthrough to the loaded VLM. Best-effort: any
    /// transport/parse error returns nil so the caller drops recovery.
    func groundMarkedClickTarget(
        markedImageData: Data,
        targetDescription: String,
        markCount: Int
    ) async -> Int? {
        try? await screenAnalysisClient.groundMarkedClickTarget(
            markedImageData: markedImageData,
            targetDescription: targetDescription,
            markCount: markCount
        )
    }

    /// Drops every cached entry. Intended for analyzer-identity or
    /// display-set changes that should invalidate everything in one
    /// shot. Logs the reason so audit trails make the why visible.
    func invalidateAllCachedAnalysis(reason: String) {
        guard !perScreenAnalysisCache.isEmpty else { return }
        print("👁️  Invalidating \(perScreenAnalysisCache.count) cached screen analyses — \(reason)")
        perScreenAnalysisCache.removeAll()
    }

    // MARK: - Internal helpers (moved verbatim from CompanionManager)

    /// Build the planner prompt from already-enriched analyses (the
    /// pre-warm path). Same formatting as the synchronous path so the
    /// planner can't tell whether it's reading a pre-warmed or fresh
    /// analysis — keeps prompt-engineering work consistent.
    private func buildPromptFromEnrichedAnalyses(
        transcript: String,
        captures: [CompanionScreenCapture],
        enrichedAnalysesByLabel: [String: LocalVLMScreenAnalysis]
    ) -> String {
        let perScreenPromptSections: [String] = captures.compactMap { capture in
            guard let analysis = enrichedAnalysesByLabel[capture.label] else { return nil }
            return Self.formatScreenAnalysisForPrompt(
                screenLabel: capture.label,
                analysis: analysis
            )
        }
        guard !perScreenPromptSections.isEmpty else { return transcript }

        // IDE-aware code context. When the frontmost app is a
        // recognised IDE and we can read its window title, prepend a
        // tiny block naming the IDE + focused file. The planner uses
        // this to answer "what does this function do" / "summarize
        // this file" / "rename this variable" without having to
        // extract the filename from raw OCR'd code.
        let ideContextBlock: String = {
            let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let frontmostWindowTitle = Self.frontmostWindowTitleForFrontmostApp()
            guard let detectedContext = PaceIDEContextDetector.detect(
                frontmostBundleIdentifier: frontmostBundleIdentifier,
                frontmostWindowTitle: frontmostWindowTitle
            ) else {
                return ""
            }
            return "Editor context:\n\(PaceIDEContextDetector.renderForPlannerPrompt(detectedContext))\n\n"
        }()

        return """
        \(ideContextBlock)On-device screen analysis (auto-extracted by a local vision model + native OCR):

        \(perScreenPromptSections.joined(separator: "\n\n"))

        User said: \(transcript)
        """
    }

    /// Read the window title of the frontmost app's keyWindow via
    /// `CGWindowListCopyWindowInfo`. ~1 ms; no AX permission required
    /// because window-title metadata is exposed by the window server
    /// for all on-screen windows. Returns nil for apps that don't
    /// expose their window name (rare — most apps including every
    /// IDE we care about set it).
    nonisolated static func frontmostWindowTitleForFrontmostApp() -> String? {
        guard let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let windowInfoListOption: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(windowInfoListOption, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for windowInfo in windowInfoList {
            guard let ownerProcessIdentifier = windowInfo[kCGWindowOwnerPID as String] as? Int32 else { continue }
            guard ownerProcessIdentifier == frontmostProcessIdentifier else { continue }
            // Skip windows with no title — they're usually system
            // overlays or background helpers, not the user's main
            // document.
            guard let windowTitle = windowInfo[kCGWindowName as String] as? String,
                  !windowTitle.isEmpty else { continue }
            return windowTitle
        }
        return nil
    }

    /// Render one screen's element map into the planner-prompt block.
    /// Compact format: one element per line as `role|x,y|label|text`.
    /// Cap reduced to 15 (down from 25) because Apple Foundation
    /// Models' 4K context window busts on bigger element lists once
    /// the system prompt + agent rules + history are added. 30-char
    /// text cap (down from 60) keeps headings and button labels
    /// intact while shedding the bulk of verbose OCR runs.
    private static func formatScreenAnalysisForPrompt(
        screenLabel: String,
        analysis: LocalVLMScreenAnalysis
    ) -> String {
        let maxElementsRendered = 15
        let maxTextCharsPerElement = 30
        let elementSummaryLines = analysis.elements
            .prefix(maxElementsRendered)
            .enumerated()
            .map { elementIndex, element -> String in
                // Bbox CENTER, not top-left — Click landed half-element
                // off when we sent corners.
                let coordinateText = element.bbox.count == 4
                    ? "\(element.bbox[0] + element.bbox[2] / 2),\(element.bbox[1] + element.bbox[3] / 2)"
                    : "?,?"
                let textSuffix = element.text.flatMap { text -> String? in
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedText.isEmpty else { return nil }
                    let truncatedText = trimmedText.count > maxTextCharsPerElement
                        ? String(trimmedText.prefix(maxTextCharsPerElement)) + "…"
                        : trimmedText
                    return "|\(truncatedText)"
                } ?? ""
                // Numeric ID prefix lets the FM @Generable planner
                // emit element IDs instead of free-text coords. The
                // ID space is local to this turn; the planner client
                // re-parses these lines to map ID → (x, y) on output.
                return "[\(elementIndex)] \(element.role)|\(coordinateText)|\(element.label)\(textSuffix)"
            }
        let elementSummaryText = elementSummaryLines.joined(separator: "\n")
        let elementCountSummary = analysis.elements.count > maxElementsRendered
            ? "top \(maxElementsRendered) of \(analysis.elements.count)"
            : "\(analysis.elements.count)"
        let trimmedDescription = analysis.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionLine = trimmedDescription.isEmpty
            ? ""
            : "\nsummary: \(trimmedDescription)"

        // NSDataDetector pass over the visible-on-screen text. Adds a
        // small typed-entity block ahead of the element list so the
        // planner can reference "PHONE: …" / "URL: …" / "DATE: …"
        // directly instead of re-extracting them from raw OCR. The
        // detector runs deterministically with zero LLM cost; the
        // entities block stays compact (one line per entity, max ~10).
        let detectedEntities = Self.detectScreenEntities(
            fromElements: analysis.elements,
            description: analysis.description
        )
        let detectedEntitiesBlock: String = {
            guard let renderedBlock = PaceOCRDataDetector.renderEntitiesForPlannerPrompt(detectedEntities) else {
                return ""
            }
            return "\non-screen data:\n\(renderedBlock)\n"
        }()
        return """
        === \(screenLabel) (\(elementCountSummary) elements) ===\(descriptionLine)\(detectedEntitiesBlock)
        \(elementSummaryText)
        """
    }

    /// Concatenate the screen's visible text (element labels + text +
    /// description) and run `NSDataDetector` once over the merged
    /// string. Caps the entity list at 10 so a busy screen (e.g. a
    /// contacts directory) doesn't bloat the planner prompt. Returned
    /// entities are de-duplicated by `normalizedValue` so the same
    /// phone number appearing in three places counts once.
    nonisolated private static func detectScreenEntities(
        fromElements elements: [LocalVLMScreenElement],
        description: String
    ) -> [PaceDetectedEntity] {
        let textBlobsToScan = elements.compactMap { element -> String? in
            let candidate = (element.text ?? "") + " " + element.label
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let mergedScannableText = (textBlobsToScan + [description])
            .joined(separator: "\n")
        let allDetectedEntities = PaceOCRDataDetector.detectEntities(in: mergedScannableText)

        // Dedupe by normalizedValue. Preserve first-seen order so the
        // top-of-screen entity stays at the top of the rendered list
        // — a small but real signal for which one the user means.
        var seenNormalizedValues: Set<String> = []
        var dedupedEntities: [PaceDetectedEntity] = []
        for entity in allDetectedEntities {
            if !seenNormalizedValues.contains(entity.normalizedValue) {
                seenNormalizedValues.insert(entity.normalizedValue)
                dedupedEntities.append(entity)
            }
            if dedupedEntities.count >= 10 { break }
        }
        return dedupedEntities
    }

    /// SHA256 of the JPEG byte stream. Stable across runs, ~5ms for a
    /// 1 MB capture on Apple Silicon. Used as the cache key for the
    /// per-screen VLM analysis — if the pixels didn't change, the
    /// element map didn't either.
    nonisolated private static func computePixelHash(for jpegData: Data) -> String {
        let digest = SHA256.hash(data: jpegData)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
