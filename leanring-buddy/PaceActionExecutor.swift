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
struct ScreenshotPixelLocation {
    let xInScreenshotPixels: Int
    let yInScreenshotPixels: Int
    /// 1-based screen index from the screenshot label. nil = cursor screen.
    let screenNumber: Int?
}

struct PaceClickCandidate {
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

struct PaceClickCandidateRecency {
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

struct PaceClickCandidateSet {
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
    private var mutationLog: [PaceActionMutation] = []
    private var activeStreamingMailDraftState: PaceStreamingMailDraftState?

    init(
        actionsAreEnabledOverride: Bool? = nil,
        mcpClient: PaceMCPStdioClient = PaceMCPStdioClient()
    ) {
        self.mcpClient = mcpClient
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
        if #available(macOS 14.0, *) {
            return authorizationStatus == .fullAccess
        }
        return authorizationStatus == .authorized
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

    // MARK: - Key name → virtual key code

    static func virtualKeyCode(forKeyName keyName: String) -> CGKeyCode? {
        // ANSI (US-layout) virtual key codes for every letter, digit, common
        // punctuation, function key, and named key. parseKeyPayload validates
        // against this table, so parse-time acceptance and execution-time
        // capability stay in lockstep — an unmappable key name is rejected
        // before it reaches the executor instead of failing mid-plan.
        switch keyName.lowercased() {
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "=", "equals": return 0x18
        case "9": return 0x19
        case "7": return 0x1A
        case "-", "minus": return 0x1B
        case "8": return 0x1C
        case "0": return 0x1D
        case "]": return 0x1E
        case "o": return 0x1F
        case "u": return 0x20
        case "[": return 0x21
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "'": return 0x27
        case "k": return 0x28
        case ";": return 0x29
        case "\\": return 0x2A
        case ",", "comma": return 0x2B
        case "/", "slash": return 0x2C
        case "n": return 0x2D
        case "m": return 0x2E
        case ".", "period": return 0x2F
        case "`", "backtick", "grave": return 0x32
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "forwarddelete": return 0x75
        case "escape", "esc": return 0x35
        case "up", "uparrow": return 0x7E
        case "down", "downarrow": return 0x7D
        case "left", "leftarrow": return 0x7B
        case "right", "rightarrow": return 0x7C
        case "home": return 0x73
        case "end": return 0x77
        case "pageup": return 0x74
        case "pagedown": return 0x79
        case "f1": return 0x7A
        case "f2": return 0x78
        case "f3": return 0x63
        case "f4": return 0x76
        case "f5": return 0x60
        case "f6": return 0x61
        case "f7": return 0x62
        case "f8": return 0x64
        case "f9": return 0x65
        case "f10": return 0x6D
        case "f11": return 0x67
        case "f12": return 0x6F
        default:
            return nil
        }
    }

    private static func cgEventFlags(forModifiers modifiers: [PaceKeyboardModifier]) -> CGEventFlags {
        var combinedFlags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: combinedFlags.insert(.maskCommand)
            case .option: combinedFlags.insert(.maskAlternate)
            case .control: combinedFlags.insert(.maskControl)
            case .shift: combinedFlags.insert(.maskShift)
            }
        }
        return combinedFlags
    }

    // MARK: - Coordinate conversion

    /// Maps a screenshot-pixel coordinate to a global CG point (the
    /// coordinate space CGEvent expects: top-left origin, points). The
    /// math mirrors the pointing logic in CompanionManager so what the
    /// user sees the cursor *point at* is exactly where a click would land.
    private func convertScreenshotPixelToDisplayGlobalPoint(
        screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture]
    ) -> CGPoint? {
        let targetCapture: CompanionScreenCapture? = {
            if let screenNumber = screenshotPixelLocation.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()

        guard let capture = targetCapture else { return nil }

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedScreenshotX = max(0, min(CGFloat(screenshotPixelLocation.xInScreenshotPixels), screenshotWidth))
        let clampedScreenshotY = max(0, min(CGFloat(screenshotPixelLocation.yInScreenshotPixels), screenshotHeight))

        let displayLocalX = clampedScreenshotX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedScreenshotY * (displayHeight / screenshotHeight)

        // CG global coordinates have top-left origin on the main screen.
        // CompanionScreenCapture.displayFrame is in AppKit coords (bottom-left
        // origin), so we need to convert here. The main screen's height in
        // AppKit coords minus the AppKit y of the top of the display gives
        // the CG y of the top of the display.
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = mainScreen.frame.height
        let displayCGTopY = mainScreenHeight - (displayFrame.origin.y + displayHeight)

        let globalCGPoint = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: displayLocalY + displayCGTopY
        )

        return globalCGPoint
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

// MARK: - Parsed action types

struct PaceActionExecutionObservation {
    let toolName: String
    let summary: String

    static func formatForPlanner(_ observations: [PaceActionExecutionObservation]) -> String {
        observations
            .enumerated()
            .map { index, observation in
                "[\(index + 1)] \(observation.toolName): \(observation.summary)"
            }
            .joined(separator: "\n")
    }

    static func formatForUserFeedback(_ observations: [PaceActionExecutionObservation]) -> String? {
        let userVisibleSummaries = observations
            .map(\.summary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstSummary = userVisibleSummaries.first else {
            return nil
        }

        if userVisibleSummaries.count == 1 {
            return firstSummary
        }

        return "\(firstSummary), plus \(userVisibleSummaries.count - 1) more action result\(userVisibleSummaries.count == 2 ? "" : "s")."
    }
}

struct PaceActionExecutionPlan {
    let steps: [PaceActionExecutionStep]

    static func serial(actions: [PaceParsedAction]) -> PaceActionExecutionPlan {
        PaceActionExecutionPlan(
            steps: actions.map { PaceActionExecutionStep(actions: [$0]) }
        )
    }

    var flattenedActions: [PaceParsedAction] {
        steps.flatMap(\.actions)
    }

    var approvalSummary: String {
        steps
            .enumerated()
            .flatMap { stepIndex, step in
                step.actions.enumerated().map { actionIndex, action in
                    let stepLabel = "Step \(stepIndex + 1)"
                    let riskLabel = PaceToolRegistry.riskDisplayName(for: action)
                    if step.actions.count == 1 {
                        return "\(stepLabel): [\(riskLabel)] \(action.approvalDescription)"
                    }
                    return "\(stepLabel).\(actionIndex + 1): [\(riskLabel)] \(action.approvalDescription)"
                }
            }
            .joined(separator: "\n")
    }
}

struct PaceActionExecutionStep {
    let actions: [PaceParsedAction]
}

enum PaceActionMutation {
    case axValue(element: AXUIElement, oldValue: String, summary: String)
}

/// One action Claude wants pace to perform on the user's behalf.
/// Parsed out of the assistant's response by `PaceActionTagParser`.
enum PaceParsedAction {
    case click(ScreenshotPixelLocation)
    case doubleClick(ScreenshotPixelLocation)
    case clickCandidates(PaceClickCandidateSet)
    case type(String)
    case setTextValue(PaceSetTextValueRequest)
    case editSelectedText(PaceVoiceEditRequest)
    case undoLastMutation
    case pressKey(name: String, modifiers: [PaceKeyboardModifier])
    case readClipboard
    case snapWindow(PaceWindowSnapRequest)
    case scroll(PaceScrollDirection, amountInLines: Int)
    case openApplication(String)
    case openURL(String)
    case controlMusic(PaceMusicCommand)
    case adjustVolume(PaceSystemAdjustment)
    case adjustBrightness(PaceSystemAdjustment)
    case listCalendarEvents(PaceCalendarQuery)
    case createCalendarEvent(PaceCalendarEventRequest)
    case createReminder(PaceReminderRequest)
    case finder(PaceFinderRequest)
    case createNote(PaceNoteRequest)
    case appendNote(PaceNoteRequest)
    case searchNotes(String)
    case composeMail(PaceMailDraft)
    case createThingsToDo(PaceThingsToDoRequest)
    case runShortcut(String)
    case openMessages(PaceMessageRequest)
    case downloadFile(PaceFileDownloadRequest)
    case mcp(PaceMCPToolCall)

    /// Audit-log operation slug — the verb part. Mirrors the case name.
    var auditOperationName: String {
        switch self {
        case .click: return "click"
        case .doubleClick: return "double_click"
        case .clickCandidates: return "click_candidates"
        case .type: return "type"
        case .setTextValue: return "set_value"
        case .editSelectedText: return "edit_selection"
        case .undoLastMutation: return "undo"
        case .pressKey: return "key_press"
        case .readClipboard: return "clipboard_read"
        case .snapWindow: return "window_snap"
        case .scroll: return "scroll"
        case .openApplication: return "open_app"
        case .openURL: return "open_url"
        case .controlMusic: return "music"
        case .adjustVolume: return "volume"
        case .adjustBrightness: return "brightness"
        case .listCalendarEvents: return "calendar_read"
        case .createCalendarEvent: return "calendar_create"
        case .createReminder: return "reminder_create"
        case .finder: return "finder"
        case .createNote: return "note_create"
        case .appendNote: return "note_append"
        case .searchNotes: return "note_search"
        case .composeMail: return "mail_draft"
        case .createThingsToDo: return "things_create"
        case .runShortcut: return "shortcut_run"
        case .openMessages: return "messages_open"
        case .downloadFile: return "download_file"
        case .mcp: return "mcp_call"
        }
    }

    /// Audit-log target — the noun: what app, server, or URL the action
    /// touches. Sizes capped so even pathological inputs stay log-safe.
    var auditTarget: String {
        switch self {
        case .openApplication(let appName):
            return appName
        case .openURL(let urlString):
            return String(urlString.prefix(120))
        case .runShortcut(let name):
            return name
        case .openMessages(let request):
            return request.recipient ?? "messages"
        case .composeMail(let draft):
            return draft.recipients.first ?? "mail"
        case .createCalendarEvent(let request):
            return String(request.title.prefix(60))
        case .createReminder(let request):
            return String(request.title.prefix(60))
        case .createNote(let request), .appendNote(let request):
            return String(request.title.prefix(60))
        case .searchNotes(let query):
            return String(query.prefix(60))
        case .createThingsToDo(let request):
            return String(request.title.prefix(60))
        case .finder(let request):
            return String(request.path.prefix(120))
        case .downloadFile(let request):
            return String(request.url.absoluteString.prefix(120))
        case .mcp(let toolCall):
            return "\(toolCall.serverName).\(toolCall.toolName)"
        case .pressKey(let keyName, let modifiers):
            let modifierPrefix = modifiers.isEmpty
                ? ""
                : modifiers.map(\.rawValue).joined(separator: "+") + "+"
            return "\(modifierPrefix)\(keyName)"
        case .controlMusic(let command):
            return command.rawValue
        case .adjustVolume, .adjustBrightness:
            return auditOperationName
        case .scroll(let direction, _):
            return direction.rawValue
        case .snapWindow(let request):
            return request.position.rawValue
        default:
            return ""
        }
    }

    var approvalDescription: String {
        switch self {
        case .click(let location):
            return "Click at \(location.approvalDescription)"
        case .doubleClick(let location):
            return "Double-click at \(location.approvalDescription)"
        case .clickCandidates(let clickCandidateSet):
            let candidateCount = clickCandidateSet.candidates.count
            if clickCandidateSet.clickCount == 2 {
                return "Double-click best of \(candidateCount) candidates"
            }
            return "Click best of \(candidateCount) candidates"
        case .type(let text):
            return "Type \(text.count) characters"
        case .setTextValue(let setTextValueRequest):
            switch setTextValueRequest.target {
            case .focused:
                return "Set focused text value"
            case .selection:
                return "Replace selected text"
            }
        case .editSelectedText(let voiceEditRequest):
            return "Edit selected text: \(voiceEditRequest.operation.displayName)"
        case .undoLastMutation:
            return "Undo last editable text change"
        case .pressKey(let keyName, let modifiers):
            let modifierPrefix = modifiers.isEmpty
                ? ""
                : modifiers.map(\.rawValue).joined(separator: "+") + "+"
            return "Press \(modifierPrefix)\(keyName)"
        case .readClipboard:
            return "Read clipboard text"
        case .snapWindow(let snapWindowRequest):
            return "Snap focused window: \(snapWindowRequest.position.displayName)"
        case .scroll(let direction, let amountInLines):
            return "Scroll \(direction.rawValue) \(amountInLines) lines"
        case .openApplication(let applicationName):
            return "Open app: \(applicationName)"
        case .openURL(let urlString):
            return "Open URL: \(urlString)"
        case .controlMusic(let musicCommand):
            return "Control Music: \(musicCommand.rawValue)"
        case .adjustVolume(let adjustment):
            return "Adjust volume: \(adjustment.description)"
        case .adjustBrightness(let adjustment):
            return "Adjust brightness: \(adjustment.description)"
        case .listCalendarEvents(let calendarQuery):
            return "Read Calendar: \(calendarQuery.range.displayName)"
        case .createCalendarEvent(let calendarEventRequest):
            return "Create calendar event: \(calendarEventRequest.title)"
        case .createReminder(let reminderRequest):
            return "Create reminder: \(reminderRequest.title)"
        case .finder(let finderRequest):
            return "Finder \(finderRequest.action.rawValue): \(finderRequest.path)"
        case .createNote(let noteRequest):
            let trimmedBody = noteRequest.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else {
                return "Create note: \(noteRequest.title)"
            }
            return "Create note: \(noteRequest.title) — \(Self.truncatedForApproval(trimmedBody))"
        case .appendNote(let noteRequest):
            return "Append note: \(noteRequest.title) — \(Self.truncatedForApproval(noteRequest.body))"
        case .searchNotes(let query):
            return "Search notes: \(query)"
        case .composeMail(let mailDraft):
            return "Compose mail draft: \(mailDraft.subject)"
        case .createThingsToDo(let thingsToDoRequest):
            return "Create Things to-do: \(thingsToDoRequest.title)"
        case .runShortcut(let shortcutName):
            return "Run shortcut: \(shortcutName)"
        case .openMessages(let messageRequest):
            if let recipient = messageRequest.recipient, !recipient.isEmpty {
                return "Open Messages for: \(recipient)"
            }
            return "Open Messages"
        case .downloadFile(let downloadRequest):
            return "Download file to ~/Downloads: \(downloadRequest.url.absoluteString)"
        case .mcp(let mcpToolCall):
            return "Call MCP tool: \(mcpToolCall.approvalDescription)"
        }
    }

    private static func truncatedForApproval(_ text: String) -> String {
        let maximumApprovalCharacters = 80
        guard text.count > maximumApprovalCharacters else {
            return text
        }
        let prefix = text.prefix(maximumApprovalCharacters)
        return "\(prefix)…"
    }
}

private extension ScreenshotPixelLocation {
    var approvalDescription: String {
        let screenSuffix = screenNumber.map { ", screen \($0)" } ?? ""
        return "\(xInScreenshotPixels), \(yInScreenshotPixels)\(screenSuffix)"
    }
}

enum PaceKeyboardModifier: String {
    case command, option, control, shift
}

struct PaceWindowSnapRequest {
    let position: PaceWindowSnapPosition
}

enum PaceWindowSnapPosition: String {
    case left
    case right
    case top
    case bottom
    case maximize
    case center

    var displayName: String {
        switch self {
        case .left:
            return "left half"
        case .right:
            return "right half"
        case .top:
            return "top half"
        case .bottom:
            return "bottom half"
        case .maximize:
            return "maximize"
        case .center:
            return "center"
        }
    }

    func targetFrame(in visibleFrame: CGRect) -> CGRect {
        switch self {
        case .left:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .right:
            return CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .top:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height / 2
            )
        case .bottom:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.midY,
                width: visibleFrame.width,
                height: visibleFrame.height / 2
            )
        case .maximize:
            return visibleFrame
        case .center:
            let width = visibleFrame.width * 0.8
            let height = visibleFrame.height * 0.85
            return CGRect(
                x: visibleFrame.midX - (width / 2),
                y: visibleFrame.midY - (height / 2),
                width: width,
                height: height
            )
        }
    }
}

struct PaceSetTextValueRequest {
    let value: String
    let target: PaceSetTextValueTarget
}

enum PaceSetTextValueTarget: String {
    case focused
    case selection

    var dryRunVerb: String {
        switch self {
        case .focused:
            return "set focused text to"
        case .selection:
            return "replace selected text with"
        }
    }
}

enum PaceScrollDirection: String, CustomStringConvertible {
    case up, down

    var description: String { rawValue }
}

struct PaceSystemAdjustment: CustomStringConvertible {
    let direction: PaceAdjustmentDirection
    let stepCount: Int

    var description: String {
        "\(direction.rawValue):\(stepCount)"
    }
}

enum PaceAdjustmentDirection: String {
    case up, down
}

enum PaceMusicCommand: String, Equatable {
    case play
    case pause
    case playPause
    case next
    case previous
}

struct PaceCalendarQuery {
    let range: PaceCalendarRange

    func dateInterval(relativeTo date: Date) -> DateInterval {
        let calendar = Calendar.current
        switch range {
        case .today:
            let startOfToday = calendar.startOfDay(for: date)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? date
            return DateInterval(start: startOfToday, end: endOfToday)
        case .tomorrow:
            let startOfToday = calendar.startOfDay(for: date)
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? date
            let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow
            return DateInterval(start: startOfTomorrow, end: endOfTomorrow)
        case .week:
            let endOfRange = calendar.date(byAdding: .day, value: 7, to: date) ?? date
            return DateInterval(start: date, end: endOfRange)
        }
    }
}

struct PaceCalendarEventRequest {
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let notes: String?
    let location: String?
    let calendarTitle: String?

    var displaySummary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = isAllDay ? .none : .short

        let timeSummary: String
        if isAllDay {
            timeSummary = formatter.string(from: startDate)
        } else {
            timeSummary = "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
        }

        return "\(title) (\(timeSummary))"
    }
}

enum PaceCalendarRange: String, Equatable {
    case today
    case tomorrow
    case week

    var displayName: String {
        switch self {
        case .today: return "today"
        case .tomorrow: return "tomorrow"
        case .week: return "the next 7 days"
        }
    }
}

struct PaceReminderRequest {
    let title: String
    let notes: String?
}

struct PaceFinderRequest {
    let path: String
    let action: PaceFinderAction
}

enum PaceFinderAction: String, Equatable {
    case open
    case reveal
}

struct PaceNoteRequest {
    let title: String
    let body: String
}

struct PaceMailDraft {
    let recipients: [String]
    let subject: String
    let body: String
}

private struct PaceStreamingMailDraftState {
    let lastWrittenSnapshot: PaceStreamingMailDraftSnapshot
    let pendingSnapshot: PaceStreamingMailDraftSnapshot?
    let lastWriteDate: Date

    func withPendingSnapshot(
        _ pendingSnapshot: PaceStreamingMailDraftSnapshot
    ) -> PaceStreamingMailDraftState {
        PaceStreamingMailDraftState(
            lastWrittenSnapshot: lastWrittenSnapshot,
            pendingSnapshot: pendingSnapshot,
            lastWriteDate: lastWriteDate
        )
    }
}

struct PaceThingsToDoRequest {
    let title: String
    let notes: String?
}

struct PaceMessageRequest {
    let recipient: String?
    let text: String?
}

// MARK: - Action tag parser

/// Result of pulling all action tags out of Claude's response.
struct PaceActionTagParseResult {
    /// The assistant text with every recognised action tag stripped.
    /// Safe to feed to TTS.
    let spokenText: String
    /// The parsed actions, in the order they appeared in the response.
    let actions: [PaceParsedAction]
    /// Grouped tool-call plan. Outer steps run sequentially; actions
    /// within one step are the model's requested parallel group.
    let executionPlan: PaceActionExecutionPlan
    /// The first click/double-click coordinate, if any — used by the
    /// existing cursor-flight visualization so the user sees pace
    /// move to the target before it executes.
    let firstClickVisualisationLocation: ScreenshotPixelLocation?
}

struct PaceFastActionParseResult {
    let spokenText: String
    let executionPlan: PaceActionExecutionPlan
}

/// Deterministic parser for no-screen, no-reasoning commands that are common
/// enough to execute without burning a VLM/planner turn. It intentionally
/// avoids clicks, typing, scrolling, and open-ended app names; those stay on
/// the normal planner path where screen context and approval copy are richer.
enum PaceFastActionCommandParser {
    private static let knownApplicationAliases: [String: String] = [
        "arc": "Arc",
        "calendar": "Calendar",
        "chrome": "Google Chrome",
        "cursor": "Cursor",
        "discord": "Discord",
        "facetime": "FaceTime",
        "figma": "Figma",
        "finder": "Finder",
        "firefox": "Firefox",
        "google chrome": "Google Chrome",
        "iterm": "iTerm",
        "iterm2": "iTerm",
        "linear": "Linear",
        "mail": "Mail",
        "messages": "Messages",
        "music": "Music",
        "notes": "Notes",
        "notion": "Notion",
        "obsidian": "Obsidian",
        "photos": "Photos",
        "preview": "Preview",
        "raycast": "Raycast",
        "reminders": "Reminders",
        "safari": "Safari",
        "settings": "System Settings",
        "slack": "Slack",
        "spotify": "Spotify",
        "system settings": "System Settings",
        "terminal": "Terminal",
        "visual studio code": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "xcode": "Xcode",
        "zoom": "zoom.us"
    ]

    static func parse(transcript: String) -> PaceFastActionParseResult? {
        let normalizedTranscript = normalizeTranscript(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        if let musicCommand = parseMusicCommand(from: normalizedTranscript) {
            let spokenText = spokenTextForMusicCommand(musicCommand)
            return PaceFastActionParseResult(
                spokenText: spokenText,
                executionPlan: .serial(actions: [.controlMusic(musicCommand)])
            )
        }

        if isUndoCommand(normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "undoing that.",
                executionPlan: .serial(actions: [.undoLastMutation])
            )
        }

        if let voiceEditRequest = PaceVoiceEditProcessor.parseCommand(normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "editing selection.",
                executionPlan: .serial(actions: [.editSelectedText(voiceEditRequest)])
            )
        }

        if let keyPress = parseKeyPressCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: keyPress.spokenText,
                executionPlan: .serial(actions: [.pressKey(name: keyPress.keyName, modifiers: keyPress.modifiers)])
            )
        }

        if let snapWindowRequest = parseWindowSnapCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "moving the window.",
                executionPlan: .serial(actions: [.snapWindow(snapWindowRequest)])
            )
        }

        if let messageRequest = parseOpenMessagesCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: messageRequest.recipient?.isEmpty == false
                    ? "opening Messages for \(messageRequest.recipient!)."
                    : "opening Messages.",
                executionPlan: .serial(actions: [.openMessages(messageRequest)])
            )
        }

        if let volumeAdjustment = parseSystemAdjustment(
            from: normalizedTranscript,
            noun: "volume"
        ) {
            return PaceFastActionParseResult(
                spokenText: "adjusting volume.",
                executionPlan: .serial(actions: [.adjustVolume(volumeAdjustment)])
            )
        }

        if let brightnessAdjustment = parseSystemAdjustment(
            from: normalizedTranscript,
            noun: "brightness"
        ) {
            return PaceFastActionParseResult(
                spokenText: "adjusting brightness.",
                executionPlan: .serial(actions: [.adjustBrightness(brightnessAdjustment)])
            )
        }

        if let urlString = parseURLCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "opening \(urlString).",
                executionPlan: .serial(actions: [.openURL(urlString)])
            )
        }

        if let applicationName = parseKnownApplicationCommand(from: normalizedTranscript) {
            return PaceFastActionParseResult(
                spokenText: "opening \(applicationName).",
                executionPlan: .serial(actions: [.openApplication(applicationName)])
            )
        }

        return nil
    }

    private static func normalizeTranscript(_ transcript: String) -> String {
        var normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for wakePrefix in ["hey pace ", "pace ", "ok pace ", "okay pace "] {
            if normalizedTranscript.hasPrefix(wakePrefix) {
                normalizedTranscript.removeFirst(wakePrefix.count)
                break
            }
        }

        return normalizedTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
    }

    private static func isUndoCommand(_ normalizedTranscript: String) -> Bool {
        switch normalizedTranscript {
        case "undo that", "undo last", "undo the last thing", "revert that", "revert last", "change it back":
            return true
        default:
            return false
        }
    }

    private struct FastKeyPressCommand {
        let keyName: String
        let modifiers: [PaceKeyboardModifier]
        let spokenText: String
    }

    private static func parseKeyPressCommand(from normalizedTranscript: String) -> FastKeyPressCommand? {
        switch normalizedTranscript {
        case "save", "save this", "save file", "save the file", "press command s", "press cmd s", "command s", "cmd s", "hit command s":
            return FastKeyPressCommand(
                keyName: "s",
                modifiers: [.command],
                spokenText: "saving."
            )
        case "new tab", "open new tab", "open a new tab", "press command t", "press cmd t", "command t", "cmd t":
            return FastKeyPressCommand(
                keyName: "t",
                modifiers: [.command],
                spokenText: "opening a new tab."
            )
        case "close tab", "close this tab", "close the tab", "press command w", "press cmd w", "command w", "cmd w":
            return FastKeyPressCommand(
                keyName: "w",
                modifiers: [.command],
                spokenText: "closing the tab."
            )
        case "reopen closed tab", "reopen the closed tab", "reopen last closed tab", "press command shift t", "press cmd shift t", "command shift t", "cmd shift t":
            return FastKeyPressCommand(
                keyName: "t",
                modifiers: [.command, .shift],
                spokenText: "reopening the tab."
            )
        default:
            return nil
        }
    }

    private static func parseWindowSnapCommand(from normalizedTranscript: String) -> PaceWindowSnapRequest? {
        let position: PaceWindowSnapPosition
        switch normalizedTranscript {
        case "snap window left", "move window left", "put window left", "put the window left", "move the window left", "snap the window left", "resize window left", "left half window", "window left half":
            position = .left
        case "snap window right", "move window right", "put window right", "put the window right", "move the window right", "snap the window right", "resize window right", "right half window", "window right half":
            position = .right
        case "snap window top", "move window top", "put window top", "put the window top", "move the window top", "snap the window top", "top half window", "window top half":
            position = .top
        case "snap window bottom", "move window bottom", "put window bottom", "put the window bottom", "move the window bottom", "snap the window bottom", "bottom half window", "window bottom half":
            position = .bottom
        case "maximize window", "maximize the window", "make window full size", "make the window full size":
            position = .maximize
        case "center window", "center the window", "move window center", "move the window center":
            position = .center
        default:
            return nil
        }

        return PaceWindowSnapRequest(position: position)
    }

    private static func parseOpenMessagesCommand(from normalizedTranscript: String) -> PaceMessageRequest? {
        guard !messageCommandContainsBodyOrSendIntent(normalizedTranscript) else { return nil }

        if normalizedTranscript == "open messages"
            || normalizedTranscript == "open messages app"
            || normalizedTranscript == "launch messages" {
            return PaceMessageRequest(recipient: nil, text: nil)
        }

        let recipientPrefixes = [
            "open messages to ",
            "open message to ",
            "open messages with ",
            "open message with ",
            "message "
        ]

        for recipientPrefix in recipientPrefixes {
            guard normalizedTranscript.hasPrefix(recipientPrefix) else { continue }
            let rawRecipientName = String(normalizedTranscript.dropFirst(recipientPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let recipientName = normalizedRecipientName(rawRecipientName) else { return nil }
            return PaceMessageRequest(recipient: recipientName, text: nil)
        }

        return nil
    }

    private static func messageCommandContainsBodyOrSendIntent(_ normalizedTranscript: String) -> Bool {
        let blockedFragments = [
            " saying ",
            " say ",
            " that ",
            " telling ",
            " tell ",
            " about ",
            " with text ",
            " body ",
            "send message",
            "send a message",
            "text "
        ]
        return blockedFragments.contains { normalizedTranscript.contains($0) }
    }

    private static func normalizedRecipientName(_ rawRecipientName: String) -> String? {
        guard !rawRecipientName.isEmpty else { return nil }
        guard rawRecipientName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\{}[]<>")) == nil else {
            return nil
        }

        let words = rawRecipientName
            .split(separator: " ")
            .map { word in
                let lowercasedWord = word.lowercased()
                guard let firstCharacter = lowercasedWord.first else { return "" }
                return firstCharacter.uppercased() + lowercasedWord.dropFirst()
            }
        let recipientName = words.joined(separator: " ")
        return recipientName.isEmpty ? nil : recipientName
    }

    private static func parseMusicCommand(from normalizedTranscript: String) -> PaceMusicCommand? {
        switch normalizedTranscript {
        case "play music", "start music", "resume music", "play the music":
            return .play
        case "pause music", "stop music", "pause the music":
            return .pause
        case "toggle music", "play pause music", "play or pause music":
            return .playPause
        case "next song", "next track", "skip song", "skip track", "music next":
            return .next
        case "previous song", "previous track", "last song", "last track", "music previous":
            return .previous
        default:
            return nil
        }
    }

    private static func spokenTextForMusicCommand(_ musicCommand: PaceMusicCommand) -> String {
        switch musicCommand {
        case .play:
            return "playing music."
        case .pause:
            return "pausing music."
        case .playPause:
            return "toggling music."
        case .next:
            return "skipping ahead."
        case .previous:
            return "going back."
        }
    }

    private static func parseSystemAdjustment(
        from normalizedTranscript: String,
        noun: String
    ) -> PaceSystemAdjustment? {
        let direction: PaceAdjustmentDirection
        if normalizedTranscript == "\(noun) up"
            || normalizedTranscript == "turn \(noun) up"
            || normalizedTranscript == "turn the \(noun) up"
            || normalizedTranscript == "increase \(noun)"
            || normalizedTranscript == "raise \(noun)"
            || normalizedTranscript == "make \(noun) louder"
            || normalizedTranscript == "make the \(noun) louder"
            || normalizedTranscript.hasPrefix("\(noun) up ")
            || normalizedTranscript.hasPrefix("turn \(noun) up ")
            || normalizedTranscript.hasPrefix("turn the \(noun) up ") {
            direction = .up
        } else if normalizedTranscript == "\(noun) down"
            || normalizedTranscript == "turn \(noun) down"
            || normalizedTranscript == "turn the \(noun) down"
            || normalizedTranscript == "decrease \(noun)"
            || normalizedTranscript == "lower \(noun)"
            || normalizedTranscript == "make \(noun) quieter"
            || normalizedTranscript == "make the \(noun) quieter"
            || normalizedTranscript.hasPrefix("\(noun) down ")
            || normalizedTranscript.hasPrefix("turn \(noun) down ")
            || normalizedTranscript.hasPrefix("turn the \(noun) down ") {
            direction = .down
        } else {
            return nil
        }

        return PaceSystemAdjustment(
            direction: direction,
            stepCount: parseStepCount(from: normalizedTranscript)
        )
    }

    private static func parseStepCount(from normalizedTranscript: String) -> Int {
        let tokens = normalizedTranscript
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard let requestedStepCount = tokens.first else { return 2 }
        return max(1, min(requestedStepCount, 10))
    }

    private static func parseURLCommand(from normalizedTranscript: String) -> String? {
        for prefix in ["open ", "go to ", "visit ", "navigate to "] {
            guard normalizedTranscript.hasPrefix(prefix) else { continue }
            let rawURLTarget = String(normalizedTranscript.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedURLString(from: rawURLTarget)
        }
        return nil
    }

    private static func normalizedURLString(from rawURLTarget: String) -> String? {
        guard !rawURLTarget.isEmpty, !rawURLTarget.contains(" ") else { return nil }
        if rawURLTarget.hasPrefix("http://") || rawURLTarget.hasPrefix("https://") {
            return rawURLTarget
        }
        guard rawURLTarget.contains(".") else { return nil }
        return "https://\(rawURLTarget)"
    }

    private static func parseKnownApplicationCommand(from normalizedTranscript: String) -> String? {
        let candidateApplicationName: String?
        if normalizedTranscript.hasPrefix("open app ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("open app ".count))
        } else if normalizedTranscript.hasPrefix("open application ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("open application ".count))
        } else if normalizedTranscript.hasPrefix("open ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("open ".count))
        } else if normalizedTranscript.hasPrefix("launch ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("launch ".count))
        } else if normalizedTranscript.hasPrefix("start ") {
            candidateApplicationName = String(normalizedTranscript.dropFirst("start ".count))
        } else {
            candidateApplicationName = nil
        }

        guard let candidateApplicationName else { return nil }
        let normalizedCandidate = candidateApplicationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return knownApplicationAliases[normalizedCandidate]
    }
}

enum PaceActionTagParser {
    private struct PlannerResponseDTO: Decodable {
        let spokenText: String?
        let intent: String?
        let payload: [String: PaceMCPJSONValue]?
    }

    private struct ToolCallDTO: Decodable {
        let tool: String
        let app: String?
        let name: String?
        let url: String?
        let command: String?
        let direction: String?
        let title: String?
        let query: String?
        let text: String?
        let body: String?
        let notes: String?
        let range: String?
        let key: String?
        let path: String?
        let action: String?
        let to: String?
        let subject: String?
        let recipient: String?
        let server: String?
        let toolName: String?
        let mcpTool: String?
        let arguments: [String: PaceMCPJSONValue]
        let extraArguments: [String: PaceMCPJSONValue]
        let steps: Int?
        let amount: Int?
        let x: Int?
        let y: Int?
        let screen: Int?
        let candidates: [ClickCandidateDTO]
        let expectStateChange: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case tool, app, name, url, command, direction, title, query, text, body, notes, range, key, path, action, to, subject, recipient, server, toolName, mcpTool, arguments, steps, amount, x, y, screen, candidates, expectStateChange
        }

        struct ClickCandidateDTO: Decodable {
            let x: Int?
            let y: Int?
            let screen: Int?
            let label: String?
            let confidence: Double?
            let expectStateChange: Bool?
            let recencyRank: Int?
            let lastSeenMillisecondsAgo: Double?

            enum CodingKeys: String, CodingKey {
                case x, y, screen, label, confidence, expectStateChange
                case recencyRank, recentRank, lastSeenMillisecondsAgo, lastSeenMsAgo, observedMillisecondsAgo, observedMsAgo
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.x = Self.decodeIntIfPresent(from: container, forKey: .x)
                self.y = Self.decodeIntIfPresent(from: container, forKey: .y)
                self.screen = Self.decodeIntIfPresent(from: container, forKey: .screen)
                self.label = Self.decodeStringIfPresent(from: container, forKey: .label)
                self.confidence = try? container.decodeIfPresent(Double.self, forKey: .confidence)
                self.expectStateChange = try? container.decodeIfPresent(Bool.self, forKey: .expectStateChange)
                self.recencyRank = Self.firstDecodedInt(
                    from: container,
                    keys: [.recencyRank, .recentRank]
                )
                self.lastSeenMillisecondsAgo = Self.firstDecodedDouble(
                    from: container,
                    keys: [.lastSeenMillisecondsAgo, .lastSeenMsAgo, .observedMillisecondsAgo, .observedMsAgo]
                )
            }

            private static func decodeStringIfPresent(
                from container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> String? {
                if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                    return stringValue
                }
                if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return String(intValue)
                }
                return nil
            }

            private static func decodeIntIfPresent(
                from container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> Int? {
                if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return intValue
                }
                if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return nil
            }

            private static func firstDecodedInt(
                from container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> Int? {
                for key in keys {
                    if let intValue = decodeIntIfPresent(from: container, forKey: key) {
                        return intValue
                    }
                }
                return nil
            }

            private static func decodeDoubleIfPresent(
                from container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> Double? {
                if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
                    return doubleValue
                }
                if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return Double(intValue)
                }
                if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return nil
            }

            private static func firstDecodedDouble(
                from container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> Double? {
                for key in keys {
                    if let doubleValue = decodeDoubleIfPresent(from: container, forKey: key) {
                        return doubleValue
                    }
                }
                return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawContainer = try decoder.container(keyedBy: PaceMCPDynamicCodingKey.self)
            self.tool = try container.decode(String.self, forKey: .tool)
            self.app = Self.decodeStringIfPresent(from: container, forKey: .app)
            self.name = Self.decodeStringIfPresent(from: container, forKey: .name)
            self.url = Self.decodeStringIfPresent(from: container, forKey: .url)
            self.command = Self.decodeStringIfPresent(from: container, forKey: .command)
            self.direction = Self.decodeStringIfPresent(from: container, forKey: .direction)
            self.title = Self.decodeStringIfPresent(from: container, forKey: .title)
            self.query = Self.decodeStringIfPresent(from: container, forKey: .query)
            self.text = Self.decodeStringIfPresent(from: container, forKey: .text)
            self.body = Self.decodeStringIfPresent(from: container, forKey: .body)
            self.notes = Self.decodeStringIfPresent(from: container, forKey: .notes)
            self.range = Self.decodeStringIfPresent(from: container, forKey: .range)
            self.key = Self.decodeStringIfPresent(from: container, forKey: .key)
            self.path = Self.decodeStringIfPresent(from: container, forKey: .path)
            self.action = Self.decodeStringIfPresent(from: container, forKey: .action)
            self.to = Self.decodeStringIfPresent(from: container, forKey: .to)
            self.subject = Self.decodeStringIfPresent(from: container, forKey: .subject)
            self.recipient = Self.decodeStringIfPresent(from: container, forKey: .recipient)
            self.server = Self.decodeStringIfPresent(from: container, forKey: .server)
            self.toolName = Self.decodeStringIfPresent(from: container, forKey: .toolName)
            self.mcpTool = Self.decodeStringIfPresent(from: container, forKey: .mcpTool)
            self.arguments = (try? container.decodeIfPresent([String: PaceMCPJSONValue].self, forKey: .arguments)) ?? [:]
            self.steps = Self.decodeIntIfPresent(from: container, forKey: .steps)
            self.amount = Self.decodeIntIfPresent(from: container, forKey: .amount)
            self.x = Self.decodeIntIfPresent(from: container, forKey: .x)
            self.y = Self.decodeIntIfPresent(from: container, forKey: .y)
            self.screen = Self.decodeIntIfPresent(from: container, forKey: .screen)
            self.candidates = (try? container.decodeIfPresent([ClickCandidateDTO].self, forKey: .candidates)) ?? []
            self.expectStateChange = try? container.decodeIfPresent(Bool.self, forKey: .expectStateChange)
            self.extraArguments = Self.decodeExtraArguments(from: rawContainer)
        }

        private static func decodeStringIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> String? {
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                return stringValue
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(intValue)
            }
            return nil
        }

        private static func decodeIntIfPresent(
            from container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intValue
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        private static func decodeExtraArguments(
            from container: KeyedDecodingContainer<PaceMCPDynamicCodingKey>
        ) -> [String: PaceMCPJSONValue] {
            let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
            var extraArguments: [String: PaceMCPJSONValue] = [:]

            for key in container.allKeys where !knownKeys.contains(key.stringValue) {
                if let value = try? container.decode(PaceMCPJSONValue.self, forKey: key) {
                    extraArguments[key.stringValue] = value
                }
            }

            return extraArguments
        }
    }

    private struct PaceMCPDynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    /// Tag formats supported (case-insensitive on tag name):
    ///   [CLICK:x,y]                or [CLICK:x,y:screen2]
    ///   [DOUBLE_CLICK:x,y]         or [DOUBLE_CLICK:x,y:screen2]
    ///   [TYPE:hello world]
    ///   [KEY:Return]               or [KEY:cmd+s]   or [KEY:cmd+shift+t]
    ///   [SCROLL:up:3]              or [SCROLL:down:5]
    ///   [OPEN_APP:Safari]
    ///   [VOLUME:up:2]              or [VOLUME:down]
    ///   [BRIGHTNESS:up]            or [BRIGHTNESS:down:3]
    ///
    /// Preferred grouped format:
    ///   <tool_calls>
    ///   [[{"tool":"open_app","app":"Music"},{"tool":"music","command":"play"}]]
    ///   </tool_calls>
    ///
    /// Order of tags in the response is preserved in the returned actions array.
    static func parseActions(from responseText: String) -> PaceActionTagParseResult {
        if let plannerResponseParseResult = parsePlannerResponseJSON(from: responseText) {
            return plannerResponseParseResult
        }

        let (toolCallSteps, responseTextWithoutToolCallBlocks) = parseToolCallBlocks(in: responseText)

        // One regex that matches any of the supported tag shapes. We use a
        // single pass so we can walk matches in source order. Group 1 is the
        // tag name; group 2 is the everything-after-the-colon payload.
        let actionTagPattern = #"\[(CLICK|DOUBLE_CLICK|TYPE|KEY|SCROLL|OPEN_APP|OPEN_URL|MUSIC|VOLUME|BRIGHTNESS|CALENDAR|REMINDER):([^\]]+)\]"#

        guard let actionTagRegex = try? NSRegularExpression(
            pattern: actionTagPattern,
            options: [.caseInsensitive]
        ) else {
            let allActions = toolCallSteps.flatMap(\.actions)
            return PaceActionTagParseResult(
                spokenText: responseTextWithoutToolCallBlocks,
                actions: allActions,
                executionPlan: PaceActionExecutionPlan(steps: toolCallSteps),
                firstClickVisualisationLocation: firstClickVisualisationLocation(in: allActions)
            )
        }

        let entireRange = NSRange(responseTextWithoutToolCallBlocks.startIndex..., in: responseTextWithoutToolCallBlocks)
        let matches = actionTagRegex.matches(in: responseTextWithoutToolCallBlocks, options: [], range: entireRange)

        var parsedActions: [PaceParsedAction] = []
        var spokenTextWithoutActionTags = responseTextWithoutToolCallBlocks

        // Build spoken text by removing matches in reverse so ranges stay valid.
        let matchesInForwardOrder = matches
        let matchesInReverseOrder = matches.reversed()

        for match in matchesInForwardOrder {
            guard let fullRange = Range(match.range, in: responseTextWithoutToolCallBlocks),
                  let nameRange = Range(match.range(at: 1), in: responseTextWithoutToolCallBlocks),
                  let payloadRange = Range(match.range(at: 2), in: responseTextWithoutToolCallBlocks) else {
                continue
            }
            let tagName = String(responseTextWithoutToolCallBlocks[nameRange]).uppercased()
            let payload = String(responseTextWithoutToolCallBlocks[payloadRange])

            if let parsedAction = parseSingleAction(tagName: tagName, payload: payload) {
                parsedActions.append(parsedAction)
            }
            _ = fullRange // silence unused warning; we use it via the reverse loop below
        }

        for match in matchesInReverseOrder {
            guard let fullRange = Range(match.range, in: spokenTextWithoutActionTags) else { continue }
            spokenTextWithoutActionTags.removeSubrange(fullRange)
        }

        let cleanedSpokenText = spokenTextWithoutActionTags
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let executionSteps = toolCallSteps + parsedActions.map { PaceActionExecutionStep(actions: [$0]) }
        let allActions = executionSteps.flatMap(\.actions)

        return PaceActionTagParseResult(
            spokenText: cleanedSpokenText,
            actions: allActions,
            executionPlan: PaceActionExecutionPlan(steps: executionSteps),
            firstClickVisualisationLocation: firstClickVisualisationLocation(in: allActions)
        )
    }

    private static func parsePlannerResponseJSON(from responseText: String) -> PaceActionTagParseResult? {
        let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedResponseText.hasPrefix("{"), trimmedResponseText.hasSuffix("}") else {
            return nil
        }
        guard let responseData = trimmedResponseText.data(using: .utf8),
              let plannerResponseObject = try? JSONDecoder().decode([String: PaceMCPJSONValue].self, from: responseData) else {
            return nil
        }
        guard plannerResponseObject.keys.contains(where: { ["spokenText", "intent", "payload"].contains($0) }) else {
            return nil
        }

        let envelopeValidationIssues = validatePlannerResponseEnvelope(plannerResponseObject)
        guard envelopeValidationIssues.isEmpty else {
            print("⚠️ Rejected invalid v10 planner response before execution: \(envelopeValidationIssues.joined(separator: "; "))")
            return PaceActionTagParseResult(
                spokenText: strictStringValue(for: "spokenText", in: plannerResponseObject) ?? "",
                actions: [],
                executionPlan: PaceActionExecutionPlan(steps: []),
                firstClickVisualisationLocation: nil
            )
        }

        guard let plannerResponse = try? JSONDecoder().decode(PlannerResponseDTO.self, from: responseData) else {
            return nil
        }

        let spokenText = plannerResponse.spokenText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedIntent = plannerResponse.intent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let payload = plannerResponse.payload,
              let plannerActions = parsePlannerActions(intent: normalizedIntent, payload: payload),
              !plannerActions.isEmpty else {
            return PaceActionTagParseResult(
                spokenText: spokenText,
                actions: [],
                executionPlan: PaceActionExecutionPlan(steps: []),
                firstClickVisualisationLocation: nil
            )
        }

        let executionPlan = PaceActionExecutionPlan.serial(actions: plannerActions)
        return PaceActionTagParseResult(
            spokenText: spokenText,
            actions: plannerActions,
            executionPlan: executionPlan,
            firstClickVisualisationLocation: firstClickVisualisationLocation(in: plannerActions)
        )
    }

    private static func validatePlannerResponseEnvelope(
        _ plannerResponseObject: [String: PaceMCPJSONValue]
    ) -> [String] {
        let allowedTopLevelKeys = Set(["spokenText", "intent", "payload"])
        var issues: [String] = []

        for unexpectedKey in Set(plannerResponseObject.keys).subtracting(allowedTopLevelKeys).sorted() {
            issues.append("unexpected top-level key \(unexpectedKey)")
        }

        guard strictStringValue(for: "spokenText", in: plannerResponseObject) != nil else {
            issues.append("spokenText must be a string")
            return issues
        }

        guard let rawIntent = strictStringValue(for: "intent", in: plannerResponseObject) else {
            issues.append("intent must be a string")
            return issues
        }

        let normalizedIntent = rawIntent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowedIntents = Set(["answer", "action", "dictate", "edit", "clarify", "refuse"])
        guard allowedIntents.contains(normalizedIntent) else {
            issues.append("intent must be one of \(allowedIntents.sorted().joined(separator: ", "))")
            return issues
        }

        let payload = objectValue(for: "payload", in: plannerResponseObject)
        if plannerResponseObject["payload"] != nil && payload == nil {
            issues.append("payload must be an object")
        }

        guard let payload else {
            if normalizedIntent == "action" {
                issues.append("action intent requires payload")
            }
            return issues
        }

        issues.append(contentsOf: validatePlannerResponsePayload(payload, intent: normalizedIntent))
        return issues
    }

    private static func validatePlannerResponsePayload(
        _ payload: [String: PaceMCPJSONValue],
        intent normalizedIntent: String
    ) -> [String] {
        var issues: [String] = []

        for key in ["name", "answer", "text", "replacement", "command"] {
            if payload[key] != nil && strictStringValue(for: key, in: payload) == nil {
                issues.append("payload.\(key) must be a string")
            }
        }

        if let target = strictStringValue(for: "target", in: payload),
           !["focused", "selection"].contains(target.lowercased()) {
            issues.append("payload.target must be focused or selection")
        } else if payload["target"] != nil && strictStringValue(for: "target", in: payload) == nil {
            issues.append("payload.target must be a string")
        }

        if payload["args"] != nil && objectValue(for: "args", in: payload) == nil {
            issues.append("payload.args must be an object")
        }

        if let callsIssue = validatePlannerResponseCallsPayload(payload["calls"]) {
            issues.append(contentsOf: callsIssue)
        }

        if normalizedIntent == "action" {
            let hasSingleActionName = strictStringValue(for: "name", in: payload) != nil
            let hasCalls = payload["calls"] != nil && validatePlannerResponseCallsPayload(payload["calls"]) == nil
            if !hasSingleActionName && !hasCalls {
                issues.append("action payload requires name or calls")
            }
        }

        return issues
    }

    private static func validatePlannerResponseCallsPayload(
        _ callsValue: PaceMCPJSONValue?
    ) -> [String]? {
        guard let callsValue else { return nil }
        guard case .array(let calls) = callsValue else {
            return ["payload.calls must be an array"]
        }

        var issues: [String] = []
        let allowedCallKeys = Set(["name", "args"])
        for (index, callValue) in calls.enumerated() {
            guard case .object(let callObject) = callValue else {
                issues.append("payload.calls[\(index)] must be an object")
                continue
            }

            for unexpectedKey in Set(callObject.keys).subtracting(allowedCallKeys).sorted() {
                issues.append("payload.calls[\(index)] unexpected key \(unexpectedKey)")
            }

            if strictStringValue(for: "name", in: callObject) == nil {
                issues.append("payload.calls[\(index)].name must be a string")
            }
            if callObject["args"] != nil && objectValue(for: "args", in: callObject) == nil {
                issues.append("payload.calls[\(index)].args must be an object")
            }
        }

        return issues.isEmpty ? nil : issues
    }

    private static func parsePlannerActions(
        intent normalizedIntent: String?,
        payload: [String: PaceMCPJSONValue]
    ) -> [PaceParsedAction]? {
        switch normalizedIntent {
        case "action":
            if let calls = actionCallObjects(from: payload) {
                return calls.compactMap(parsePlannerActionCall)
            }
            return parsePlannerActionCall(payload).map { [$0] }
        case "dictate":
            let dictatedText = firstStringValue(for: ["text", "body", "value"], in: payload)
            guard let dictatedText, !dictatedText.isEmpty else { return [] }
            let processedDictatedText = PaceDictationPostProcessor.process(
                rawText: dictatedText,
                mode: firstStringValue(for: ["mode"], in: payload)
            )
            guard !processedDictatedText.isEmpty else { return [] }
            return [.type(processedDictatedText)]
        case "edit":
            let replacementText = firstStringValue(for: ["replacement", "text", "value"], in: payload)
            if let replacementText, !replacementText.isEmpty {
                let target = parseSetTextValueTarget(
                    firstStringValue(for: ["target"], in: payload)
                ) ?? .selection
                return [.setTextValue(PaceSetTextValueRequest(
                    value: replacementText,
                    target: target
                ))]
            }

            if let editCommand = firstStringValue(for: ["command", "instruction", "operation"], in: payload),
               let voiceEditRequest = PaceVoiceEditProcessor.parseCommand(editCommand) {
                return [.editSelectedText(voiceEditRequest)]
            }

            return []
        default:
            return []
        }
    }

    private static func parsePlannerActionCall(_ actionCall: [String: PaceMCPJSONValue]) -> PaceParsedAction? {
        guard let actionName = stringValue(for: "name", in: actionCall) else { return nil }
        let actionArguments = objectValue(for: "args", in: actionCall) ?? [:]
        let validationIssues = validateParameterizedActionCall(name: actionName, arguments: actionArguments)
        guard validationIssues.isEmpty else {
            print("⚠️ Rejected invalid \(actionName) planner action before execution: \(validationIssues.joined(separator: "; "))")
            return nil
        }
        return parseParameterizedAction(name: actionName, arguments: actionArguments)
    }

    private static func actionCallObjects(from payload: [String: PaceMCPJSONValue]) -> [[String: PaceMCPJSONValue]]? {
        guard case .array(let callsValue)? = payload["calls"] else { return nil }
        return callsValue.compactMap { callValue in
            guard case .object(let callObject) = callValue else { return nil }
            return callObject
        }
    }

    private static func parseParameterizedAction(
        name rawActionName: String,
        arguments: [String: PaceMCPJSONValue]
    ) -> PaceParsedAction? {
        let normalizedActionName = normalizedParameterizedActionName(rawActionName)

        switch normalizedActionName {
        case "app.launch", "app.open", "open.app":
            let applicationName = firstStringValue(for: ["name", "app"], in: arguments)
            return applicationName.map { .openApplication($0) }
        case "app.openurl", "open.url", "url.open":
            let urlString = firstStringValue(for: ["url", "text"], in: arguments)
            return urlString.map { .openURL($0) }
        case "ax.press", "click", "mouse.click":
            if let clickCandidateSet = parseClickCandidateSet(fromParameterizedArguments: arguments, clickCount: 1) {
                return .clickCandidates(clickCandidateSet)
            }
            if let location = screenshotPixelLocation(from: arguments) {
                return .click(location)
            }
            return nil
        case "ax.doublepress", "double.click", "mouse.doubleclick":
            if let clickCandidateSet = parseClickCandidateSet(fromParameterizedArguments: arguments, clickCount: 2) {
                return .clickCandidates(clickCandidateSet)
            }
            if let location = screenshotPixelLocation(from: arguments) {
                return .doubleClick(location)
            }
            return nil
        case "ax.setvalue":
            let value = firstStringValue(for: ["value", "text", "body"], in: arguments)
            guard let value, !value.isEmpty else { return nil }
            let target = parseSetTextValueTarget(
                firstStringValue(for: ["target"], in: arguments)
            ) ?? .focused
            return .setTextValue(PaceSetTextValueRequest(
                value: value,
                target: target
            ))
        case "type", "keyboard.type":
            let text = firstStringValue(for: ["value", "text", "body"], in: arguments)
            guard let text, !text.isEmpty else { return nil }
            return .type(text)
        case "undo.last", "undo", "undo.lastmutation":
            return .undoLastMutation
        case "key.press", "keyboard.press":
            let key = firstStringValue(for: ["key", "name", "command"], in: arguments) ?? ""
            return parseKeyPayload(key)
        case "clipboard.read", "clipboard":
            return .readClipboard
        case "window.snap", "window.move", "window.resize":
            return parseWindowSnapRequest(from: arguments)
                .map { .snapWindow($0) }
        case "ax.scroll":
            let direction = stringValue(for: "direction", in: arguments) ?? "down"
            let amount = intValue(for: "amount", in: arguments)
                ?? intValue(for: "steps", in: arguments)
                ?? 3
            return parseScrollPayload("\(direction):\(amount)")
        case "music.control", "music":
            let command = firstStringValue(for: ["command", "name"], in: arguments) ?? ""
            return parseMusicPayload(command)
        case "volume.adjust", "volume":
            return parseSystemAdjustmentPayloadFromParameterizedArguments(arguments)
                .map { .adjustVolume($0) }
        case "brightness.adjust", "brightness":
            return parseSystemAdjustmentPayloadFromParameterizedArguments(arguments)
                .map { .adjustBrightness($0) }
        case "calendar.read", "calendar.list":
            let range = firstStringValue(for: ["range", "when"], in: arguments) ?? "today"
            return parseCalendarPayload(range)
        case "calendar.createevent", "calendar.create", "calendar.add", "cal.event":
            return parseCalendarEventRequest(from: arguments)
                .map { .createCalendarEvent($0) }
        case "reminders.add", "reminder.add":
            let title = firstStringValue(for: ["title", "text", "name"], in: arguments)
            guard let title, !title.isEmpty else { return nil }
            return .createReminder(PaceReminderRequest(
                title: title,
                notes: stringValue(for: "notes", in: arguments)
            ))
        case "notes.create", "note.create":
            let title = firstStringValue(for: ["title", "name"], in: arguments) ?? "Pace note"
            let body = firstStringValue(for: ["body", "text", "notes"], in: arguments) ?? ""
            guard !title.isEmpty || !body.isEmpty else { return nil }
            return .createNote(PaceNoteRequest(
                title: title.isEmpty ? "Pace note" : title,
                body: body
            ))
        case "notes.append", "note.append":
            let title = firstStringValue(for: ["title", "name"], in: arguments) ?? "Pace note"
            let body = firstStringValue(for: ["body", "text", "notes"], in: arguments) ?? ""
            guard !title.isEmpty || !body.isEmpty else { return nil }
            return .appendNote(PaceNoteRequest(
                title: title.isEmpty ? "Pace note" : title,
                body: body
            ))
        case "notes.search", "note.search":
            let query = firstStringValue(for: ["query", "text", "title", "name"], in: arguments)
            guard let query, !query.isEmpty else { return nil }
            return .searchNotes(query)
        case "mail.draft", "mail.compose":
            let recipients = stringArrayValue(for: "to", in: arguments)
                + stringArrayValue(for: "recipients", in: arguments)
                + stringArrayValue(for: "recipient", in: arguments)
            let subject = firstStringValue(for: ["subject", "title"], in: arguments) ?? ""
            let body = firstStringValue(for: ["body", "text", "bodyText"], in: arguments) ?? ""
            guard !recipients.isEmpty || !subject.isEmpty || !body.isEmpty else { return nil }
            return .composeMail(PaceMailDraft(
                recipients: recipients,
                subject: subject.isEmpty ? "Untitled" : subject,
                body: body
            ))
        case "shortcut.run", "shortcuts.run":
            let shortcutName = firstStringValue(for: ["name", "title", "shortcut"], in: arguments)
            return shortcutName.map { .runShortcut($0) }
        case "things.create", "things.add":
            let title = firstStringValue(for: ["title", "text", "name"], in: arguments)
            guard let title, !title.isEmpty else { return nil }
            return .createThingsToDo(PaceThingsToDoRequest(
                title: title,
                notes: stringValue(for: "notes", in: arguments)
            ))
        case "messages.open", "messages.draft":
            let recipient = firstStringValue(for: ["recipient", "to", "name"], in: arguments)
            let text = firstStringValue(for: ["text", "body"], in: arguments)
            return .openMessages(PaceMessageRequest(
                recipient: recipient,
                text: text
            ))
        case "mcp.call", "mcp":
            let serverName = firstStringValue(for: ["server", "serverName"], in: arguments)
            let toolName = firstStringValue(for: ["tool", "toolName", "name"], in: arguments)
            guard let serverName, !serverName.isEmpty,
                  let toolName, !toolName.isEmpty else { return nil }
            let mcpArguments = objectValue(for: "arguments", in: arguments) ?? arguments
            return .mcp(PaceMCPToolCall(
                serverName: serverName,
                toolName: toolName,
                arguments: mcpArguments
            ))
        case "file.download", "download.file":
            let rawURLString = firstStringValue(for: ["url", "text"], in: arguments) ?? ""
            guard let downloadURL = PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) else {
                return nil
            }
            let suggestedFilename = firstStringValue(for: ["filename", "name", "title"], in: arguments)
            return .downloadFile(PaceFileDownloadRequest(
                url: downloadURL,
                suggestedFilename: suggestedFilename
            ))
        case "finder.reveal":
            let path = firstStringValue(for: ["path", "url"], in: arguments)
            guard let path, !path.isEmpty else { return nil }
            return .finder(PaceFinderRequest(path: path, action: .reveal))
        case "finder.open":
            let path = firstStringValue(for: ["path", "url"], in: arguments)
            guard let path, !path.isEmpty else { return nil }
            return .finder(PaceFinderRequest(path: path, action: .open))
        default:
            return nil
        }
    }

    private static func validateParameterizedActionCall(
        name rawActionName: String,
        arguments: [String: PaceMCPJSONValue]
    ) -> [String] {
        let normalizedActionName = normalizedParameterizedActionName(rawActionName)
        var issues: [String] = []

        switch normalizedActionName {
        case "app.launch", "app.open", "open.app":
            if !hasNonEmptyString(for: ["name", "app"], in: arguments) {
                issues.append("requires app name")
            }
        case "app.openurl", "open.url", "url.open":
            if !hasNonEmptyString(for: ["url", "text"], in: arguments) {
                issues.append("requires url")
            }
        case "ax.press", "click", "mouse.click",
             "ax.doublepress", "double.click", "mouse.doubleclick":
            if screenshotPixelLocation(from: arguments) == nil
                && parseClickCandidateSet(fromParameterizedArguments: arguments, clickCount: 1) == nil {
                issues.append("requires x/y coordinates or candidates")
            }
        case "ax.setvalue", "type", "keyboard.type":
            if !hasNonEmptyString(for: ["value", "text", "body"], in: arguments) {
                issues.append("requires non-empty text")
            }
        case "undo.last", "undo", "undo.lastmutation", "clipboard.read", "clipboard":
            break
        case "key.press", "keyboard.press":
            let key = firstStringValue(for: ["key", "name", "command"], in: arguments) ?? ""
            if parseKeyPayload(key) == nil {
                issues.append("requires supported key")
            }
        case "window.snap", "window.move", "window.resize":
            if parseWindowSnapRequest(from: arguments) == nil {
                issues.append("requires supported window snap position")
            }
        case "ax.scroll":
            if let direction = stringValue(for: "direction", in: arguments),
               !["up", "down"].contains(direction.lowercased()) {
                issues.append("direction must be up or down")
            }
        case "music.control", "music":
            let command = firstStringValue(for: ["command", "name"], in: arguments) ?? ""
            if parseMusicPayload(command) == nil {
                issues.append("requires supported music command")
            }
        case "volume.adjust", "volume", "brightness.adjust", "brightness":
            if parseSystemAdjustmentPayloadFromParameterizedArguments(arguments) == nil {
                issues.append("requires supported adjustment direction")
            }
        case "calendar.read", "calendar.list":
            let range = firstStringValue(for: ["range", "when"], in: arguments) ?? "today"
            if parseCalendarPayload(range) == nil {
                issues.append("requires supported calendar range")
            }
        case "calendar.createevent", "calendar.create", "calendar.add", "cal.event":
            if parseCalendarEventRequest(from: arguments) == nil {
                issues.append("requires title and start date")
            }
        case "reminders.add", "reminder.add":
            if !hasNonEmptyString(for: ["title", "text", "name"], in: arguments) {
                issues.append("requires reminder title")
            }
        case "notes.create", "note.create", "notes.append", "note.append":
            if !hasNonEmptyString(for: ["title", "name", "body", "text", "notes"], in: arguments) {
                issues.append("requires note title or body")
            }
        case "notes.search", "note.search":
            if !hasNonEmptyString(for: ["query", "text", "title", "name"], in: arguments) {
                issues.append("requires notes query")
            }
        case "file.download", "download.file":
            let rawURLString = firstStringValue(for: ["url", "text"], in: arguments) ?? ""
            if PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) == nil {
                issues.append("requires a valid http(s) download url")
            }
        case "mail.draft", "mail.compose":
            if stringArrayValue(for: "to", in: arguments).isEmpty
                && stringArrayValue(for: "recipients", in: arguments).isEmpty
                && stringArrayValue(for: "recipient", in: arguments).isEmpty
                && !hasNonEmptyString(for: ["subject", "title", "body", "text", "bodyText"], in: arguments) {
                issues.append("requires recipient, subject, or body")
            }
        case "shortcut.run", "shortcuts.run":
            if !hasNonEmptyString(for: ["name", "title", "shortcut"], in: arguments) {
                issues.append("requires shortcut name")
            }
        case "things.create", "things.add":
            if !hasNonEmptyString(for: ["title", "text", "name"], in: arguments) {
                issues.append("requires todo title")
            }
        case "messages.open", "messages.draft":
            break
        case "mcp.call", "mcp":
            if !hasNonEmptyString(for: ["server", "serverName"], in: arguments) {
                issues.append("requires MCP server")
            }
            if !hasNonEmptyString(for: ["tool", "toolName", "name"], in: arguments) {
                issues.append("requires MCP tool name")
            }
        case "finder.reveal", "finder.open":
            if !hasNonEmptyString(for: ["path", "url"], in: arguments) {
                issues.append("requires path")
            }
        default:
            issues.append("unknown action")
        }

        return issues
    }

    private static func normalizedParameterizedActionName(_ rawActionName: String) -> String {
        rawActionName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
    }

    private static func screenshotPixelLocation(from arguments: [String: PaceMCPJSONValue]) -> ScreenshotPixelLocation? {
        guard let xPixel = intValue(for: "x", in: arguments),
              let yPixel = intValue(for: "y", in: arguments) else {
            return nil
        }
        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: intValue(for: "screen", in: arguments)
        )
    }

    private static func parseClickCandidateSet(
        fromParameterizedArguments arguments: [String: PaceMCPJSONValue],
        clickCount: Int
    ) -> PaceClickCandidateSet? {
        guard case .array(let rawCandidateValues)? = arguments["candidates"] else { return nil }
        let defaultScreenNumber = intValue(for: "screen", in: arguments)
        let defaultExpectStateChange = boolValue(for: "expectStateChange", in: arguments) ?? true

        let candidates = rawCandidateValues.compactMap { rawCandidateValue -> PaceClickCandidate? in
            guard case .object(let candidateObject) = rawCandidateValue else { return nil }
            let trimmedLabel = firstStringValue(for: ["label", "title", "name"], in: candidateObject)
            let candidateLocation: ScreenshotPixelLocation? = {
                guard let xPixel = intValue(for: "x", in: candidateObject),
                      let yPixel = intValue(for: "y", in: candidateObject) else {
                    return nil
                }
                return ScreenshotPixelLocation(
                    xInScreenshotPixels: xPixel,
                    yInScreenshotPixels: yPixel,
                    screenNumber: intValue(for: "screen", in: candidateObject) ?? defaultScreenNumber
                )
            }()

            guard candidateLocation != nil || !(trimmedLabel ?? "").isEmpty else { return nil }

            return PaceClickCandidate(
                location: candidateLocation,
                label: trimmedLabel,
                confidence: max(0, min(doubleValue(for: "confidence", in: candidateObject) ?? 0.5, 1)),
                expectStateChange: boolValue(for: "expectStateChange", in: candidateObject) ?? defaultExpectStateChange,
                recency: parseClickCandidateRecency(fromParameterizedArguments: candidateObject)
            )
        }

        guard !candidates.isEmpty else { return nil }
        return PaceClickCandidateSet(candidates: candidates, clickCount: clickCount)
    }

    private static func parseClickCandidateRecency(
        fromParameterizedArguments arguments: [String: PaceMCPJSONValue]
    ) -> PaceClickCandidateRecency? {
        let rank = intValue(for: "recencyRank", in: arguments)
            ?? intValue(for: "recentRank", in: arguments)
        let lastSeenMillisecondsAgo = doubleValue(for: "lastSeenMillisecondsAgo", in: arguments)
            ?? doubleValue(for: "lastSeenMsAgo", in: arguments)
            ?? doubleValue(for: "observedMillisecondsAgo", in: arguments)
            ?? doubleValue(for: "observedMsAgo", in: arguments)
        guard rank != nil || lastSeenMillisecondsAgo != nil else { return nil }
        return PaceClickCandidateRecency(
            rank: rank,
            lastSeenMillisecondsAgo: lastSeenMillisecondsAgo
        )
    }

    private static func parseSystemAdjustmentPayloadFromParameterizedArguments(
        _ arguments: [String: PaceMCPJSONValue]
    ) -> PaceSystemAdjustment? {
        let direction = firstStringValue(for: ["direction", "command"], in: arguments) ?? "up"
        let steps = intValue(for: "steps", in: arguments)
            ?? intValue(for: "amount", in: arguments)
            ?? 2
        return parseSystemAdjustmentPayload("\(direction):\(steps)")
    }

    private static func firstStringValue(
        for keys: [String],
        in object: [String: PaceMCPJSONValue]
    ) -> String? {
        for key in keys {
            if let value = stringValue(for: key, in: object), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> String? {
        guard let value = object[key] else { return nil }
        switch value {
        case .string(let stringValue):
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let numberValue):
            if numberValue.rounded() == numberValue {
                return String(Int(numberValue))
            }
            return String(numberValue)
        case .bool(let boolValue):
            return String(boolValue)
        case .array, .object, .null:
            return nil
        }
    }

    private static func strictStringValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> String? {
        guard case .string(let stringValue)? = object[key] else { return nil }
        return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> Int? {
        guard let value = object[key] else { return nil }
        switch value {
        case .number(let numberValue):
            return Int(numberValue)
        case .string(let stringValue):
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .array, .object, .null:
            return nil
        }
    }

    private static func doubleValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> Double? {
        guard let value = object[key] else { return nil }
        switch value {
        case .number(let numberValue):
            return numberValue
        case .string(let stringValue):
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .array, .object, .null:
            return nil
        }
    }

    private static func objectValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> [String: PaceMCPJSONValue]? {
        guard case .object(let objectValue)? = object[key] else { return nil }
        return objectValue
    }

    private static func boolValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> Bool? {
        guard let value = object[key] else { return nil }
        switch value {
        case .bool(let boolValue):
            return boolValue
        case .string(let stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        case .number(let numberValue):
            return numberValue != 0
        case .array, .object, .null:
            return nil
        }
    }

    private static func stringArrayValue(
        for key: String,
        in object: [String: PaceMCPJSONValue]
    ) -> [String] {
        guard let value = object[key] else { return [] }
        switch value {
        case .string(let stringValue):
            return stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .array(let arrayValue):
            return arrayValue.compactMap { element in
                switch element {
                case .string(let stringValue):
                    let trimmedString = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmedString.isEmpty ? nil : trimmedString
                case .number(let numberValue):
                    if numberValue.rounded() == numberValue {
                        return String(Int(numberValue))
                    }
                    return String(numberValue)
                case .bool, .array, .object, .null:
                    return nil
                }
            }
        case .number(let numberValue):
            if numberValue.rounded() == numberValue {
                return [String(Int(numberValue))]
            }
            return [String(numberValue)]
        case .bool, .object, .null:
            return []
        }
    }

    private static func parseSingleAction(tagName: String, payload: String) -> PaceParsedAction? {
        switch tagName {
        case "CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .click($0) }
        case "DOUBLE_CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .doubleClick($0) }
        case "TYPE":
            // TYPE payload is free text — pass through verbatim.
            return .type(payload)
        case "KEY":
            return parseKeyPayload(payload)
        case "SCROLL":
            return parseScrollPayload(payload)
        case "OPEN_APP":
            return parseOpenApplicationPayload(payload)
        case "OPEN_URL":
            return parseOpenURLPayload(payload)
        case "MUSIC":
            return parseMusicPayload(payload)
        case "VOLUME":
            return parseSystemAdjustmentPayload(payload).map { .adjustVolume($0) }
        case "BRIGHTNESS":
            return parseSystemAdjustmentPayload(payload).map { .adjustBrightness($0) }
        case "CALENDAR":
            return parseCalendarPayload(payload)
        case "REMINDER":
            return parseReminderPayload(payload)
        default:
            return nil
        }
    }

    private static func parseToolCallBlocks(in responseText: String) -> (steps: [PaceActionExecutionStep], strippedText: String) {
        let pattern = #"<tool_calls>(.*?)</tool_calls>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ([], responseText)
        }

        let entireRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, options: [], range: entireRange)
        guard !matches.isEmpty else { return ([], responseText) }

        var parsedSteps: [PaceActionExecutionStep] = []
        var strippedText = responseText

        for match in matches {
            guard let jsonRange = Range(match.range(at: 1), in: responseText) else { continue }
            let jsonText = String(responseText[jsonRange])
            parsedSteps.append(contentsOf: decodeToolCallSteps(from: jsonText))
        }

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: strippedText) else { continue }
            strippedText.removeSubrange(fullRange)
        }

        return (parsedSteps, strippedText)
    }

    private static func decodeToolCallSteps(from jsonText: String) -> [PaceActionExecutionStep] {
        guard let jsonData = jsonText.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()

        if let groupedToolCalls = try? decoder.decode([[ToolCallDTO]].self, from: jsonData) {
            return groupedToolCalls.compactMap { toolCallGroup in
                let actions = toolCallGroup.compactMap(parseToolCall)
                return actions.isEmpty ? nil : PaceActionExecutionStep(actions: actions)
            }
        }

        if let flatToolCalls = try? decoder.decode([ToolCallDTO].self, from: jsonData) {
            return flatToolCalls.compactMap { toolCall in
                guard let action = parseToolCall(toolCall) else { return nil }
                return PaceActionExecutionStep(actions: [action])
            }
        }

        return []
    }

    private static func parseToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        if let mcpToolCall = parseMCPToolCall(toolCall) {
            return .mcp(mcpToolCall)
        }

        guard let toolKind = PaceToolRegistry.kind(forToolName: toolCall.tool) else {
            return nil
        }

        let validationIssues = validateLocalToolCall(toolCall, kind: toolKind)
        guard validationIssues.isEmpty else {
            print("⚠️ Rejected invalid \(toolCall.tool) tool call before execution: \(validationIssues.joined(separator: "; "))")
            return nil
        }

        switch toolKind {
        case .click:
            if let clickCandidateSet = parseClickCandidateSet(toolCall, clickCount: 1) {
                return .clickCandidates(clickCandidateSet)
            }
            return parseToolCallLocation(toolCall).map { .click($0) }
        case .doubleClick:
            if let clickCandidateSet = parseClickCandidateSet(toolCall, clickCount: 2) {
                return .clickCandidates(clickCandidateSet)
            }
            return parseToolCallLocation(toolCall).map { .doubleClick($0) }
        case .type:
            guard let text = toolCall.text, !text.isEmpty else { return nil }
            return .type(text)
        case .setValue:
            let mergedArguments = mergeMCPArguments(from: toolCall)
            let value = (firstStringValue(for: ["value", "text", "body"], in: mergedArguments) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let target = parseSetTextValueTarget(firstStringValue(for: ["target", "action"], in: mergedArguments)) ?? .focused
            return .setTextValue(PaceSetTextValueRequest(
                value: value,
                target: target
            ))
        case .undo:
            return .undoLastMutation
        case .key:
            return parseKeyPayload(toolCall.key ?? toolCall.command ?? "")
        case .clipboard:
            return .readClipboard
        case .window:
            return parseWindowToolCall(toolCall)
        case .scroll:
            return parseScrollPayload(
                [
                    toolCall.direction,
                    (toolCall.amount ?? toolCall.steps).map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            )
        case .openApp:
            return parseOpenApplicationPayload(toolCall.app ?? toolCall.name ?? "")
        case .openURL:
            return parseOpenURLPayload(toolCall.url ?? toolCall.text ?? "")
        case .music:
            return parseMusicPayload(toolCall.command ?? "")
        case .volume:
            return parseSystemAdjustmentPayload(
                [
                    toolCall.direction,
                    toolCall.steps.map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            ).map { .adjustVolume($0) }
        case .brightness:
            return parseSystemAdjustmentPayload(
                [
                    toolCall.direction,
                    toolCall.steps.map(String.init)
                ]
                .compactMap { $0 }
                .joined(separator: ":")
            ).map { .adjustBrightness($0) }
        case .calendar:
            if let calendarEventAction = parseCalendarEventToolCallIfRequested(toolCall) {
                return calendarEventAction
            }
            return parseCalendarPayload(toolCall.range ?? "today")
        case .calendarCreate:
            return parseCalendarEventToolCall(toolCall)
        case .reminder:
            return parseReminderPayload(toolCall.title ?? toolCall.text ?? "")
        case .finder:
            return parseFinderToolCall(toolCall)
        case .notes:
            return parseNoteToolCall(toolCall)
        case .mail:
            return parseMailToolCall(toolCall)
        case .things:
            return parseThingsToolCall(toolCall)
        case .shortcuts:
            return parseShortcutToolCall(toolCall)
        case .messages:
            return parseMessagesToolCall(toolCall)
        case .downloadFile:
            return parseDownloadFileToolCall(toolCall)
        }
    }

    private static func validateLocalToolCall(_ toolCall: ToolCallDTO, kind: PaceLocalToolKind) -> [String] {
        let mergedArguments = mergeMCPArguments(from: toolCall)
        var issues: [String] = []

        // Defense-in-depth for the no-destructive-tools invariant (also
        // enforced by registry startup validation): even if a destructive
        // definition slipped past startup, its calls are rejected here
        // before approval or execution.
        if PaceToolRegistry.localTools.first(where: { $0.kind == kind })?.riskLevel == .destructive {
            issues.append("destructive actions are not permitted")
        }

        switch kind {
        case .click, .doubleClick:
            if parseToolCallLocation(toolCall) == nil && parseClickCandidateSet(toolCall, clickCount: 1) == nil {
                issues.append("requires x/y coordinates or candidates")
            }
        case .type:
            if !hasNonEmptyString(for: ["text", "body", "value"], in: mergedArguments) {
                issues.append("requires non-empty text")
            }
        case .setValue:
            if !hasNonEmptyString(for: ["value", "text", "body"], in: mergedArguments) {
                issues.append("requires non-empty value")
            }
            if let target = firstStringValue(for: ["target", "action"], in: mergedArguments),
               parseSetTextValueTarget(target) == nil {
                issues.append("target must be focused or selection")
            }
        case .undo, .clipboard:
            break
        case .key:
            if !hasNonEmptyString(for: ["key", "command", "name"], in: mergedArguments) {
                issues.append("requires key")
            }
        case .window:
            if parseWindowSnapRequest(from: mergedArguments) == nil {
                issues.append("requires a supported window snap position")
            }
        case .scroll:
            if let direction = firstStringValue(for: ["direction", "command"], in: mergedArguments) {
                if !["up", "down"].contains(direction.lowercased()) {
                    issues.append("direction must be up or down")
                }
            }
        case .openApp:
            if !hasNonEmptyString(for: ["app", "name"], in: mergedArguments) {
                issues.append("requires app")
            }
        case .openURL:
            if !hasNonEmptyString(for: ["url", "text"], in: mergedArguments) {
                issues.append("requires url")
            }
        case .music:
            let command = firstStringValue(for: ["command", "name"], in: mergedArguments) ?? ""
            if parseMusicPayload(command) == nil {
                issues.append("requires supported music command")
            }
        case .volume, .brightness:
            let direction = firstStringValue(for: ["direction", "command"], in: mergedArguments)
            if let direction {
                if !["up", "down"].contains(direction.lowercased()) {
                    issues.append("direction must be up or down")
                }
            } else {
                issues.append("requires direction")
            }
        case .calendar:
            let normalizedAction = (firstStringValue(for: ["action"], in: mergedArguments) ?? "")
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            if ["create", "create_event", "add", "schedule"].contains(normalizedAction) {
                if parseCalendarEventToolCall(toolCall) == nil {
                    issues.append("requires title and start date")
                }
                break
            }
            let range = firstStringValue(for: ["range", "when"], in: mergedArguments) ?? "today"
            if parseCalendarPayload(range) == nil {
                issues.append("requires supported calendar range")
            }
        case .calendarCreate:
            if parseCalendarEventToolCall(toolCall) == nil {
                issues.append("requires title and start date")
            }
        case .reminder:
            if !hasNonEmptyString(for: ["title", "text", "name"], in: mergedArguments) {
                issues.append("requires reminder title")
            }
        case .finder:
            if !hasNonEmptyString(for: ["path", "text"], in: mergedArguments) {
                issues.append("requires path")
            }
        case .notes:
            let normalizedAction = (firstStringValue(for: ["action"], in: mergedArguments) ?? "create")
                .lowercased()
            if ["search", "find"].contains(normalizedAction) {
                if !hasNonEmptyString(for: ["query", "text", "title", "name", "body", "notes"], in: mergedArguments) {
                    issues.append("requires notes query")
                }
            } else if !hasNonEmptyString(for: ["title", "name", "body", "text", "notes"], in: mergedArguments) {
                issues.append("requires note title or body")
            }
        case .mail:
            if !hasNonEmptyString(for: ["to", "recipient", "subject", "title", "body", "text"], in: mergedArguments) {
                issues.append("requires recipient, subject, or body")
            }
        case .things:
            if !hasNonEmptyString(for: ["title", "text", "name"], in: mergedArguments) {
                issues.append("requires todo title")
            }
        case .shortcuts:
            if !hasNonEmptyString(for: ["name", "title", "command"], in: mergedArguments) {
                issues.append("requires shortcut name")
            }
        case .messages:
            break
        case .downloadFile:
            let rawURLString = firstStringValue(for: ["url", "text"], in: mergedArguments) ?? ""
            if PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) == nil {
                issues.append("requires a valid http(s) download url")
            }
        }

        return issues
    }

    private static func hasNonEmptyString(
        for keys: [String],
        in object: [String: PaceMCPJSONValue]
    ) -> Bool {
        firstStringValue(for: keys, in: object) != nil
    }

    private static func parseMCPToolCall(_ toolCall: ToolCallDTO) -> PaceMCPToolCall? {
        let normalizedToolName = toolCall.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let serverName = toolCall.server?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedToolName == "mcp" {
            guard let serverName, !serverName.isEmpty else { return nil }
            let mcpToolName = [
                toolCall.toolName,
                toolCall.mcpTool,
                toolCall.name,
                toolCall.command,
                toolCall.action
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

            guard let mcpToolName else { return nil }
            var serverArguments = mergeMCPArguments(from: toolCall)
            // Top-level `name`/`action`/`command` can carry the MCP tool name
            // rather than a real tool argument — drop them when they only
            // duplicate the resolved tool name so servers get clean arguments.
            for routingKey in ["name", "action", "command"] {
                if case .string(let routingValue)? = serverArguments[routingKey],
                   routingValue == mcpToolName {
                    serverArguments.removeValue(forKey: routingKey)
                }
            }
            return PaceMCPToolCall(
                serverName: serverName,
                toolName: mcpToolName,
                arguments: serverArguments
            )
        }

        if let serverName, !serverName.isEmpty, PaceToolRegistry.kind(forToolName: toolCall.tool) == nil {
            return PaceMCPToolCall(
                serverName: serverName,
                toolName: toolCall.tool,
                arguments: mergeMCPArguments(from: toolCall)
            )
        }

        return nil
    }

    private static func mergeMCPArguments(from toolCall: ToolCallDTO) -> [String: PaceMCPJSONValue] {
        var arguments = toolCall.arguments

        let knownPayloadArguments: [(String, PaceMCPJSONValue?)] = [
            ("app", toolCall.app.map { .string($0) }),
            ("url", toolCall.url.map { .string($0) }),
            ("command", toolCall.command.map { .string($0) }),
            ("direction", toolCall.direction.map { .string($0) }),
            ("title", toolCall.title.map { .string($0) }),
            ("name", toolCall.name.map { .string($0) }),
            ("query", toolCall.query.map { .string($0) }),
            ("action", toolCall.action.map { .string($0) }),
            ("text", toolCall.text.map { .string($0) }),
            ("body", toolCall.body.map { .string($0) }),
            ("notes", toolCall.notes.map { .string($0) }),
            ("range", toolCall.range.map { .string($0) }),
            ("key", toolCall.key.map { .string($0) }),
            ("path", toolCall.path.map { .string($0) }),
            ("to", toolCall.to.map { .string($0) }),
            ("subject", toolCall.subject.map { .string($0) }),
            ("recipient", toolCall.recipient.map { .string($0) }),
            ("steps", toolCall.steps.map { .number(Double($0)) }),
            ("amount", toolCall.amount.map { .number(Double($0)) }),
            ("x", toolCall.x.map { .number(Double($0)) }),
            ("y", toolCall.y.map { .number(Double($0)) }),
            ("screen", toolCall.screen.map { .number(Double($0)) })
        ]

        for (key, value) in knownPayloadArguments {
            guard let value else { continue }
            arguments[key] = value
        }

        for (key, value) in toolCall.extraArguments {
            arguments[key] = value
        }
        return arguments
    }

    private static func parseToolCallLocation(_ toolCall: ToolCallDTO) -> ScreenshotPixelLocation? {
        guard let xPixel = toolCall.x, let yPixel = toolCall.y else { return nil }
        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: toolCall.screen
        )
    }

    private static func parseClickCandidateSet(
        _ toolCall: ToolCallDTO,
        clickCount: Int
    ) -> PaceClickCandidateSet? {
        let candidates = toolCall.candidates.compactMap { candidateDTO -> PaceClickCandidate? in
            let trimmedLabel = candidateDTO.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateLocation: ScreenshotPixelLocation? = {
                guard let xPixel = candidateDTO.x, let yPixel = candidateDTO.y else { return nil }
                return ScreenshotPixelLocation(
                    xInScreenshotPixels: xPixel,
                    yInScreenshotPixels: yPixel,
                    screenNumber: candidateDTO.screen ?? toolCall.screen
                )
            }()

            guard candidateLocation != nil || !(trimmedLabel ?? "").isEmpty else { return nil }

            return PaceClickCandidate(
                location: candidateLocation,
                label: trimmedLabel,
                confidence: max(0, min(candidateDTO.confidence ?? 0.5, 1)),
                expectStateChange: candidateDTO.expectStateChange ?? toolCall.expectStateChange ?? true,
                recency: parseClickCandidateRecency(candidateDTO)
            )
        }

        guard !candidates.isEmpty else { return nil }
        return PaceClickCandidateSet(candidates: candidates, clickCount: clickCount)
    }

    private static func parseClickCandidateRecency(
        _ candidateDTO: ToolCallDTO.ClickCandidateDTO
    ) -> PaceClickCandidateRecency? {
        guard candidateDTO.recencyRank != nil || candidateDTO.lastSeenMillisecondsAgo != nil else {
            return nil
        }
        return PaceClickCandidateRecency(
            rank: candidateDTO.recencyRank,
            lastSeenMillisecondsAgo: candidateDTO.lastSeenMillisecondsAgo
        )
    }

    private static func firstClickVisualisationLocation(in actions: [PaceParsedAction]) -> ScreenshotPixelLocation? {
        for action in actions {
            switch action {
            case .click(let location), .doubleClick(let location):
                return location
            case .clickCandidates(let clickCandidateSet):
                return clickCandidateSet.selectedFallbackLocation
            default:
                continue
            }
        }
        return nil
    }

    /// Parses `x,y` or `x,y:screenN` into a ScreenshotPixelLocation.
    private static func parseScreenshotPixelLocationPayload(_ payload: String) -> ScreenshotPixelLocation? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard let coordinateComponent = payloadComponents.first else { return nil }

        let xyComponents = coordinateComponent.split(separator: ",", omittingEmptySubsequences: false)
        guard xyComponents.count == 2,
              let xPixel = Int(xyComponents[0].trimmingCharacters(in: .whitespaces)),
              let yPixel = Int(xyComponents[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        var screenNumber: Int? = nil
        for trailingComponent in payloadComponents.dropFirst() {
            let trimmedTrailingComponent = trailingComponent.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmedTrailingComponent.hasPrefix("screen") {
                let digitsString = trimmedTrailingComponent.dropFirst("screen".count)
                screenNumber = Int(digitsString)
            }
        }

        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: screenNumber
        )
    }

    /// Parses `Return`, `cmd+s`, `cmd+shift+t` into a pressKey action.
    private static func parseKeyPayload(_ payload: String) -> PaceParsedAction? {
        let plusSeparatedTokens = payload.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let mainKeyToken = plusSeparatedTokens.last, !mainKeyToken.isEmpty else { return nil }
        // Reject key names the executor cannot map to a virtual key code, so
        // the planner gets a parse-time rejection instead of a mid-plan failure.
        guard PaceActionExecutor.virtualKeyCode(forKeyName: mainKeyToken) != nil else { return nil }

        var modifiers: [PaceKeyboardModifier] = []
        for modifierToken in plusSeparatedTokens.dropLast() {
            switch modifierToken {
            case "cmd", "command", "meta": modifiers.append(.command)
            case "opt", "option", "alt": modifiers.append(.option)
            case "ctrl", "control": modifiers.append(.control)
            case "shift": modifiers.append(.shift)
            default: continue
            }
        }

        return .pressKey(name: mainKeyToken, modifiers: modifiers)
    }

    /// Parses `up:3` / `down:5` into a scroll action.
    private static func parseScrollPayload(_ payload: String) -> PaceParsedAction? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceScrollDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let amountInLines: Int = {
            if payloadComponents.count >= 2,
               let parsedAmount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedAmount, 50)) // clamp to a reasonable range
            }
            return 3
        }()

        return .scroll(direction, amountInLines: amountInLines)
    }

    private static func parseOpenApplicationPayload(_ payload: String) -> PaceParsedAction? {
        let applicationName = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !applicationName.isEmpty else { return nil }
        return .openApplication(applicationName)
    }

    private static func parseOpenURLPayload(_ payload: String) -> PaceParsedAction? {
        let urlString = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        return .openURL(urlString)
    }

    private static func parseSetTextValueTarget(_ rawTarget: String?) -> PaceSetTextValueTarget? {
        let normalizedTarget = rawTarget?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch normalizedTarget {
        case "focused", "focus", "field", "value":
            return .focused
        case "selection", "selected", "selected_text", "replace_selection":
            return .selection
        default:
            return nil
        }
    }

    private static func parseWindowSnapRequest(
        from arguments: [String: PaceMCPJSONValue]
    ) -> PaceWindowSnapRequest? {
        let rawPosition = firstStringValue(
            for: ["position", "target", "side", "direction", "action"],
            in: arguments
        )
        guard let position = parseWindowSnapPosition(rawPosition) else {
            return nil
        }
        return PaceWindowSnapRequest(position: position)
    }

    private static func parseWindowSnapPosition(_ rawPosition: String?) -> PaceWindowSnapPosition? {
        let normalizedPosition = rawPosition?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalizedPosition {
        case "left", "left_half", "left_side":
            return .left
        case "right", "right_half", "right_side":
            return .right
        case "top", "top_half", "upper_half":
            return .top
        case "bottom", "bottom_half", "lower_half":
            return .bottom
        case "maximize", "maximise", "full", "fullscreen", "full_screen":
            return .maximize
        case "center", "centre", "middle":
            return .center
        default:
            return nil
        }
    }

    private static func parseMusicPayload(_ payload: String) -> PaceParsedAction? {
        let normalizedCommand = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalizedCommand {
        case "play":
            return .controlMusic(.play)
        case "pause":
            return .controlMusic(.pause)
        case "play_pause", "playpause", "toggle":
            return .controlMusic(.playPause)
        case "next", "next_track":
            return .controlMusic(.next)
        case "previous", "prev", "previous_track":
            return .controlMusic(.previous)
        default:
            return nil
        }
    }

    private static func parseCalendarPayload(_ payload: String) -> PaceParsedAction? {
        let normalizedRange = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let range: PaceCalendarRange
        switch normalizedRange {
        case "today", "":
            range = .today
        case "tomorrow":
            range = .tomorrow
        case "week", "next_week", "next_7_days", "next 7 days":
            range = .week
        default:
            return nil
        }
        return .listCalendarEvents(PaceCalendarQuery(range: range))
    }

    private struct ParsedCalendarDate {
        let date: Date
        let isDateOnly: Bool
    }

    private static func parseCalendarEventRequest(
        from arguments: [String: PaceMCPJSONValue]
    ) -> PaceCalendarEventRequest? {
        let title = firstStringValue(for: ["title", "name", "summary"], in: arguments) ?? ""
        guard !title.isEmpty else { return nil }

        let rawStartDate = firstStringValue(
            for: ["start", "startDate", "startsAt", "date", "when"],
            in: arguments
        )
        guard let rawStartDate,
              let parsedStartDate = parseCalendarDate(rawStartDate) else {
            return nil
        }

        let rawEndDate = firstStringValue(for: ["end", "endDate", "endsAt"], in: arguments)
        let parsedEndDate = rawEndDate.flatMap(parseCalendarDate)
        let isAllDay = boolValue(for: "allDay", in: arguments)
            ?? boolValue(for: "isAllDay", in: arguments)
            ?? parsedStartDate.isDateOnly

        let defaultEndDate: Date = {
            let calendar = Calendar.current
            if isAllDay {
                return calendar.date(byAdding: .day, value: 1, to: parsedStartDate.date)
                    ?? parsedStartDate.date.addingTimeInterval(24 * 60 * 60)
            }
            return calendar.date(byAdding: .hour, value: 1, to: parsedStartDate.date)
                ?? parsedStartDate.date.addingTimeInterval(60 * 60)
        }()

        let endDate = parsedEndDate?.date ?? defaultEndDate
        let safeEndDate = endDate > parsedStartDate.date ? endDate : defaultEndDate

        return PaceCalendarEventRequest(
            title: title,
            startDate: parsedStartDate.date,
            endDate: safeEndDate,
            isAllDay: isAllDay,
            notes: firstStringValue(for: ["notes", "body", "description"], in: arguments),
            location: firstStringValue(for: ["location", "place"], in: arguments),
            calendarTitle: firstStringValue(for: ["calendar", "calendarTitle"], in: arguments)
        )
    }

    private static func parseCalendarDate(_ rawDate: String) -> ParsedCalendarDate? {
        let trimmedRawDate = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawDate.isEmpty else { return nil }

        if let dateOnlyDate = parseDateOnly(trimmedRawDate) {
            return ParsedCalendarDate(date: dateOnlyDate, isDateOnly: true)
        }

        let iso8601FormatterWithFractionalSeconds = ISO8601DateFormatter()
        iso8601FormatterWithFractionalSeconds.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = iso8601FormatterWithFractionalSeconds.date(from: trimmedRawDate) {
            return ParsedCalendarDate(date: date, isDateOnly: false)
        }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime]
        if let date = iso8601Formatter.date(from: trimmedRawDate) {
            return ParsedCalendarDate(date: date, isDateOnly: false)
        }

        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmedRawDate) {
                return ParsedCalendarDate(date: date, isDateOnly: false)
            }
        }

        return nil
    }

    private static func parseDateOnly(_ rawDate: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: rawDate).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func parseReminderPayload(_ payload: String) -> PaceParsedAction? {
        let reminderTitle = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reminderTitle.isEmpty else { return nil }
        return .createReminder(PaceReminderRequest(title: reminderTitle, notes: nil))
    }

    private static func parseCalendarEventToolCallIfRequested(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let normalizedAction = (toolCall.action ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        guard ["create", "create_event", "add", "schedule"].contains(normalizedAction) else {
            return nil
        }

        return parseCalendarEventToolCall(toolCall)
    }

    private static func parseCalendarEventToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        parseParameterizedAction(
            name: "Calendar.createEvent",
            arguments: mergeMCPArguments(from: toolCall)
        )
    }

    private static func parseWindowToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        parseParameterizedAction(
            name: "Window.snap",
            arguments: mergeMCPArguments(from: toolCall)
        )
    }

    private static func parseFinderToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let path = (toolCall.path ?? toolCall.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let normalizedAction = (toolCall.action ?? "open")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let finderAction: PaceFinderAction = normalizedAction == "reveal" ? .reveal : .open

        return .finder(PaceFinderRequest(path: path, action: finderAction))
    }

    private static func parseNoteToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let normalizedAction = (toolCall.action ?? "create")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let title = (toolCall.title ?? toolCall.name ?? "Pace note")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (toolCall.body ?? toolCall.text ?? toolCall.notes ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedAction == "search" || normalizedAction == "find" {
            let query = (toolCall.query ?? toolCall.text ?? toolCall.title ?? toolCall.name ?? body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            return .searchNotes(query)
        }

        guard !title.isEmpty || !body.isEmpty else { return nil }
        let noteRequest = PaceNoteRequest(
            title: title.isEmpty ? "Pace note" : title,
            body: body
        )

        if normalizedAction == "append" || normalizedAction == "add" || normalizedAction == "update" {
            return .appendNote(noteRequest)
        }

        return .createNote(noteRequest)
    }

    private static func parseDownloadFileToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let rawURLString = toolCall.url ?? toolCall.text ?? ""
        guard let downloadURL = PaceFileDownloadURLValidator.validatedDownloadURL(from: rawURLString) else {
            return nil
        }
        let suggestedFilename = (toolCall.name ?? toolCall.title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .downloadFile(PaceFileDownloadRequest(
            url: downloadURL,
            suggestedFilename: suggestedFilename?.isEmpty == false ? suggestedFilename : nil
        ))
    }

    private static func parseMailToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let recipients = (toolCall.to ?? toolCall.recipient ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let subject = (toolCall.subject ?? toolCall.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (toolCall.body ?? toolCall.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty || !body.isEmpty || !recipients.isEmpty else { return nil }

        return .composeMail(PaceMailDraft(
            recipients: recipients,
            subject: subject.isEmpty ? "Untitled" : subject,
            body: body
        ))
    }

    private static func parseThingsToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let title = (toolCall.title ?? toolCall.text ?? toolCall.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return .createThingsToDo(PaceThingsToDoRequest(title: title, notes: toolCall.notes))
    }

    private static func parseShortcutToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let shortcutName = (toolCall.name ?? toolCall.title ?? toolCall.command ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else { return nil }
        return .runShortcut(shortcutName)
    }

    private static func parseMessagesToolCall(_ toolCall: ToolCallDTO) -> PaceParsedAction? {
        let recipient = (toolCall.recipient ?? toolCall.to ?? toolCall.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (toolCall.text ?? toolCall.body)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .openMessages(PaceMessageRequest(
            recipient: recipient?.isEmpty == false ? recipient : nil,
            text: text?.isEmpty == false ? text : nil
        ))
    }

    /// Parses `up`, `down`, `up:3`, `down:5` into a relative system adjustment.
    private static func parseSystemAdjustmentPayload(_ payload: String) -> PaceSystemAdjustment? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceAdjustmentDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let stepCount: Int = {
            if payloadComponents.count >= 2,
               let parsedStepCount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedStepCount, 10))
            }
            return 2
        }()

        return PaceSystemAdjustment(direction: direction, stepCount: stepCount)
    }
}
