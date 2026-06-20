//
//  PaceActionExecutor+Keyboard.swift
//  leanring-buddy
//
//  Extracted from PaceActionExecutor.swift (god-class decomposition Phase B):
//  type, set text, edit selection, undo, key press, MCP tool calls.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
extension PaceActionExecutor {

    // MARK: - Keyboard

    // MARK: - Keyboard

    func typeText(_ textToType: String) async {
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

    func setTextValue(_ request: PaceSetTextValueRequest) -> PaceActionExecutionObservation {
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

    func editSelectedText(_ request: PaceVoiceEditRequest) -> PaceActionExecutionObservation {
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

    func undoLastMutation() -> PaceActionExecutionObservation {
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

    func stringValue(of focusedElement: AXUIElement) -> String? {
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

    func selectedTextReplacement(
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

    func selectedText(
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

    func pressKey(named keyName: String, withModifiers modifiers: [PaceKeyboardModifier]) async {
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

    func callMCPTool(_ mcpToolCall: PaceMCPToolCall) async -> PaceActionExecutionObservation {
        let toolObservationName = "mcp.\(mcpToolCall.serverName).\(mcpToolCall.toolName)"

        guard actionsAreEnabled else {
            return PaceActionExecutionObservation(
                toolName: toolObservationName,
                summary: "Would call MCP tool: \(mcpToolCall.approvalDescription)"
            )
        }

        // Hosted-MCP detection: when this MCP server routes through a
        // hosted gateway (e.g. Composio), the menu-bar capsule should
        // tint amber for the duration of the call to match Direct API
        // and Cloud Bridge behavior. Local stdio servers (filesystem,
        // applescript, fetch) leave the tint alone.
        let isHostedMCPServer = PacePrivacyDashboardAggregator
            .knownOffDeviceMCPServerSlugs
            .contains(mcpToolCall.serverName.lowercased())
        if isHostedMCPServer {
            setOffDeviceTurnInFlightCallback(true)
        }
        defer {
            if isHostedMCPServer {
                setOffDeviceTurnInFlightCallback(false)
            }
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
