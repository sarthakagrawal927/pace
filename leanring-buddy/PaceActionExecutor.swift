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
    let interActionDelay: TimeInterval = 0.075

    /// Hybrid targeter that tries the accessibility tree first before
    /// falling back to raw CGEvent clicks. Single-click only — double-
    /// click and drag still go through CGEvent because AX doesn't have
    /// a built-in "double-press" action.
    let axTargeter = PaceAXTargeter()
    let eventStore = EKEventStore()
    let contactStore = CNContactStore()
    let mcpClient: PaceMCPStdioClient
    let timerScheduler: PaceTimerScheduler
    var mutationLog: [PaceActionMutation] = []
    var activeStreamingMailDraftState: PaceStreamingMailDraftState?

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

    /// Callback wired by `CompanionManager` so the executor can flip
    /// the off-device-turn tint while a hosted-MCP tool call (e.g.
    /// Composio) is in flight. The closure takes the new flag value;
    /// true at call start, false in the `defer`. Default no-op keeps
    /// the executor testable without a CompanionManager.
    var setOffDeviceTurnInFlightCallback: (Bool) -> Void = { _ in }

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




}
