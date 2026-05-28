//
//  PaceAXScreenReader.swift
//  leanring-buddy
//
//  Reads the focused window via macOS Accessibility APIs and produces
//  the same `LocalVLMScreenElement` shape the VLM path produces. This
//  is the fast tier of the 3-tier screen-context ladder:
//
//      AX tree   (this file)   — 5-50ms typical
//      Vision OCR (`.fast`)    — 50-150ms typical, fills text fidelity
//      Local VLM (UI-Venus)    — 800ms-3s, only when AX + OCR insufficient
//
//  Why this tier wins for most queries: production fast voice agents
//  (Wispr Flow, Screenpipe, Granola) read the AX tree first. Most
//  AppKit / SwiftUI / Catalyst apps publish a usable AX tree out of
//  the box — buttons, links, fields all carry roles, frames, titles.
//  Walking that tree is two orders of magnitude faster than vision.
//
//  When this tier loses: Electron with broken AX exports, native
//  games / video, terminal contents, web content rendered without AX
//  hints. For those, the OCR + VLM fallback paths still exist.
//
//  This reader is intentionally narrow:
//  - Reads only the FOCUSED window of the FRONTMOST application.
//    Multi-window context comes from a separate (future) reader.
//  - Filters to "interactive-or-readable" roles. Decorative containers
//    are dropped so the planner prompt stays compact.
//  - Time-boxed via `walkDeadline` so a slow app's AX server can't
//    stall the voice pipeline. We bail at ~100ms and report what we
//    have so far.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PaceAXScreenReader {
    /// Soft cap on how long we'll spend walking the AX tree before
    /// returning whatever we have. Voice latency budget is the whole
    /// point; better to ship partial AX than to stall.
    private let walkDeadlineSeconds: TimeInterval = 0.1

    /// Roles we keep in the element map. Mirrors the taxonomy
    /// `LocalVLMScreenElement.role` uses so downstream consumers
    /// (planner prompt builder, click targeter) don't need to know
    /// which source produced the elements.
    // The macOS Carbon AX headers don't expose every role string as
    // a `k…Role` constant — `AXLink` (used heavily by Safari / web
    // views / many SwiftUI Link views) is one common omission. We
    // use the raw role strings here so every role is reachable.
    private static let axLinkRoleString = "AXLink"

    private static let interestingAXRoles: Set<String> = [
        kAXButtonRole as String,
        axLinkRoleString,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXStaticTextRole as String,
        kAXMenuItemRole as String,
        kAXMenuButtonRole as String,
        kAXCheckBoxRole as String,
        kAXPopUpButtonRole as String,
        kAXTabGroupRole as String,
        kAXRadioButtonRole as String,
        kAXImageRole as String,
        kAXComboBoxRole as String,
        kAXSliderRole as String
    ]

    /// Map AX role strings into the role taxonomy
    /// `LocalVLMScreenElement.role` uses. Anything not in the table
    /// falls through to `"other"` so the planner prompt stays
    /// consistent across sources.
    private static let axRoleToScreenElementRole: [String: String] = [
        kAXButtonRole as String: "button",
        axLinkRoleString: "link",
        kAXTextFieldRole as String: "text_field",
        kAXTextAreaRole as String: "text_field",
        kAXStaticTextRole as String: "static_text",
        kAXMenuItemRole as String: "menu_item",
        kAXMenuButtonRole as String: "menu_item",
        kAXCheckBoxRole as String: "checkbox",
        kAXPopUpButtonRole as String: "button",
        kAXTabGroupRole as String: "tab",
        kAXRadioButtonRole as String: "checkbox",
        kAXImageRole as String: "image",
        kAXComboBoxRole as String: "text_field",
        kAXSliderRole as String: "other"
    ]

    /// Read the focused window of the frontmost app. Returns elements
    /// in AX-tree iteration order (which is roughly visual order on
    /// most apps). Returns `[]` if AX permission is missing, the
    /// frontmost app doesn't expose AX, or the walk deadline trips
    /// before finding anything.
    func readFocusedWindow() -> [LocalVLMScreenElement] {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return []
        }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)

        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedWindowResult == .success,
              let focusedWindowObject = focusedWindowValue,
              CFGetTypeID(focusedWindowObject) == AXUIElementGetTypeID() else {
            return []
        }
        let focusedWindow = focusedWindowObject as! AXUIElement

        // Pixel scale for the screen the focused window lives on —
        // AX coordinates are in POINTS, screenshot pixels are in
        // PIXELS, and the rest of Pace's stack works in pixels.
        let pixelScaleFactor = pixelScaleFactorForScreen(containing: focusedWindow)

        let walkDeadline = Date(timeIntervalSinceNow: walkDeadlineSeconds)
        var collectedElements: [LocalVLMScreenElement] = []
        walkSubtree(
            of: focusedWindow,
            collectingInto: &collectedElements,
            pixelScaleFactor: pixelScaleFactor,
            deadline: walkDeadline
        )
        return collectedElements
    }

    // MARK: - Tree walk

    /// Depth-first walk that appends interesting elements to
    /// `collectedElements`. Bails when `deadline` trips so a slow app
    /// can't stall the caller; the elements gathered before the bail
    /// are still useful.
    private func walkSubtree(
        of element: AXUIElement,
        collectingInto collectedElements: inout [LocalVLMScreenElement],
        pixelScaleFactor: CGFloat,
        deadline: Date
    ) {
        guard Date() < deadline else { return }

        if let role = stringAttribute(kAXRoleAttribute as String, of: element),
           Self.interestingAXRoles.contains(role),
           let elementInPixels = makeScreenElement(
               from: element,
               role: role,
               pixelScaleFactor: pixelScaleFactor
           ) {
            collectedElements.append(elementInPixels)
        }

        var childrenValue: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard childrenResult == .success,
              let childrenArray = childrenValue as? [AXUIElement] else {
            return
        }

        for childElement in childrenArray {
            if Date() >= deadline { return }
            walkSubtree(
                of: childElement,
                collectingInto: &collectedElements,
                pixelScaleFactor: pixelScaleFactor,
                deadline: deadline
            )
        }
    }

    /// Pull frame + label + text content off one AX element and
    /// package it as a `LocalVLMScreenElement`. Returns nil for
    /// elements with no frame (off-screen, hidden) or no useful label.
    private func makeScreenElement(
        from element: AXUIElement,
        role: String,
        pixelScaleFactor: CGFloat
    ) -> LocalVLMScreenElement? {
        guard let pointFrame = frameAttribute(of: element),
              pointFrame.width > 1,
              pointFrame.height > 1 else {
            return nil
        }

        // AX coords are in points (top-left origin on the screen the
        // element lives on). Convert to screenshot pixels so the
        // planner prompt's coordinate space matches every other source.
        let pixelBoundingBox = [
            Int(pointFrame.origin.x * pixelScaleFactor),
            Int(pointFrame.origin.y * pixelScaleFactor),
            Int(pointFrame.size.width * pixelScaleFactor),
            Int(pointFrame.size.height * pixelScaleFactor)
        ]

        let shortLabel = labelFor(element: element, role: role)
        let verbatimText = verbatimTextFor(element: element, role: role)
        guard shortLabel != nil || verbatimText != nil else {
            // Nothing readable here. Skip — empty entries just bloat
            // the planner prompt.
            return nil
        }

        let translatedRole = Self.axRoleToScreenElementRole[role] ?? "other"
        return LocalVLMScreenElement(
            label: shortLabel ?? translatedRole,
            role: translatedRole,
            bbox: pixelBoundingBox,
            text: verbatimText
        )
    }

    /// Best-effort short label. AX exposes a handful of attributes
    /// for this; we take the first non-empty one in priority order.
    private func labelFor(element: AXUIElement, role: String) -> String? {
        let candidateAttributes = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXLabelValueAttribute as String,
            kAXHelpAttribute as String
        ]
        for attributeName in candidateAttributes {
            if let candidateValue = stringAttribute(attributeName, of: element),
               !candidateValue.isEmpty {
                let truncatedToTenWords = candidateValue
                    .split(separator: " ")
                    .prefix(10)
                    .joined(separator: " ")
                return truncatedToTenWords
            }
        }
        return nil
    }

    /// Verbatim text content for elements that contain text the user
    /// might want to reference. Skipped for buttons / images / etc.
    /// where the title is the meaningful label.
    private func verbatimTextFor(element: AXUIElement, role: String) -> String? {
        let rolesWithVerbatimText: Set<String> = [
            kAXStaticTextRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String
        ]
        guard rolesWithVerbatimText.contains(role) else { return nil }
        guard let valueString = stringAttribute(kAXValueAttribute as String, of: element),
              !valueString.isEmpty else {
            return nil
        }
        // Cap verbatim text at 60 chars — keeps headings / single
        // paragraphs but stops a giant TextView dumping a novel into
        // the planner prompt.
        if valueString.count > 60 {
            return String(valueString.prefix(60)) + "…"
        }
        return valueString
    }

    // MARK: - AX attribute helpers

    private func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        let resultCode = AXUIElementCopyAttributeValue(
            element,
            attributeName as CFString,
            &attributeValue
        )
        guard resultCode == .success, let attributeObject = attributeValue else {
            return nil
        }
        return attributeObject as? String
    }

    /// Reads `kAXPositionAttribute` + `kAXSizeAttribute` and returns a
    /// combined `CGRect`. Returns nil if either is missing or in the
    /// wrong type — common for purely-visual elements that don't
    /// expose a frame.
    private func frameAttribute(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        guard positionResult == .success, let positionRaw = positionValue,
              CFGetTypeID(positionRaw) == AXValueGetTypeID() else {
            return nil
        }
        var pointOrigin = CGPoint.zero
        AXValueGetValue(positionRaw as! AXValue, .cgPoint, &pointOrigin)

        var sizeValue: CFTypeRef?
        let sizeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        )
        guard sizeResult == .success, let sizeRaw = sizeValue,
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return nil
        }
        var pointSize = CGSize.zero
        AXValueGetValue(sizeRaw as! AXValue, .cgSize, &pointSize)

        return CGRect(origin: pointOrigin, size: pointSize)
    }

    /// Pixel scale (Retina factor) of the NSScreen the focused window
    /// is on. Falls back to the main screen if we can't resolve.
    private func pixelScaleFactorForScreen(containing focusedWindow: AXUIElement) -> CGFloat {
        guard let windowFrame = frameAttribute(of: focusedWindow) else {
            return NSScreen.main?.backingScaleFactor ?? 2.0
        }
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        // NSScreen frames are in BOTTOM-LEFT origin Cocoa coords on
        // the primary screen; we flip Y to compare with AX's top-left
        // origin. Use the primary-screen height for the flip.
        let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        let primaryHeight = primaryScreen?.frame.height ?? 0
        for candidateScreen in NSScreen.screens {
            // Convert NSScreen.frame to top-left-origin to match AX.
            let flippedScreenFrame = CGRect(
                x: candidateScreen.frame.origin.x,
                y: primaryHeight - candidateScreen.frame.origin.y - candidateScreen.frame.height,
                width: candidateScreen.frame.width,
                height: candidateScreen.frame.height
            )
            if flippedScreenFrame.contains(windowCenter) {
                return candidateScreen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }
}
