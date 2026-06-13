//
//  PaceActionExecutor.swift
//  leanring-buddy
//
//  Executes mouse and keyboard actions on the user's behalf via
//  CGEvent. This is the layer that turns pace from a pointer into an
//  agent: it actually clicks, types, and presses keys.
//
//  All actions are gated by `EnableActions` in Info.plist. When the
//  flag is off, every method here becomes a no-op and we log instead.
//  When it's on, we still introduce small inter-action delays so the
//  target app has time to respond to focus / hover / key-down state
//  changes — without these, fast multi-step sequences race the UI.
//

import AppKit
import Contacts
import CoreGraphics
import EventKit
import Foundation

/// A single mouse position expressed in *screenshot pixel space*. The
/// executor converts to display-points and CG global coords internally
/// using the same screen-capture metadata the pointing layer uses, so
/// callers never need to think about coordinate spaces.
nonisolated struct ScreenshotPixelLocation {
    let xInScreenshotPixels: Int
    let yInScreenshotPixels: Int
    /// 1-based screen index from the screenshot label. nil = cursor screen.
    let screenNumber: Int?
}

nonisolated struct PaceClickCandidate {
    let location: ScreenshotPixelLocation?
    let label: String?
    let confidence: Double
    let expectStateChange: Bool
    let recency: PaceClickCandidateRecency?

    init(
        location: ScreenshotPixelLocation?,
        label: String?,
        confidence: Double,
        expectStateChange: Bool,
        recency: PaceClickCandidateRecency? = nil
    ) {
        self.location = location
        self.label = label
        self.confidence = confidence
        self.expectStateChange = expectStateChange
        self.recency = recency
    }

    var sortDescription: String {
        if let location {
            return location.approvalDescription
        }
        return label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var observationDescription: String {
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedLabel, location) {
        case (.some(let trimmedLabel), .some(let location)) where !trimmedLabel.isEmpty:
            return "\"\(trimmedLabel)\" at \(location.approvalDescription)"
        case (.some(let trimmedLabel), nil) where !trimmedLabel.isEmpty:
            return "\"\(trimmedLabel)\""
        case (nil, .some(let location)), (.some, .some(let location)):
            return location.approvalDescription
        case (nil, nil), (.some, nil):
            return "unlabelled candidate"
        }
    }
}

nonisolated struct PaceClickCandidateRecency {
    let rank: Int?
    let lastSeenMillisecondsAgo: Double?

    var scoreBoost: Double {
        let rankBoost: Double? = rank.map { rank in
            max(0, 0.12 - (Double(max(0, rank)) * 0.02))
        }
        let lastSeenBoost: Double? = lastSeenMillisecondsAgo.map { millisecondsAgo in
            let clampedMillisecondsAgo = max(0, min(millisecondsAgo, 5_000))
            return 0.12 * (1 - (clampedMillisecondsAgo / 5_000))
        }
        return max(rankBoost ?? 0, lastSeenBoost ?? 0)
    }
}

nonisolated struct PaceClickCandidateSet {
    let candidates: [PaceClickCandidate]
    let clickCount: Int

    var selectedFallbackLocation: ScreenshotPixelLocation? {
        candidates.compactMap(\.location).first
    }

    func bestCandidate(
        currentGlobalCursorPoint: CGPoint?,
        focusedWindowGlobalFrame: CGRect? = nil,
        screenCaptures: [CompanionScreenCapture],
        coordinateConverter: (ScreenshotPixelLocation, [CompanionScreenCapture]) -> CGPoint?
    ) -> PaceClickCandidate? {
        orderedCandidates(
            currentGlobalCursorPoint: currentGlobalCursorPoint,
            focusedWindowGlobalFrame: focusedWindowGlobalFrame,
            screenCaptures: screenCaptures,
            coordinateConverter: coordinateConverter
        ).first
    }

    func orderedCandidates(
        currentGlobalCursorPoint: CGPoint?,
        focusedWindowGlobalFrame: CGRect? = nil,
        screenCaptures: [CompanionScreenCapture],
        coordinateConverter: (ScreenshotPixelLocation, [CompanionScreenCapture]) -> CGPoint?
    ) -> [PaceClickCandidate] {
        guard !candidates.isEmpty else { return [] }

        let sortedCandidates = candidates.sorted {
            if $0.confidence == $1.confidence {
                return $0.sortDescription < $1.sortDescription
            }
            return $0.confidence > $1.confidence
        }

        if let firstCandidate = sortedCandidates.first, firstCandidate.confidence > 0.80 {
            return sortedCandidates
        }

        return sortedCandidates.sorted { firstCandidate, secondCandidate in
            let firstScore = score(
                    firstCandidate,
                    currentGlobalCursorPoint: currentGlobalCursorPoint,
                    focusedWindowGlobalFrame: focusedWindowGlobalFrame,
                    screenCaptures: screenCaptures,
                    coordinateConverter: coordinateConverter
                )
            let secondScore = score(
                    secondCandidate,
                    currentGlobalCursorPoint: currentGlobalCursorPoint,
                    focusedWindowGlobalFrame: focusedWindowGlobalFrame,
                    screenCaptures: screenCaptures,
                    coordinateConverter: coordinateConverter
                )
            if firstScore == secondScore {
                return firstCandidate.sortDescription < secondCandidate.sortDescription
            }
            return firstScore > secondScore
        }
    }

    private func score(
        _ candidate: PaceClickCandidate,
        currentGlobalCursorPoint: CGPoint?,
        focusedWindowGlobalFrame: CGRect?,
        screenCaptures: [CompanionScreenCapture],
        coordinateConverter: (ScreenshotPixelLocation, [CompanionScreenCapture]) -> CGPoint?
    ) -> Double {
        var score = candidate.confidence
        score += candidate.recency?.scoreBoost ?? 0

        if let currentGlobalCursorPoint,
           let location = candidate.location,
           let candidateGlobalPoint = coordinateConverter(location, screenCaptures) {
            let distanceFromCursor = hypot(
                candidateGlobalPoint.x - currentGlobalCursorPoint.x,
                candidateGlobalPoint.y - currentGlobalCursorPoint.y
            )
            // Linear falloff instead of a flat in-radius bonus: when several
            // candidates sit within the radius (common with repeated labels in
            // one window), the nearest one must actually win the tiebreak.
            let proximityRadius: CGFloat = 200
            if distanceFromCursor <= proximityRadius {
                score += 3.0 * Double((proximityRadius - distanceFromCursor) / proximityRadius)
            }
        }

        if let focusedWindowGlobalFrame,
           let location = candidate.location,
           let candidateGlobalPoint = coordinateConverter(location, screenCaptures),
           focusedWindowGlobalFrame.insetBy(dx: -24, dy: -24).contains(candidateGlobalPoint) {
            score += 0.18
        }

        if let label = candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            score += 0.01
        }

        return score
    }
}

/// Pure, runtime-free decision rule for the HUD visual-target ambiguity
/// prompt (PRD docs/prds/hud-intent-disambiguator.md). When the executor
/// produces several click candidates whose label-match confidences are
/// near-tied AND whose labels are distinguishable, Pace should ask one
/// short question ("did you mean Save or Save As?") through the existing
/// HUD clarification surface instead of guessing the top candidate.
///
/// The rule deliberately works off `confidence` alone — the raw
/// label-match score the VLM/parser already computed — NOT the executor's
/// cursor-proximity/focus runtime score. Cursor proximity is a tiebreak
/// for *which* near-tied candidate to auto-click; it is the wrong signal
/// for *whether the user's words were ambiguous*. Two labels with tied
/// match confidence are ambiguous regardless of where the cursor happens
/// to sit, so the question (not a silent guess) is the safe move.
enum PaceClickCandidateAmbiguity {
    /// Returns the 2-3 distinguishable candidates to offer the user when
    /// the top candidate's confidence lead over the runner-up is BELOW
    /// `confidenceDelta`. Returns `nil` (proceed to the existing
    /// auto-click) when there's a clear winner, when fewer than
    /// `minCandidatesToOffer` distinguishable labels exist, or when the
    /// near-tied candidates share identical labels (offering "Save" vs
    /// "Save" helps nobody).
    ///
    /// The common case — one obviously-best target — must stay
    /// zero-friction, so a clear winner NEVER produces a prompt.
    static func isAmbiguous(
        _ clickCandidateSet: PaceClickCandidateSet,
        confidenceDelta: Double = 0.12,
        minCandidatesToOffer: Int = 2,
        maxCandidatesToOffer: Int = 3
    ) -> [PaceClickCandidate]? {
        // Only labelled candidates can be offered as readable chips. A
        // coordinate-only candidate gives the user nothing to choose
        // between, so it can't participate in a disambiguation question.
        let labelledCandidates = clickCandidateSet.candidates
            .filter { candidate in
                guard let trimmedLabel = candidate.label?
                    .trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return !trimmedLabel.isEmpty
            }
            .sorted { $0.confidence > $1.confidence }

        guard labelledCandidates.count >= minCandidatesToOffer else {
            return nil
        }

        let topCandidate = labelledCandidates[0]
        let runnerUpCandidate = labelledCandidates[1]

        // Clear winner: the top candidate's confidence lead is at or above
        // the threshold. Trust it, never interrupt.
        let confidenceLead = topCandidate.confidence - runnerUpCandidate.confidence
        guard confidenceLead < confidenceDelta else {
            return nil
        }

        // Collect the near-tied front-runners: every candidate within
        // `confidenceDelta` of the top one, deduplicated by normalized
        // label so identical labels collapse to a single offer.
        var offeredCandidates: [PaceClickCandidate] = []
        var seenNormalizedLabels: Set<String> = []
        for candidate in labelledCandidates {
            guard topCandidate.confidence - candidate.confidence < confidenceDelta else {
                break
            }
            let normalizedLabel = candidate.label?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard seenNormalizedLabels.insert(normalizedLabel).inserted else {
                continue
            }
            offeredCandidates.append(candidate)
            if offeredCandidates.count == maxCandidatesToOffer {
                break
            }
        }

        // Identical labels (after dedup, only one distinguishable option
        // survives) help nobody — fall through to auto-click.
        guard offeredCandidates.count >= minCandidatesToOffer else {
            return nil
        }

        return offeredCandidates
    }
}

struct PaceClickStateSnapshot: Equatable {
    let frontmostBundleIdentifier: String?
    let visibleWindowCount: Int
    let focusedWindowTitle: String?
    let focusedElementFingerprint: String?
    let focusedAXTreeFingerprint: String?

    static func captureCurrent() -> PaceClickStateSnapshot {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let focusedWindowTitle: String?
        let focusedElementFingerprint: String?
        let focusedAXTreeFingerprint: String?

        if let frontmostApplication {
            let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
            let focusedWindowElement = focusedWindowElement(in: applicationElement)
            focusedWindowTitle = stringAttribute(
                kAXTitleAttribute as CFString,
                of: focusedWindowElement
            )
            focusedElementFingerprint = fingerprint(
                of: focusedElement(in: applicationElement)
            )
            focusedAXTreeFingerprint = treeFingerprint(
                of: focusedWindowElement ?? applicationElement
            )
        } else {
            focusedWindowTitle = nil
            focusedElementFingerprint = nil
            focusedAXTreeFingerprint = nil
        }

        return PaceClickStateSnapshot(
            frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier,
            visibleWindowCount: visibleWindowCount(),
            focusedWindowTitle: focusedWindowTitle,
            focusedElementFingerprint: focusedElementFingerprint,
            focusedAXTreeFingerprint: focusedAXTreeFingerprint
        )
    }

    static func focusedWindowGlobalFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        guard let focusedWindowElement = focusedWindowElement(in: applicationElement),
              let focusedWindowOrigin = pointAttribute(kAXPositionAttribute as CFString, of: focusedWindowElement),
              let focusedWindowSize = sizeAttribute(kAXSizeAttribute as CFString, of: focusedWindowElement) else {
            return nil
        }
        return CGRect(origin: focusedWindowOrigin, size: focusedWindowSize)
    }

    private static func focusedWindowElement(in applicationElement: AXUIElement) -> AXUIElement? {
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedWindowValue as! AXUIElement)
    }

    private static func focusedElement(in applicationElement: AXUIElement) -> AXUIElement? {
        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedElementValue as! AXUIElement)
    }

    private static func fingerprint(of element: AXUIElement?) -> String? {
        guard let element else { return nil }
        let fingerprintParts = [
            stringAttribute(kAXRoleAttribute as CFString, of: element),
            stringAttribute(kAXSubroleAttribute as CFString, of: element),
            stringAttribute(kAXTitleAttribute as CFString, of: element),
            stringAttribute(kAXDescriptionAttribute as CFString, of: element),
            stringAttribute(kAXValueAttribute as CFString, of: element)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        guard !fingerprintParts.isEmpty else { return nil }
        return fingerprintParts.joined(separator: "|")
    }

    private static func pointAttribute(_ attributeName: CFString, of element: AXUIElement?) -> CGPoint? {
        guard let element else { return nil }
        var attributeValue: CFTypeRef?
        let attributeResult = AXUIElementCopyAttributeValue(element, attributeName, &attributeValue)
        guard attributeResult == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }

        var pointValue = CGPoint.zero
        guard AXValueGetValue((attributeValue as! AXValue), .cgPoint, &pointValue) else {
            return nil
        }
        return pointValue
    }

    private static func sizeAttribute(_ attributeName: CFString, of element: AXUIElement?) -> CGSize? {
        guard let element else { return nil }
        var attributeValue: CFTypeRef?
        let attributeResult = AXUIElementCopyAttributeValue(element, attributeName, &attributeValue)
        guard attributeResult == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }

        var sizeValue = CGSize.zero
        guard AXValueGetValue((attributeValue as! AXValue), .cgSize, &sizeValue) else {
            return nil
        }
        return sizeValue
    }

    private static func treeFingerprint(of rootElement: AXUIElement?) -> String? {
        guard let rootElement else { return nil }

        var queue: [AXUIElement] = [rootElement]
        var nodeFingerprints: [String] = []
        var visitedNodeCount = 0
        let maximumNodeCount = 600

        while !queue.isEmpty, visitedNodeCount < maximumNodeCount {
            let element = queue.removeFirst()
            visitedNodeCount += 1

            if let elementFingerprint = fingerprint(of: element) {
                nodeFingerprints.append(elementFingerprint)
            }

            queue.append(contentsOf: children(of: element))
        }

        guard !nodeFingerprints.isEmpty else { return nil }
        return "\(visitedNodeCount):" + nodeFingerprints.joined(separator: "\n")
    }

    private static func stringAttribute(_ attributeName: CFString, of element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName, &value)
        guard result == .success, let value else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard result == .success,
              let childrenValue,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func visibleWindowCount() -> Int {
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]

        return windowInfo?
            .filter { window in
                (window[kCGWindowLayer as String] as? Int) == 0
            }
            .count ?? 0
    }
}

struct PaceMailComposeBodyCandidateMetadata: Equatable {
    let role: String?
    let title: String?
    let description: String?
    let help: String?
    let value: String?
    let placeholder: String?
    let frame: CGRect?

    var score: Double {
        guard let normalizedRole = role?.lowercased() else { return -100 }

        var score = 0.0
        switch normalizedRole {
        case "axtextarea":
            score += 80
        case "axwebarea":
            score += 65
        case "axtexteditor":
            score += 60
        case "axtextfield":
            score += 18
        default:
            return -100
        }

        let combinedLabels = [
            title,
            description,
            help,
            placeholder,
            value
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if Self.headerFieldKeywords.contains(where: { combinedLabels.contains($0) }) {
            score -= 90
        }

        if let frame {
            let area = max(0, frame.width) * max(0, frame.height)
            score += min(40, area / 4_000)
            if frame.height < 80 {
                score -= 25
            }
        }

        return score
    }

    private static let headerFieldKeywords = [
        "to:",
        "cc:",
        "bcc:",
        "from:",
        "reply-to",
        "subject",
        "search"
    ]
}

struct PaceAXLabelPressResolver {
    private static let pressableRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXMenuItem",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXTab",
        "AXDisclosureTriangle",
        "AXStepper"
    ]

    static func pressBestMatch(for candidate: PaceClickCandidate) -> Bool {
        guard let requestedLabel = candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedLabel.isEmpty,
              let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        let searchRoot = focusedWindowElement(in: applicationElement) ?? applicationElement
        let matches = collectPressableMatches(
            requestedLabel: requestedLabel,
            rootElement: searchRoot
        )

        guard let bestMatch = matches.sorted(by: { firstMatch, secondMatch in
            if firstMatch.score == secondMatch.score {
                return firstMatch.label < secondMatch.label
            }
            return firstMatch.score > secondMatch.score
        }).first else {
            print("⚠️ AX label targeting: no pressable match for \"\(requestedLabel)\"")
            return false
        }

        let pressResult = AXUIElementPerformAction(bestMatch.element, kAXPressAction as CFString)
        if pressResult == .success {
            print("🪟 AX label targeting: pressed \"\(bestMatch.label)\" for \"\(requestedLabel)\"")
            return true
        }

        print("⚠️ AX label targeting: press failed (\(pressResult.rawValue)) for \"\(requestedLabel)\"")
        return false
    }

    private struct Match {
        let element: AXUIElement
        let label: String
        let score: Int
    }

    private static func collectPressableMatches(
        requestedLabel: String,
        rootElement: AXUIElement
    ) -> [Match] {
        let normalizedRequestedLabel = normalizeLabel(requestedLabel)
        guard !normalizedRequestedLabel.isEmpty else { return [] }

        var matches: [Match] = []
        var queue: [AXUIElement] = [rootElement]
        var visitedNodeCount = 0
        let maximumNodeCount = 800

        while !queue.isEmpty, visitedNodeCount < maximumNodeCount {
            let element = queue.removeFirst()
            visitedNodeCount += 1

            if let role = stringAttribute(kAXRoleAttribute as CFString, of: element),
               pressableRoles.contains(role),
               let elementLabel = label(for: element) {
                let normalizedElementLabel = normalizeLabel(elementLabel)
                let score: Int?
                if normalizedElementLabel == normalizedRequestedLabel {
                    score = 10
                } else if normalizedElementLabel.contains(normalizedRequestedLabel) {
                    score = 6
                } else if normalizedRequestedLabel.contains(normalizedElementLabel) {
                    score = 4
                } else {
                    score = nil
                }

                if let score {
                    matches.append(Match(element: element, label: elementLabel, score: score))
                }
            }

            queue.append(contentsOf: children(of: element))
        }

        return matches
    }

    private static func focusedWindowElement(in applicationElement: AXUIElement) -> AXUIElement? {
        var focusedWindowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard result == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedWindowValue as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard result == .success,
              let childrenValue,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func label(for element: AXUIElement) -> String? {
        let candidateLabels = [
            stringAttribute(kAXTitleAttribute as CFString, of: element),
            stringAttribute(kAXDescriptionAttribute as CFString, of: element),
            stringAttribute(kAXValueAttribute as CFString, of: element),
            stringAttribute(kAXHelpAttribute as CFString, of: element)
        ]

        return candidateLabels
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func stringAttribute(_ attributeName: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName, &value)
        guard result == .success, let value else { return nil }
        return value as? String
    }

    static func normalizeLabel(_ label: String) -> String {
        label
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

@MainActor
final class PaceActionExecutor {
    /// Read from Info.plist at construction so a release build with the
    /// flag set false is guaranteed not to execute anything.
    let actionsAreEnabled: Bool

    /// Delay between consecutive actions when a single planner response
    /// chains several (e.g. click then type). Gives the focused app
    /// time to accept input. 75ms is the smallest reliable value across
    /// the common macOS apps tested during development.
    private let interActionDelay: TimeInterval = 0.075

    /// Hybrid targeter that tries the accessibility tree first before
    /// falling back to raw CGEvent clicks. Single-click only — double-
    /// click and drag still go through CGEvent because AX doesn't have
    /// a built-in "double-press" action.
    private let axTargeter = PaceAXTargeter()
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private let mcpClient: PaceMCPStdioClient
    private let timerScheduler: PaceTimerScheduler
    private var mutationLog: [PaceActionMutation] = []
    private var activeStreamingMailDraftState: PaceStreamingMailDraftState?

    /// Callback wired by `CompanionManager` so the planner's
    /// `record_flow` tool can kick off the live recorder + persist on
    /// stop. The closure returns a short user-facing summary the
    /// executor folds into its observation. Default no-op preserves
    /// dry-run / unit-test behavior.
    var startFlowRecordingCallback: (String) -> String = { flowName in
        "Ready to record flow \"\(flowName)\". Recorder hook isn't wired."
    }

    /// Callback wired by `CompanionManager` so the planner's
    /// `run_flow` tool can drive the live replayer. Returns true when
    /// the caller already kicked the replay off (so the executor's
    /// observation can say "replaying now"); false signals the
    /// approval flow short-circuited and the executor should report a
    /// neutral status instead.
    var runFlowCallback: (PaceRecordedFlow) -> Bool = { _ in false }

    init(
        actionsAreEnabledOverride: Bool? = nil,
        mcpClient: PaceMCPStdioClient = PaceMCPStdioClient(),
        timerScheduler: PaceTimerScheduler? = nil
    ) {
        self.mcpClient = mcpClient
        // Default-construct on the MainActor init body — the
        // @MainActor-isolated initializer can't be the default arg of
        // another @MainActor init in Swift 6 concurrency checking.
        self.timerScheduler = timerScheduler ?? PaceTimerScheduler()
        if let actionsAreEnabledOverride {
            self.actionsAreEnabled = actionsAreEnabledOverride
        } else {
            let rawFlag = AppBundleConfiguration.stringValue(forKey: "EnableActions")?.lowercased()
            self.actionsAreEnabled = (rawFlag == "true" || rawFlag == "1" || rawFlag == "yes")
        }
        if actionsAreEnabled {
            print("🤖 PaceActionExecutor: actions ENABLED — real clicks and keystrokes will be sent")
        } else {
            print("🤖 PaceActionExecutor: actions DISABLED (Info.plist EnableActions != true) — dry-run only")
        }
    }

    // MARK: - High-level entry point

    /// Executes a serial sequence of actions parsed from legacy inline tags.
    /// Kept as a compatibility wrapper around the richer tool-plan shape.
    @discardableResult
    func executeActionSequence(
        _ actions: [PaceParsedAction],
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        await executeActionPlan(
            PaceActionExecutionPlan.serial(actions: actions),
            screenCaptures: screenCaptures
        )
    }

    /// Executes a tool plan: outer steps are sequential; actions within one
    /// step are a parallel group at the planner contract level. UI-mutating
    /// actions still run in source order because macOS focus/cursor state is
    /// global and not safe to mutate concurrently.
    @discardableResult
    func executeActionPlan(
        _ actionExecutionPlan: PaceActionExecutionPlan,
        screenCaptures: [CompanionScreenCapture]
    ) async -> [PaceActionExecutionObservation] {
        guard !actionExecutionPlan.steps.isEmpty else { return [] }

        var observations: [PaceActionExecutionObservation] = []

        for (stepIndex, step) in actionExecutionPlan.steps.enumerated() {
            guard !step.actions.isEmpty else { continue }

            for (actionIndex, action) in step.actions.enumerated() {
                if let observation = await executeSingleAction(action, screenCaptures: screenCaptures) {
                    observations.append(observation)
                }

                let isLastActionInStep = (actionIndex == step.actions.count - 1)
                if !isLastActionInStep {
                    try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
                }
            }

            let isLastStep = (stepIndex == actionExecutionPlan.steps.count - 1)
            if !isLastStep {
                try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
            }
        }

        return observations
    }

    var hasActiveStreamingMailDraft: Bool {
        activeStreamingMailDraftState != nil
    }

    @discardableResult
    func beginOrUpdateStreamingMailDraft(
        _ snapshot: PaceStreamingMailDraftSnapshot
    ) async -> PaceActionExecutionObservation? {
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Would stream mail draft body: \(snapshot.normalizedMailDraft.subject)"
            )
        }

        let now = Date()
        if let activeStreamingMailDraftState,
           now.timeIntervalSince(activeStreamingMailDraftState.lastWriteDate) < 0.033 {
            self.activeStreamingMailDraftState = activeStreamingMailDraftState
                .withPendingSnapshot(snapshot)
            return nil
        }

        return await writeStreamingMailDraft(snapshot, isFinalWrite: false)
    }

    @discardableResult
    func finishActiveStreamingMailDraft(
        finalMailDraft: PaceMailDraft
    ) async -> PaceActionExecutionObservation? {
        guard activeStreamingMailDraftState != nil else {
            return nil
        }

        let finalSnapshot = PaceStreamingMailDraftSnapshot(
            recipients: finalMailDraft.recipients,
            subject: finalMailDraft.subject,
            body: finalMailDraft.body
        )
        let observation = await writeStreamingMailDraft(finalSnapshot, isFinalWrite: true)
        activeStreamingMailDraftState = nil

        return observation ?? PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created streaming mail draft: \(finalMailDraft.subject)"
        )
    }

    func cancelActiveStreamingMailDraftTracking() {
        activeStreamingMailDraftState = nil
    }

    private func executeSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        let observation = await dispatchSingleAction(action, screenCaptures: screenCaptures)
        let outcomeText: String
        if let observation, observation.summary.lowercased().contains("fail")
            || observation.summary.lowercased().contains("error")
            || observation.summary.lowercased().contains("could not") {
            outcomeText = "error"
        } else {
            outcomeText = "ok"
        }
        PaceAPIAuditLog.shared.record(
            subsystem: "action",
            operation: action.auditOperationName,
            target: action.auditTarget,
            durationMilliseconds: 0,
            outcome: outcomeText,
            outputCharacterCount: observation?.summary.count,
            detail: observation?.summary.prefix(160).description
        )
        return observation
    }

    private func dispatchSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        switch action {
        case .click(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 1)
        case .doubleClick(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 2)
        case .clickCandidates(let clickCandidateSet):
            return await clickBestCandidate(clickCandidateSet, screenCaptures: screenCaptures)
        case .type(let textToType):
            await typeText(textToType)
        case .setTextValue(let setTextValueRequest):
            return setTextValue(setTextValueRequest)
        case .editSelectedText(let voiceEditRequest):
            return editSelectedText(voiceEditRequest)
        case .undoLastMutation:
            return undoLastMutation()
        case .pressKey(let keyName, let modifiers):
            await pressKey(named: keyName, withModifiers: modifiers)
        case .readClipboard:
            return readClipboardText()
        case .snapWindow(let snapWindowRequest):
            return snapFocusedWindow(snapWindowRequest)
        case .scroll(let direction, let amount):
            await scroll(direction: direction, amountInLines: amount)
        case .openApplication(let applicationName):
            return await openApplication(named: applicationName)
        case .openURL(let urlString):
            return await openURL(urlString)
        case .controlMusic(let musicCommand):
            return await controlMusic(musicCommand)
        case .adjustVolume(let adjustment):
            await adjustVolume(adjustment)
        case .adjustBrightness(let adjustment):
            await adjustBrightness(adjustment)
        case .listCalendarEvents(let calendarQuery):
            return await listCalendarEvents(calendarQuery)
        case .createCalendarEvent(let calendarEventRequest):
            return await createCalendarEvent(calendarEventRequest)
        case .createReminder(let reminderRequest):
            return await createReminder(reminderRequest)
        case .finder(let finderRequest):
            return await performFinderRequest(finderRequest)
        case .createNote(let noteRequest):
            return await createNote(noteRequest)
        case .appendNote(let noteRequest):
            return await appendNote(noteRequest)
        case .searchNotes(let query):
            return await searchNotes(query: query)
        case .composeMail(let mailDraft):
            return await composeMail(mailDraft)
        case .createThingsToDo(let thingsToDoRequest):
            return await createThingsToDo(thingsToDoRequest)
        case .runShortcut(let shortcutName):
            return await runShortcut(named: shortcutName)
        case .openMessages(let messageRequest):
            return await openMessages(messageRequest)
        case .downloadFile(let downloadRequest):
            return await downloadFile(downloadRequest)
        case .startTimer(let timerRequest):
            return await startTimer(timerRequest)
        case .recordFlow(let flowRequest):
            return recordFlow(flowRequest)
        case .runFlow(let flowRequest):
            return runFlow(flowRequest)
        case .mcp(let mcpToolCall):
            return await callMCPTool(mcpToolCall)
        }

        return nil
    }

    // MARK: - Mouse

    private func clickBestCandidate(
        _ clickCandidateSet: PaceClickCandidateSet,
        screenCaptures: [CompanionScreenCapture]
    ) async -> PaceActionExecutionObservation? {
        let currentGlobalCursorPoint = CGEvent(source: nil)?.location
        let focusedWindowGlobalFrame = PaceClickStateSnapshot.focusedWindowGlobalFrame()
        let orderedCandidates = clickCandidateSet.orderedCandidates(
            currentGlobalCursorPoint: currentGlobalCursorPoint,
            focusedWindowGlobalFrame: focusedWindowGlobalFrame,
            screenCaptures: screenCaptures,
            coordinateConverter: { [weak self] location, captures in
                self?.convertScreenshotPixelToDisplayGlobalPoint(
                    screenshotPixelLocation: location,
                    screenCaptures: captures
                )
            }
        )

        guard !orderedCandidates.isEmpty else {
            print("⚠️ PaceActionExecutor: no click candidates available — skipping")
            return PaceActionExecutionObservation(
                toolName: "click_candidates",
                summary: "Click failed: no click candidates were available."
            )
        }

        let maximumAttempts = min(3, orderedCandidates.count)
        let attemptedCandidates = Array(orderedCandidates.prefix(maximumAttempts))
        for (candidateIndex, candidate) in attemptedCandidates.enumerated() {
            let beforeClickState = actionsAreEnabled && candidate.expectStateChange
                ? PaceClickStateSnapshot.captureCurrent()
                : nil

            let didAttemptClick = await clickCandidate(
                candidate,
                screenCaptures: screenCaptures,
                clickCount: clickCandidateSet.clickCount
            )
            guard didAttemptClick else { continue }

            guard actionsAreEnabled, candidate.expectStateChange else {
                return nil
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            let afterClickState = PaceClickStateSnapshot.captureCurrent()
            if beforeClickState != afterClickState {
                return nil
            }

            let hasAnotherCandidate = candidateIndex < maximumAttempts - 1
            if hasAnotherCandidate {
                print("⚠️ PaceActionExecutor: click candidate produced no observable state change — retrying next candidate")
            } else {
                print("⚠️ PaceActionExecutor: click candidates produced no observable state change")
            }
        }

        let attemptedCandidateSummary = attemptedCandidates
            .map(\.observationDescription)
            .joined(separator: "; ")
        let skippedCandidateCount = max(0, orderedCandidates.count - attemptedCandidates.count)
        let skippedCandidateText = skippedCandidateCount > 0
            ? " \(skippedCandidateCount) lower-ranked candidate\(skippedCandidateCount == 1 ? " was" : "s were") not tried."
            : ""
        return PaceActionExecutionObservation(
            toolName: "click_candidates",
            summary: "Click failed after trying \(attemptedCandidates.count) of \(orderedCandidates.count) candidate\(orderedCandidates.count == 1 ? "" : "s"): \(attemptedCandidateSummary).\(skippedCandidateText)"
        )
    }

    private func clickCandidate(
        _ candidate: PaceClickCandidate,
        screenCaptures: [CompanionScreenCapture],
        clickCount: Int
    ) async -> Bool {
        if let location = candidate.location {
            return await clickAtScreenshotLocation(
                location,
                screenCaptures: screenCaptures,
                clickCount: clickCount
            )
        }

        guard let label = candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            print("⚠️ PaceActionExecutor: click candidate has no coordinate or label — skipping")
            return false
        }

        print("🪟 AX label click \"\(label)\" (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else { return true }
        guard clickCount == 1 else {
            print("⚠️ PaceActionExecutor: label-only double-click candidates are not supported — skipping")
            return false
        }

        return PaceAXLabelPressResolver.pressBestMatch(for: candidate)
    }

    @discardableResult
    private func clickAtScreenshotLocation(
        _ screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture],
        clickCount: Int
    ) async -> Bool {
        guard let displayGlobalPoint = convertScreenshotPixelToDisplayGlobalPoint(
            screenshotPixelLocation: screenshotPixelLocation,
            screenCaptures: screenCaptures
        ) else {
            print("⚠️ PaceActionExecutor: could not resolve display coordinates for click — skipping")
            return false
        }

        print("🖱️  Click x\(clickCount) at \(Int(displayGlobalPoint.x)),\(Int(displayGlobalPoint.y)) (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else { return true }

        // Try the AX path first for single clicks. If AX finds a
        // pressable element and the press succeeds, we skip the CGEvent
        // path entirely — it's more robust against layout shifts and
        // synthesises a semantically correct activation event.
        // Double-clicks still go through CGEvent because AX has no
        // "double-press" primitive.
        if clickCount == 1, axTargeter.tryClickViaAccessibility(atGlobalCGPoint: displayGlobalPoint) {
            return true
        }

        // Move the system cursor first so the visual position matches the
        // synthetic click and so any hover state (tooltips, menu reveals)
        // settles before the click lands.
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: displayGlobalPoint,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms hover settle

        for clickIndex in 0..<clickCount {
            let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            downEvent?.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms hold

            let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            upEvent?.post(tap: .cghidEventTap)

            if clickIndex < clickCount - 1 {
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms between clicks of a double-click
            }
        }

        return true
    }

    private func readClipboardText() -> PaceActionExecutionObservation {
        print("🧰 Clipboard read (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "clipboard_read",
                summary: "Would read clipboard text."
            )
        }

        guard let clipboardText = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "clipboard_read",
                summary: "Clipboard has no text."
            )
        }

        let maximumClipboardPreviewCharacters = 1_200
        let clippedText: String = {
            guard clipboardText.count > maximumClipboardPreviewCharacters else {
                return clipboardText
            }
            return "\(clipboardText.prefix(maximumClipboardPreviewCharacters))..."
        }()

        return PaceActionExecutionObservation(
            toolName: "clipboard_read",
            summary: "Clipboard text: \(clippedText)"
        )
    }

    private func snapFocusedWindow(_ request: PaceWindowSnapRequest) -> PaceActionExecutionObservation {
        print("🪟 Window snap \(request.position.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "Would snap focused window: \(request.position.displayName)"
            )
        }

        guard let focusedWindow = focusedWindowElement() else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "No focused window was found."
            )
        }

        guard let currentWindowFrame = axFrame(of: focusedWindow),
              let screenVisibleFrame = axVisibleFrameForScreen(containing: currentWindowFrame) else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "Could not resolve focused window frame."
            )
        }

        let targetFrame = request.position.targetFrame(in: screenVisibleFrame)
        guard setAXWindowFrame(focusedWindow, targetFrame: targetFrame) else {
            return PaceActionExecutionObservation(
                toolName: "window_snap",
                summary: "Focused window could not be moved or resized via Accessibility."
            )
        }

        return PaceActionExecutionObservation(
            toolName: "window_snap",
            summary: "Snapped focused window: \(request.position.displayName)"
        )
    }

    private func focusedWindowElement() -> AXUIElement? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedWindowValue as! AXUIElement)
    }

    private func axFrame(of windowElement: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        guard positionResult == .success,
              let positionValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else {
            return nil
        }

        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeValue
        )
        guard sizeResult == .success,
              let sizeValue,
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func axVisibleFrameForScreen(containing axWindowFrame: CGRect) -> CGRect? {
        let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        let primaryHeight = primaryScreen?.frame.height ?? 0
        let windowCenter = CGPoint(x: axWindowFrame.midX, y: axWindowFrame.midY)

        for screen in NSScreen.screens {
            let axScreenFrame = Self.convertCocoaScreenFrameToAXFrame(
                screen.visibleFrame,
                primaryScreenHeight: primaryHeight
            )
            if axScreenFrame.contains(windowCenter) {
                return axScreenFrame
            }
        }

        return NSScreen.main.map {
            Self.convertCocoaScreenFrameToAXFrame(
                $0.visibleFrame,
                primaryScreenHeight: primaryHeight
            )
        }
    }

    private static func convertCocoaScreenFrameToAXFrame(
        _ cocoaFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: cocoaFrame.origin.x,
            y: primaryScreenHeight - cocoaFrame.origin.y - cocoaFrame.height,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    private func setAXWindowFrame(_ windowElement: AXUIElement, targetFrame: CGRect) -> Bool {
        var targetOrigin = targetFrame.origin
        var targetSize = targetFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &targetOrigin),
              let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeResult = AXUIElementSetAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            sizeValue
        )

        return positionResult == .success && sizeResult == .success
    }

    private func scroll(direction: PaceScrollDirection, amountInLines: Int) async {
        print("🖱️  Scroll \(direction) by \(amountInLines) lines (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        let verticalDelta: Int32 = {
            switch direction {
            case .up: return Int32(amountInLines)
            case .down: return -Int32(amountInLines)
            }
        }()

        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: verticalDelta,
            wheel2: 0,
            wheel3: 0
        ) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System tools

    @discardableResult
    private func openApplication(named applicationName: String) async -> PaceActionExecutionObservation {
        let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApplicationName.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "No application name was provided."
            )
        }

        print("🧰 Open app \"\(trimmedApplicationName)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "Would open app: \(trimmedApplicationName)"
            )
        }

        guard let applicationURL = Self.findApplicationURL(named: trimmedApplicationName) else {
            print("⚠️ PaceActionExecutor: could not find app named \(trimmedApplicationName)")
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "Could not find app: \(trimmedApplicationName)"
            )
        }

        let openErrorDescription: String? = await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error {
                    print("⚠️ PaceActionExecutor: failed to open \(trimmedApplicationName): \(error.localizedDescription)")
                }
                continuation.resume(returning: error?.localizedDescription)
            }
        }

        if let openErrorDescription {
            return PaceActionExecutionObservation(
                toolName: "open_app",
                summary: "Failed to open app \(trimmedApplicationName): \(openErrorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "open_app",
            summary: "Opened app: \(trimmedApplicationName)"
        )
    }

    /// Public hook so CompanionManager can hand the scheduler a speak
    /// closure after it has finished wiring its TTS client. Without this
    /// the scheduler fires silently — it has no idea how to talk on its
    /// own.
    func setTimerOnFireSpeakCallback(_ speakCallback: @escaping (String) -> Void) {
        timerScheduler.onFire = speakCallback
    }

    /// Reload any persisted timers from disk so a quit+restart doesn't
    /// silently swallow an in-flight nudge.
    func rehydratePersistedTimers() {
        timerScheduler.rehydrate()
    }

    private func startTimer(_ timerRequest: PaceTimerRequest) async -> PaceActionExecutionObservation {
        let durationInSeconds = max(0.001, timerRequest.durationInSeconds)
        let trimmedLabel = timerRequest.label.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧰 Start timer label=\"\(trimmedLabel)\" duration=\(durationInSeconds)s")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "start_timer",
                summary: "Would start timer for \(Int(durationInSeconds))s\(trimmedLabel.isEmpty ? "" : ": \(trimmedLabel)")."
            )
        }
        let scheduledTimer = timerScheduler.schedule(
            label: trimmedLabel,
            durationInSeconds: durationInSeconds
        )
        let minutesRemaining = Int((durationInSeconds / 60.0).rounded())
        let humanDurationText: String
        if minutesRemaining >= 1 {
            humanDurationText = "\(minutesRemaining) minute\(minutesRemaining == 1 ? "" : "s")"
        } else {
            humanDurationText = "\(Int(durationInSeconds)) seconds"
        }
        let labelSuffix = trimmedLabel.isEmpty ? "" : " for \(trimmedLabel)"
        return PaceActionExecutionObservation(
            toolName: "start_timer",
            summary: "Timer set\(labelSuffix) for \(humanDurationText) — fires at \(scheduledTimer.fireDate.formatted(date: .omitted, time: .shortened))."
        )
    }

    private func recordFlow(_ flowRequest: PaceFlowActionRequest) -> PaceActionExecutionObservation {
        let flowName = flowRequest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flowName.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "record_flow",
                summary: "Flow recording needs a name."
            )
        }
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "record_flow",
                summary: "Would record flow \"\(flowName)\"."
            )
        }
        // CompanionManager owns the live recorder + the eventual save
        // into PaceFlowStore on stop. The callback returns the
        // spoken-ready summary so the executor observation reads
        // exactly like the panel TTS would say it.
        let recorderSummary = startFlowRecordingCallback(flowName)
        return PaceActionExecutionObservation(
            toolName: "record_flow",
            summary: recorderSummary
        )
    }

    private func runFlow(_ flowRequest: PaceFlowActionRequest) -> PaceActionExecutionObservation {
        let flowName = flowRequest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flowName.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "Flow replay needs a name."
            )
        }
        let storedFlow = PaceFlowStore().load(named: flowName)
        guard let storedFlow else {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "No recorded flow named \"\(flowName)\" was found."
            )
        }
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "Would replay flow \"\(storedFlow.name)\" (\(storedFlow.steps.count) step\(storedFlow.steps.count == 1 ? "" : "s"))."
            )
        }
        // CompanionManager applies the per-session approval cache,
        // drives the replayer, and speaks completion/failure copy. The
        // executor just kicks off the call and reports a neutral
        // observation back to the planner loop.
        let didStartReplay = runFlowCallback(storedFlow)
        if didStartReplay {
            return PaceActionExecutionObservation(
                toolName: "run_flow",
                summary: "Replaying flow \"\(storedFlow.name)\" (\(storedFlow.steps.count) step\(storedFlow.steps.count == 1 ? "" : "s"))."
            )
        }
        return PaceActionExecutionObservation(
            toolName: "run_flow",
            summary: "Flow \"\(storedFlow.name)\" is ready — pending approval."
        )
    }

    private func downloadFile(_ downloadRequest: PaceFileDownloadRequest) async -> PaceActionExecutionObservation {
        let downloadURL = downloadRequest.url
        print("🧰 Download file \"\(downloadURL.absoluteString)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Would download file: \(downloadURL.absoluteString)"
            )
        }

        guard let downloadsDirectoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Could not locate the Downloads folder."
            )
        }

        do {
            let (temporaryFileURL, response) = try await URLSession.shared.download(from: downloadURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                try? FileManager.default.removeItem(at: temporaryFileURL)
                return PaceActionExecutionObservation(
                    toolName: "download_file",
                    summary: "Download failed with HTTP \(httpResponse.statusCode): \(downloadURL.absoluteString)"
                )
            }

            let sanitizedFilename = PaceDownloadFilenameSanitizer.sanitizedFilename(
                suggestedFilename: downloadRequest.suggestedFilename ?? response.suggestedFilename,
                downloadURL: downloadURL
            )
            let existingFilenames = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectoryURL.path)) ?? []
            )
            let finalFilename = PaceDownloadFilenameSanitizer.collisionFreeFilename(
                sanitizedFilename,
                existingFilenames: existingFilenames
            )
            let destinationURL = downloadsDirectoryURL.appendingPathComponent(finalFilename)
            try FileManager.default.moveItem(at: temporaryFileURL, to: destinationURL)

            let downloadedByteCount = (try? FileManager.default.attributesOfItem(
                atPath: destinationURL.path
            )[.size] as? Int) ?? 0
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Downloaded \(finalFilename) (\(downloadedByteCount) bytes) to ~/Downloads."
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "download_file",
                summary: "Download failed: \(error.localizedDescription)"
            )
        }
    }

    private func openURL(_ rawURLString: String) async -> PaceActionExecutionObservation {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return PaceActionExecutionObservation(toolName: "open_url", summary: "No URL was provided.")
        }

        let normalizedURLString: String = {
            if trimmedURLString.contains("://") {
                return trimmedURLString
            }
            return "https://\(trimmedURLString)"
        }()

        guard let url = URL(string: normalizedURLString) else {
            return PaceActionExecutionObservation(
                toolName: "open_url",
                summary: "Could not parse URL: \(trimmedURLString)"
            )
        }

        print("🧰 Open URL \"\(url.absoluteString)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "open_url",
                summary: "Would open URL: \(url.absoluteString)"
            )
        }

        if let preferredBrowser = PaceLocalMemoryStore.string(for: .preferredBrowser),
           let browserURL = Self.findApplicationURL(named: preferredBrowser) {
            let openErrorDescription: String? = await withCheckedContinuation { continuation in
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: browserURL,
                    configuration: configuration
                ) { _, error in
                    continuation.resume(returning: error?.localizedDescription)
                }
            }

            if let openErrorDescription {
                return PaceActionExecutionObservation(
                    toolName: "open_url",
                    summary: "Failed to open URL in \(preferredBrowser): \(openErrorDescription)"
                )
            }

            return PaceActionExecutionObservation(
                toolName: "open_url",
                summary: "Opened URL in \(preferredBrowser): \(url.absoluteString)"
            )
        }

        let didOpen = NSWorkspace.shared.open(url)
        return PaceActionExecutionObservation(
            toolName: "open_url",
            summary: didOpen ? "Opened URL: \(url.absoluteString)" : "Failed to open URL: \(url.absoluteString)"
        )
    }

    private func controlMusic(_ musicCommand: PaceMusicCommand) async -> PaceActionExecutionObservation {
        print("🧰 Music \(musicCommand.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "music",
                summary: "Would run Music command: \(musicCommand.rawValue)"
            )
        }

        switch musicCommand {
        case .play, .pause:
            await openApplication(named: "Music")
            try? await Task.sleep(nanoseconds: 200_000_000)
            let scriptVerb = (musicCommand == .play) ? "play" : "pause"
            let scriptResult = runAppleScript(source: """
            tell application "Music"
                \(scriptVerb)
            end tell
            """)
            if let errorDescription = scriptResult.errorDescription {
                return PaceActionExecutionObservation(
                    toolName: "music",
                    summary: "Music \(musicCommand.rawValue) failed: \(errorDescription)"
                )
            }
            return PaceActionExecutionObservation(
                toolName: "music",
                summary: "Music command completed: \(musicCommand.rawValue)"
            )
        case .playPause:
            postAuxiliaryKeyEvent(keyType: Self.mediaPlayPauseKeyType)
        case .next:
            postAuxiliaryKeyEvent(keyType: Self.mediaNextKeyType)
        case .previous:
            postAuxiliaryKeyEvent(keyType: Self.mediaPreviousKeyType)
        }

        return PaceActionExecutionObservation(
            toolName: "music",
            summary: "Music command completed: \(musicCommand.rawValue)"
        )
    }

    private func adjustVolume(_ adjustment: PaceSystemAdjustment) async {
        print("🧰 Volume \(adjustment) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        for _ in 0..<adjustment.stepCount {
            switch adjustment.direction {
            case .up:
                postAuxiliaryKeyEvent(keyType: Self.soundUpKeyType)
            case .down:
                postAuxiliaryKeyEvent(keyType: Self.soundDownKeyType)
            }
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
    }

    private func adjustBrightness(_ adjustment: PaceSystemAdjustment) async {
        print("🧰 Brightness \(adjustment) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        for _ in 0..<adjustment.stepCount {
            switch adjustment.direction {
            case .up:
                postAuxiliaryKeyEvent(keyType: Self.brightnessUpKeyType)
            case .down:
                postAuxiliaryKeyEvent(keyType: Self.brightnessDownKeyType)
            }
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
    }

    private func listCalendarEvents(_ calendarQuery: PaceCalendarQuery) async -> PaceActionExecutionObservation {
        print("🧰 Calendar list \(calendarQuery.range.rawValue) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "Would list calendar events for \(calendarQuery.range.displayName)."
            )
        }

        guard await requestCalendarAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "Calendar access not granted. Open System Settings → Privacy & Security → Calendars and toggle Pace on."
            )
        }

        let now = Date()
        let dateInterval = calendarQuery.dateInterval(relativeTo: now)
        let predicate = eventStore.predicateForEvents(
            withStart: dateInterval.start,
            end: dateInterval.end,
            calendars: nil
        )
        let matchingEvents = eventStore.events(matching: predicate)
            .filter { $0.endDate >= now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)

        guard !matchingEvents.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "calendar",
                summary: "No calendar events found for \(calendarQuery.range.displayName)."
            )
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let eventSummaries = matchingEvents.map { event in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = title?.isEmpty == false ? title! : "Untitled event"
            let locationSuffix: String = {
                guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !location.isEmpty else {
                    return ""
                }
                return " at \(location)"
            }()
            return "\(formatter.string(from: event.startDate)): \(safeTitle)\(locationSuffix)"
        }

        return PaceActionExecutionObservation(
            toolName: "calendar",
            summary: "Calendar events for \(calendarQuery.range.displayName):\n" + eventSummaries.joined(separator: "\n")
        )
    }

    private func createCalendarEvent(
        _ calendarEventRequest: PaceCalendarEventRequest
    ) async -> PaceActionExecutionObservation {
        print("🧰 Calendar create \"\(calendarEventRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Would create calendar event: \(calendarEventRequest.displaySummary)"
            )
        }

        guard await requestCalendarAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Calendar access not granted. Open System Settings → Privacy & Security → Calendars and toggle Pace on."
            )
        }

        guard let targetCalendar = calendarForNewEvent(matching: calendarEventRequest.calendarTitle) else {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Could not find a writable calendar."
            )
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = targetCalendar
        event.title = calendarEventRequest.title
        event.startDate = calendarEventRequest.startDate
        event.endDate = calendarEventRequest.endDate
        event.isAllDay = calendarEventRequest.isAllDay
        event.notes = calendarEventRequest.notes
        event.location = calendarEventRequest.location

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Created calendar event: \(calendarEventRequest.displaySummary)"
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "calendar_create",
                summary: "Failed to create calendar event: \(error.localizedDescription)"
            )
        }
    }

    private func calendarForNewEvent(matching requestedCalendarTitle: String?) -> EKCalendar? {
        guard let requestedCalendarTitle = requestedCalendarTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedCalendarTitle.isEmpty else {
            return eventStore.defaultCalendarForNewEvents
        }

        let matchingCalendar = eventStore
            .calendars(for: .event)
            .first { calendar in
                calendar.allowsContentModifications
                    && calendar.title.compare(
                        requestedCalendarTitle,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
            }

        return matchingCalendar ?? eventStore.defaultCalendarForNewEvents
    }

    private func createReminder(_ reminderRequest: PaceReminderRequest) async -> PaceActionExecutionObservation {
        print("🧰 Create reminder \"\(reminderRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Would create reminder: \(reminderRequest.title)"
            )
        }

        guard await requestReminderAccessIfNeeded() else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Reminders access not granted. Open System Settings → Privacy & Security → Reminders and toggle Pace on."
            )
        }

        guard let reminderCalendar = eventStore.defaultCalendarForNewReminders() else {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Could not find a default reminders list."
            )
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = reminderCalendar
        reminder.title = reminderRequest.title
        reminder.notes = reminderRequest.notes

        do {
            try eventStore.save(reminder, commit: true)
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Created reminder: \(reminderRequest.title)"
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: "reminder",
                summary: "Failed to create reminder: \(error.localizedDescription)"
            )
        }
    }

    private func performFinderRequest(_ finderRequest: PaceFinderRequest) async -> PaceActionExecutionObservation {
        let expandedPath = NSString(string: finderRequest.path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)
        print("🧰 Finder \(finderRequest.action.rawValue) \"\(expandedPath)\" (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: "Would \(finderRequest.action.rawValue) path: \(expandedPath)"
            )
        }

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: "Path does not exist: \(expandedPath)"
            )
        }

        switch finderRequest.action {
        case .open:
            let didOpen = NSWorkspace.shared.open(fileURL)
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: didOpen ? "Opened path: \(expandedPath)" : "Failed to open path: \(expandedPath)"
            )
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return PaceActionExecutionObservation(
                toolName: "finder",
                summary: "Revealed path in Finder: \(expandedPath)"
            )
        }
    }

    private func createNote(_ noteRequest: PaceNoteRequest) async -> PaceActionExecutionObservation {
        print("🧰 Notes create \"\(noteRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Would create note: \(noteRequest.title)"
            )
        }

        await openApplication(named: "Notes")
        let scriptResult = runAppleScript(source: """
        tell application "Notes"
            activate
            make new note at default account with properties {name:"\(Self.appleScriptEscaped(noteRequest.title))", body:"\(Self.appleScriptEscaped(noteRequest.body))"}
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Failed to create note: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "notes",
            summary: "Created note: \(noteRequest.title)"
        )
    }

    private func appendNote(_ noteRequest: PaceNoteRequest) async -> PaceActionExecutionObservation {
        print("🧰 Notes append \"\(noteRequest.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Would append to note: \(noteRequest.title)"
            )
        }

        await openApplication(named: "Notes")
        let scriptResult = runAppleScript(source: """
        tell application "Notes"
            activate
            set matchingNotes to notes whose name is "\(Self.appleScriptEscaped(noteRequest.title))"
            if (count of matchingNotes) is 0 then
                make new note at default account with properties {name:"\(Self.appleScriptEscaped(noteRequest.title))", body:"\(Self.appleScriptEscaped(noteRequest.body))"}
            else
                set targetNote to item 1 of matchingNotes
                set body of targetNote to (body of targetNote) & "<br><br>" & "\(Self.appleScriptEscaped(noteRequest.body))"
            end if
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Failed to append note: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "notes",
            summary: "Appended note: \(noteRequest.title)"
        )
    }

    private func searchNotes(query: String) async -> PaceActionExecutionObservation {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧰 Notes search \"\(trimmedQuery)\" (enabled: \(actionsAreEnabled))")
        guard !trimmedQuery.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "No note search query was provided."
            )
        }
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Would search notes for: \(trimmedQuery)"
            )
        }

        await openApplication(named: "Notes")
        let scriptResult = runAppleScript(source: """
        tell application "Notes"
            set matchingTitles to {}
            repeat with candidateNote in notes
                set candidateName to name of candidateNote
                set candidateBody to body of candidateNote
                if candidateName contains "\(Self.appleScriptEscaped(trimmedQuery))" or candidateBody contains "\(Self.appleScriptEscaped(trimmedQuery))" then
                    set end of matchingTitles to candidateName
                end if
            end repeat
            set AppleScript's text item delimiters to linefeed
            return matchingTitles as text
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "Failed to search notes: \(errorDescription)"
            )
        }

        let output = scriptResult.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            return PaceActionExecutionObservation(
                toolName: "notes",
                summary: "No notes found for: \(trimmedQuery)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "notes",
            summary: "Notes found for \(trimmedQuery):\n\(output)"
        )
    }

    private func composeMail(_ mailDraft: PaceMailDraft) async -> PaceActionExecutionObservation {
        print("🧰 Mail compose \"\(mailDraft.subject)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Would compose mail draft: \(mailDraft.subject)"
            )
        }

        let recipientResolution = await resolveMailRecipients(mailDraft.recipients)
        await openApplication(named: "Mail")
        let scriptResult = await createMailDraftViaMailtoAndAccessibility(
            mailDraft,
            resolvedRecipients: recipientResolution.recipients
        )

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Failed to compose mail draft: \(errorDescription)"
            )
        }

        let unresolvedRecipientSuffix: String = {
            guard !recipientResolution.unresolvedNames.isEmpty else { return "" }
            return " Unresolved contacts used as-is: \(recipientResolution.unresolvedNames.joined(separator: ", "))."
        }()
        return PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created mail draft: \(mailDraft.subject).\(unresolvedRecipientSuffix)"
        )
    }

    private func writeStreamingMailDraft(
        _ snapshot: PaceStreamingMailDraftSnapshot,
        isFinalWrite: Bool
    ) async -> PaceActionExecutionObservation? {
        let mailDraft = snapshot.normalizedMailDraft
        let shouldCreateDraft = activeStreamingMailDraftState == nil
        let recipientResolution = shouldCreateDraft
            ? await resolveMailRecipients(mailDraft.recipients)
            : MailRecipientResolution(recipients: mailDraft.recipients, unresolvedNames: [])

        if shouldCreateDraft {
            await openApplication(named: "Mail")
        }

        let scriptResult: (output: String?, errorDescription: String?)
        if shouldCreateDraft {
            scriptResult = await createMailDraftViaMailtoAndAccessibility(
                mailDraft,
                resolvedRecipients: recipientResolution.recipients
            )
        } else {
            scriptResult = await updateStreamingMailDraft(mailDraft)
        }

        if let errorDescription = scriptResult.errorDescription {
            activeStreamingMailDraftState = nil
            return PaceActionExecutionObservation(
                toolName: "mail",
                summary: "Failed to stream mail draft: \(errorDescription)"
            )
        }

        let now = Date()
        activeStreamingMailDraftState = PaceStreamingMailDraftState(
            lastWrittenSnapshot: snapshot,
            pendingSnapshot: nil,
            lastWriteDate: now
        )

        guard isFinalWrite else {
            return nil
        }

        let unresolvedRecipientSuffix: String = {
            guard !recipientResolution.unresolvedNames.isEmpty else { return "" }
            return " Unresolved contacts used as-is: \(recipientResolution.unresolvedNames.joined(separator: ", "))."
        }()
        return PaceActionExecutionObservation(
            toolName: "mail",
            summary: "Created streaming mail draft: \(mailDraft.subject).\(unresolvedRecipientSuffix)"
        )
    }

    private func createMailDraftViaMailtoAndAccessibility(
        _ mailDraft: PaceMailDraft,
        resolvedRecipients: [String]
    ) async -> (output: String?, errorDescription: String?) {
        guard let mailtoURL = Self.mailtoDraftURL(
            subject: mailDraft.subject,
            resolvedRecipients: resolvedRecipients
        ) else {
            return createStreamingMailDraftViaAppleScript(
                mailDraft,
                resolvedRecipients: resolvedRecipients
            )
        }

        guard NSWorkspace.shared.open(mailtoURL) else {
            return createStreamingMailDraftViaAppleScript(
                mailDraft,
                resolvedRecipients: resolvedRecipients
            )
        }

        let composeWindow = await waitForVisibleOutgoingMailDraft(
            matchingSubject: mailDraft.subject
        )
        let updateResult = await updateStreamingMailDraft(
            mailDraft,
            composeWindow: composeWindow
        )
        if updateResult.errorDescription == nil {
            return updateResult
        }

        return createStreamingMailDraftViaAppleScript(
            mailDraft,
            resolvedRecipients: resolvedRecipients
        )
    }

    static func mailtoDraftURL(
        subject: String,
        resolvedRecipients: [String]
    ) -> URL? {
        var mailtoComponents = URLComponents()
        mailtoComponents.scheme = "mailto"
        mailtoComponents.path = resolvedRecipients.joined(separator: ",")
        if !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mailtoComponents.queryItems = [
                URLQueryItem(name: "subject", value: subject)
            ]
        }
        return mailtoComponents.url
    }

    private func waitForVisibleOutgoingMailDraft(
        matchingSubject subject: String,
        timeoutInSeconds: TimeInterval = 1.0
    ) async -> AXUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeoutInSeconds)
        while Date() < deadline {
            if let composeWindow = currentMailComposeWindow(matchingSubject: subject) {
                return composeWindow
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func createStreamingMailDraftViaAppleScript(
        _ mailDraft: PaceMailDraft,
        resolvedRecipients: [String]
    ) -> (output: String?, errorDescription: String?) {
        let recipientLines = resolvedRecipients.map { recipient in
            "make new to recipient at end of to recipients with properties {address:\"\(Self.appleScriptEscaped(recipient))\"}"
        }
        .joined(separator: "\n            ")

        return runAppleScript(source: """
        tell application "Mail"
            activate
            set targetMessage to make new outgoing message with properties {subject:"\(Self.appleScriptEscaped(mailDraft.subject))", content:"\(Self.appleScriptEscaped(mailDraft.body))", visible:true}
            tell targetMessage
                \(recipientLines)
            end tell
        end tell
        """)
    }

    private func updateStreamingMailDraft(
        _ mailDraft: PaceMailDraft,
        composeWindow: AXUIElement? = nil
    ) async -> (output: String?, errorDescription: String?) {
        if mailDraft.body.isEmpty {
            return (nil, nil)
        }

        if await writeMailDraftBodyViaAccessibility(
            mailDraft.body,
            composeWindow: composeWindow ?? currentMailComposeWindow(matchingSubject: mailDraft.subject)
        ) {
            return (nil, nil)
        }

        return runAppleScript(source: """
        tell application "Mail"
            activate
            set visibleOutgoingMessages to outgoing messages whose visible is true
            if (count of visibleOutgoingMessages) is 0 then
                set targetMessage to make new outgoing message with properties {subject:"\(Self.appleScriptEscaped(mailDraft.subject))", content:"\(Self.appleScriptEscaped(mailDraft.body))", visible:true}
            else
                set targetMessage to item 1 of visibleOutgoingMessages
                set subject of targetMessage to "\(Self.appleScriptEscaped(mailDraft.subject))"
                set content of targetMessage to "\(Self.appleScriptEscaped(mailDraft.body))"
            end if
        end tell
        """)
    }

    private func writeMailDraftBodyViaAccessibility(
        _ bodyText: String,
        composeWindow: AXUIElement?
    ) async -> Bool {
        guard let composeWindow,
              let bodyElement = Self.bestMailComposeBodyElement(in: composeWindow) else {
            return false
        }

        let setValueResult = AXUIElementSetAttributeValue(
            bodyElement,
            kAXValueAttribute as CFString,
            bodyText as CFString
        )
        if setValueResult == .success {
            return true
        }

        return await replaceMailBodyViaFocusedTyping(
            bodyText,
            bodyElement: bodyElement
        )
    }

    private func replaceMailBodyViaFocusedTyping(
        _ bodyText: String,
        bodyElement: AXUIElement
    ) async -> Bool {
        let focusResult = AXUIElementPerformAction(bodyElement, kAXPressAction as CFString)
        guard focusResult == .success else {
            return false
        }

        await pressKey(named: "a", withModifiers: [.command])
        try? await Task.sleep(nanoseconds: 25_000_000)
        await typeText(bodyText)
        return true
    }

    private func currentMailComposeWindow(matchingSubject subject: String) -> AXUIElement? {
        guard let mailApplicationElement = mailApplicationElement() else {
            return nil
        }

        let normalizedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let focusedWindow = focusedWindowElement(in: mailApplicationElement)
        let windows = ([focusedWindow] + windows(of: mailApplicationElement))
            .compactMap { $0 }

        let windowsWithBodyCandidates = windows.filter {
            Self.bestMailComposeBodyElement(in: $0) != nil
        }
        guard !windowsWithBodyCandidates.isEmpty else {
            return nil
        }

        if !normalizedSubject.isEmpty,
           let subjectWindow = windowsWithBodyCandidates.first(where: { windowElement in
               Self.concatenatedTextAttributes(in: windowElement)
                   .lowercased()
                   .contains(normalizedSubject)
           }) {
            return subjectWindow
        }

        return windowsWithBodyCandidates.first
    }

    private func mailApplicationElement() -> AXUIElement? {
        guard let mailApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.mail")
            .first else {
            return nil
        }
        return AXUIElementCreateApplication(mailApplication.processIdentifier)
    }

    private func focusedWindowElement(in applicationElement: AXUIElement) -> AXUIElement? {
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedWindowResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedWindowValue as! AXUIElement)
    }

    private func windows(of applicationElement: AXUIElement) -> [AXUIElement] {
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard windowsResult == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private static func bestMailComposeBodyElement(in rootElement: AXUIElement) -> AXUIElement? {
        var bestCandidate: (element: AXUIElement, score: Double)?
        var queue: [AXUIElement] = [rootElement]
        var visitedCount = 0

        while let element = queue.first, visitedCount < 500 {
            queue.removeFirst()
            visitedCount += 1

            let metadata = PaceMailComposeBodyCandidateMetadata(
                role: stringAttribute(kAXRoleAttribute as CFString, of: element),
                title: stringAttribute(kAXTitleAttribute as CFString, of: element),
                description: stringAttribute(kAXDescriptionAttribute as CFString, of: element),
                help: stringAttribute(kAXHelpAttribute as CFString, of: element),
                value: stringAttribute(kAXValueAttribute as CFString, of: element),
                placeholder: stringAttribute("AXPlaceholderValue" as CFString, of: element),
                frame: axFrameMetadata(of: element)
            )

            if metadata.score > 0,
               bestCandidate == nil || metadata.score > (bestCandidate?.score ?? 0) {
                bestCandidate = (element, metadata.score)
            }

            queue.append(contentsOf: children(of: element))
        }

        return bestCandidate?.element
    }

    private static func concatenatedTextAttributes(in rootElement: AXUIElement) -> String {
        var values: [String] = []
        var queue: [AXUIElement] = [rootElement]
        var visitedCount = 0

        while let element = queue.first, visitedCount < 300 {
            queue.removeFirst()
            visitedCount += 1
            values.append(contentsOf: [
                stringAttribute(kAXTitleAttribute as CFString, of: element),
                stringAttribute(kAXDescriptionAttribute as CFString, of: element),
                stringAttribute(kAXValueAttribute as CFString, of: element)
            ].compactMap { $0 })
            queue.append(contentsOf: children(of: element))
        }

        return values.joined(separator: " ")
    }

    private static func axFrameMetadata(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        )
        guard positionResult == .success,
              sizeResult == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ attributeName: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName, &value)
        guard result == .success, let value else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard result == .success,
              let childrenValue,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    private struct MailRecipientResolution {
        let recipients: [String]
        let unresolvedNames: [String]
    }

    private func resolveMailRecipients(_ rawRecipients: [String]) async -> MailRecipientResolution {
        let trimmedRecipients = rawRecipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let contactNamesToResolve = trimmedRecipients
            .filter { !Self.looksLikeEmailAddress($0) }
            .map(Self.contactNameToResolve)

        guard !contactNamesToResolve.isEmpty else {
            return MailRecipientResolution(
                recipients: trimmedRecipients,
                unresolvedNames: []
            )
        }

        guard await requestContactsAccessIfNeeded() else {
            return MailRecipientResolution(
                recipients: trimmedRecipients,
                unresolvedNames: contactNamesToResolve
            )
        }

        var resolvedRecipients: [String] = []
        var unresolvedNames: [String] = []

        for rawRecipient in trimmedRecipients {
            guard !Self.looksLikeEmailAddress(rawRecipient) else {
                resolvedRecipients.append(rawRecipient)
                continue
            }

            let contactName = Self.contactNameToResolve(rawRecipient)
            if let emailAddress = emailAddressForContact(named: contactName) {
                resolvedRecipients.append(emailAddress)
            } else {
                resolvedRecipients.append(rawRecipient)
                unresolvedNames.append(contactName)
            }
        }

        return MailRecipientResolution(
            recipients: resolvedRecipients,
            unresolvedNames: unresolvedNames
        )
    }

    private func requestContactsAccessIfNeeded() async -> Bool {
        // Never trigger a mid-action TCC prompt — fail with an error
        // observation if the user hasn't granted access yet. They grant
        // once from System Settings on their own time, not while a
        // dictation turn is in progress.
        let authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        switch authorizationStatus {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    private func emailAddressForContact(named contactName: String) -> String? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingName: contactName)

        do {
            let matchingContacts = try contactStore.unifiedContacts(
                matching: predicate,
                keysToFetch: keysToFetch
            )
            return matchingContacts
                .flatMap(\.emailAddresses)
                .map { String($0.value) }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } catch {
            print("⚠️ PaceActionExecutor: contact lookup failed for \(contactName): \(error.localizedDescription)")
            return nil
        }
    }

    private static func looksLikeEmailAddress(_ recipient: String) -> Bool {
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedRecipient.contains("@") && trimmedRecipient.contains(".")
    }

    private static func contactNameToResolve(_ rawRecipient: String) -> String {
        rawRecipient
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "__resolve:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createThingsToDo(_ request: PaceThingsToDoRequest) async -> PaceActionExecutionObservation {
        print("🧰 Things create \"\(request.title)\" (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "things",
                summary: "Would create Things to-do: \(request.title)"
            )
        }

        guard Self.findApplicationURL(named: "Things3") != nil || Self.findApplicationURL(named: "Things") != nil else {
            return PaceActionExecutionObservation(
                toolName: "things",
                summary: "Things is not installed."
            )
        }

        let notesClause = request.notes.map { "notes:\"\(Self.appleScriptEscaped($0))\"" } ?? "notes:\"\""
        let scriptResult = runAppleScript(source: """
        tell application "Things3"
            activate
            make new to do with properties {name:"\(Self.appleScriptEscaped(request.title))", \(notesClause)}
        end tell
        """)

        if let errorDescription = scriptResult.errorDescription {
            return PaceActionExecutionObservation(
                toolName: "things",
                summary: "Failed to create Things to-do: \(errorDescription)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "things",
            summary: "Created Things to-do: \(request.title)"
        )
    }

    private func runShortcut(named shortcutName: String) async -> PaceActionExecutionObservation {
        let trimmedShortcutName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧰 Shortcuts run \"\(trimmedShortcutName)\" (enabled: \(actionsAreEnabled))")
        guard !trimmedShortcutName.isEmpty else {
            return PaceActionExecutionObservation(toolName: "shortcuts", summary: "No shortcut name was provided.")
        }

        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Would run shortcut: \(trimmedShortcutName)"
            )
        }

        let shortcutListResult = runShortcutsCommand(arguments: ["list"])
        guard shortcutListResult.terminationStatus == 0 else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Failed to list shortcuts: \(shortcutListResult.failureSummary)"
            )
        }

        let installedShortcutNames = Self.installedShortcutNames(
            fromListOutput: shortcutListResult.output
        )
        guard Self.shortcutList(
            installedShortcutNames,
            containsShortcutNamed: trimmedShortcutName
        ) else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "I don't see a shortcut called \(trimmedShortcutName)."
            )
        }

        let shortcutRunResult = runShortcutsCommand(arguments: ["run", trimmedShortcutName])
        guard shortcutRunResult.terminationStatus == 0 else {
            return PaceActionExecutionObservation(
                toolName: "shortcuts",
                summary: "Failed to run shortcut: \(shortcutRunResult.failureSummary)"
            )
        }

        return PaceActionExecutionObservation(
            toolName: "shortcuts",
            summary: "Ran shortcut: \(trimmedShortcutName)"
        )
    }

    static func installedShortcutNames(fromListOutput listOutput: String) -> [String] {
        listOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func shortcutList(
        _ installedShortcutNames: [String],
        containsShortcutNamed requestedShortcutName: String
    ) -> Bool {
        let normalizedRequestedShortcutName = normalizeShortcutName(requestedShortcutName)
        return installedShortcutNames.contains { installedShortcutName in
            normalizeShortcutName(installedShortcutName) == normalizedRequestedShortcutName
        }
    }

    private static func normalizeShortcutName(_ shortcutName: String) -> String {
        shortcutName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func openMessages(_ request: PaceMessageRequest) async -> PaceActionExecutionObservation {
        print("🧰 Messages open (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "messages",
                summary: "Would open Messages."
            )
        }

        await openApplication(named: "Messages")
        return PaceActionExecutionObservation(
            toolName: "messages",
            summary: request.recipient?.isEmpty == false
                ? "Opened Messages. Recipient requested: \(request.recipient!)."
                : "Opened Messages."
        )
    }

    private func postAuxiliaryKeyEvent(keyType: Int32) {
        let keyDownData = (keyType << 16) | (0xA << 8)
        let keyUpData = (keyType << 16) | (0xB << 8)

        for eventData in [keyDownData, keyUpData] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(eventData),
                data2: -1
            )?.cgEvent else {
                continue
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func requestCalendarAccessIfNeeded() async -> Bool {
        // No mid-action TCC prompt: check status, fail with an error
        // observation if missing. The user grants once from Settings on
        // their own time, never during a voice turn.
        return Self.isEventKitAccessAlreadyGranted(for: .event)
    }

    private func requestReminderAccessIfNeeded() async -> Bool {
        return Self.isEventKitAccessAlreadyGranted(for: .reminder)
    }

    private static func isEventKitAccessAlreadyGranted(for entityType: EKEntityType) -> Bool {
        let authorizationStatus = EKEventStore.authorizationStatus(for: entityType)
        // The app targets macOS 26+, where `.fullAccess` is the only status
        // that grants both read and write to EventKit entities. The legacy
        // `.authorized` case was retired on macOS 14.
        return authorizationStatus == .fullAccess
    }

    private func runAppleScript(source: String) -> (output: String?, errorDescription: String?) {
        guard let script = NSAppleScript(source: source) else {
            return (nil, "Could not compile AppleScript.")
        }

        var errorInfo: NSDictionary?
        let resultDescriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            return (nil, message)
        }

        return (resultDescriptor.stringValue, nil)
    }

    private struct PaceLocalCommandResult {
        let output: String
        let errorOutput: String
        let terminationStatus: Int32

        var failureSummary: String {
            let trimmedErrorOutput = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedErrorOutput.isEmpty {
                return trimmedErrorOutput
            }

            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutput.isEmpty {
                return trimmedOutput
            }

            return "command exited with status \(terminationStatus)"
        }
    }

    private func runShortcutsCommand(arguments: [String]) -> PaceLocalCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return PaceLocalCommandResult(
                output: "",
                errorOutput: error.localizedDescription,
                terminationStatus: 1
            )
        }

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()

        return PaceLocalCommandResult(
            output: String(data: standardOutputData, encoding: .utf8) ?? "",
            errorOutput: String(data: standardErrorData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }

    private static func findApplicationURL(named applicationName: String) -> URL? {
        let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApplicationName.isEmpty else { return nil }

        if trimmedApplicationName.contains("."),
           let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmedApplicationName) {
            return bundleURL
        }

        let requestedAppName = trimmedApplicationName.hasSuffix(".app")
            ? String(trimmedApplicationName.dropLast(4))
            : trimmedApplicationName
        let normalizedRequestedName = normalizeApplicationName(requestedAppName)

        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]

        for searchRoot in searchRoots {
            guard let appURL = findApplicationURL(
                matchingNormalizedName: normalizedRequestedName,
                under: searchRoot
            ) else {
                continue
            }
            return appURL
        }

        return nil
    }

    private static func appleScriptEscaped(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func findApplicationURL(
        matchingNormalizedName normalizedRequestedName: String,
        under searchRoot: URL
    ) -> URL? {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isApplicationKey]
        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let candidateURL as URL in enumerator {
            guard candidateURL.pathExtension.lowercased() == "app" else { continue }
            let candidateName = candidateURL.deletingPathExtension().lastPathComponent
            if normalizeApplicationName(candidateName) == normalizedRequestedName {
                return candidateURL
            }
        }

        return nil
    }

    private static func normalizeApplicationName(_ applicationName: String) -> String {
        applicationName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let soundUpKeyType: Int32 = 0
    private static let soundDownKeyType: Int32 = 1
    private static let brightnessUpKeyType: Int32 = 2
    private static let brightnessDownKeyType: Int32 = 3
    private static let mediaPlayPauseKeyType: Int32 = 16
    private static let mediaNextKeyType: Int32 = 17
    private static let mediaPreviousKeyType: Int32 = 18

    // MARK: - Keyboard

    private func typeText(_ textToType: String) async {
        print("⌨️  Type \(textToType.count) chars (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        // Use unicode-string CGEvents so we don't have to map every char to
        // a key code. This works for any printable text including emoji.
        // Each grapheme gets its own keyDown + keyUp pair.
        for unicodeCharacter in textToType {
            let utf16Units = Array(String(unicodeCharacter).utf16)
            guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyDownEvent.post(tap: .cghidEventTap)

            guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyUpEvent.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 8_000_000) // 8ms between chars feels natural
        }
    }

    private func setTextValue(_ request: PaceSetTextValueRequest) -> PaceActionExecutionObservation {
        print("⌨️  Set text value target=\(request.target.rawValue) chars=\(request.value.count) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "set_value",
                summary: "Would \(request.target.dryRunVerb) \(request.value.count) characters."
            )
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return PaceActionExecutionObservation(
                toolName: "set_value",
                summary: "No focused editable element was found."
            )
        }

        let focusedElement = focusedElementValue as! AXUIElement
        guard let originalText = stringValue(of: focusedElement) else {
            return PaceActionExecutionObservation(
                toolName: "set_value",
                summary: "Focused text value could not be read for undo."
            )
        }

        let replacementText: String
        switch request.target {
        case .focused:
            replacementText = request.value
        case .selection:
            guard let selectedTextReplacement = selectedTextReplacement(
                in: focusedElement,
                currentText: originalText,
                replacementText: request.value
            ) else {
                return PaceActionExecutionObservation(
                    toolName: "set_value",
                    summary: "No selected text was found to replace."
                )
            }
            replacementText = selectedTextReplacement
        }

        let setValueResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            replacementText as CFString
        )

        guard setValueResult == .success else {
            return PaceActionExecutionObservation(
                toolName: "set_value",
                summary: "Focused text value could not be changed via Accessibility."
            )
        }

        mutationLog.append(.axValue(
            element: focusedElement,
            oldValue: originalText,
            summary: request.target == .selection ? "selected text replacement" : "focused text update"
        ))

        return PaceActionExecutionObservation(
            toolName: "set_value",
            summary: request.target == .selection
                ? "Replaced selected text."
                : "Updated focused text value."
        )
    }

    private func editSelectedText(_ request: PaceVoiceEditRequest) -> PaceActionExecutionObservation {
        print("✏️  Edit selected text operation=\(request.operation.displayName) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "Would \(request.operation.displayName)."
            )
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "No focused editable element was found."
            )
        }

        let focusedElement = focusedElementValue as! AXUIElement
        guard let originalText = stringValue(of: focusedElement) else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "Focused text value could not be read for editing."
            )
        }

        guard let selectedText = selectedText(in: focusedElement, currentText: originalText) else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "No selected text was found to edit."
            )
        }

        guard let editedSelectedText = PaceVoiceEditProcessor.process(
            selectedText: selectedText,
            request: request
        ), editedSelectedText != selectedText else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "No deterministic edit was available for the selected text."
            )
        }

        guard let replacementText = selectedTextReplacement(
            in: focusedElement,
            currentText: originalText,
            replacementText: editedSelectedText
        ) else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "Selected text range could not be mapped for editing."
            )
        }

        let setValueResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            replacementText as CFString
        )

        guard setValueResult == .success else {
            return PaceActionExecutionObservation(
                toolName: "edit_selection",
                summary: "Focused text value could not be changed via Accessibility."
            )
        }

        mutationLog.append(.axValue(
            element: focusedElement,
            oldValue: originalText,
            summary: "selected text edit"
        ))

        return PaceActionExecutionObservation(
            toolName: "edit_selection",
            summary: "Edited selected text."
        )
    }

    private func undoLastMutation() -> PaceActionExecutionObservation {
        print("↩️  Undo last mutation (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: "undo_last",
                summary: "Would undo the last editable text change."
            )
        }

        guard let mutation = mutationLog.popLast() else {
            return PaceActionExecutionObservation(
                toolName: "undo_last",
                summary: "Nothing undoable is available."
            )
        }

        switch mutation {
        case .axValue(let element, let oldValue, let summary):
            let setValueResult = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                oldValue as CFString
            )
            guard setValueResult == .success else {
                return PaceActionExecutionObservation(
                    toolName: "undo_last",
                    summary: "Could not undo \(summary); the target element no longer accepts Accessibility updates."
                )
            }

            return PaceActionExecutionObservation(
                toolName: "undo_last",
                summary: "Undid \(summary)."
            )
        }
    }

    private func stringValue(of focusedElement: AXUIElement) -> String? {
        var currentValue: CFTypeRef?
        let currentValueResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValue
        )
        guard currentValueResult == .success else {
            return nil
        }
        return currentValue as? String
    }

    private func selectedTextReplacement(
        in focusedElement: AXUIElement,
        currentText: String,
        replacementText: String
    ) -> String? {
        var selectedRangeValue: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard selectedRangeResult == .success,
              let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(
            selectedRangeValue as! AXValue,
            .cfRange,
            &selectedRange
        ),
              selectedRange.length > 0 else {
            return nil
        }

        guard let swiftRange = Range(
            NSRange(location: selectedRange.location, length: selectedRange.length),
            in: currentText
        ) else {
            return nil
        }

        var updatedText = currentText
        updatedText.replaceSubrange(swiftRange, with: replacementText)
        return updatedText
    }

    private func selectedText(
        in focusedElement: AXUIElement,
        currentText: String
    ) -> String? {
        var selectedRangeValue: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard selectedRangeResult == .success,
              let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(
            selectedRangeValue as! AXValue,
            .cfRange,
            &selectedRange
        ),
              selectedRange.length > 0,
              let swiftRange = Range(
                NSRange(location: selectedRange.location, length: selectedRange.length),
                in: currentText
              ) else {
            return nil
        }

        return String(currentText[swiftRange])
    }

    private func pressKey(named keyName: String, withModifiers modifiers: [PaceKeyboardModifier]) async {
        print("⌨️  Press \(keyName) with modifiers \(modifiers) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        guard let virtualKeyCode = Self.virtualKeyCode(forKeyName: keyName) else {
            print("⚠️ PaceActionExecutor: unknown key name \(keyName)")
            return
        }

        let modifierFlags = Self.cgEventFlags(forModifiers: modifiers)

        if let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: true) {
            keyDownEvent.flags = modifierFlags
            keyDownEvent.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        if let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: false) {
            keyUpEvent.flags = modifierFlags
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }

    private func callMCPTool(_ mcpToolCall: PaceMCPToolCall) async -> PaceActionExecutionObservation {
        let toolObservationName = "mcp.\(mcpToolCall.serverName).\(mcpToolCall.toolName)"

        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: toolObservationName,
                summary: "Would call MCP tool: \(mcpToolCall.approvalDescription)"
            )
        }

        do {
            let resultSummary = try await mcpClient.callTool(mcpToolCall)
            return PaceActionExecutionObservation(
                toolName: toolObservationName,
                summary: resultSummary.isEmpty ? "MCP tool completed: \(mcpToolCall.approvalDescription)" : resultSummary
            )
        } catch {
            return PaceActionExecutionObservation(
                toolName: toolObservationName,
                summary: "Failed MCP tool \(mcpToolCall.approvalDescription): \(error)"
            )
        }
    }
}
