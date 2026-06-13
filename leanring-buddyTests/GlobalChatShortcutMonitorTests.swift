//
//  GlobalChatShortcutMonitorTests.swift
//  leanring-buddyTests
//
//  Unit tests for the pure shortcut-detection logic and the publisher
//  fan-out wiring inside `GlobalChatShortcutMonitor`. The actual
//  CGEvent tap is integration-only (requires Accessibility); these
//  tests exercise the deterministic helpers below it.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import Testing

@testable import Pace

@MainActor
struct GlobalChatShortcutMonitorTests {

    // MARK: - Shortcut-match helper

    @Test func detectsCommandShiftPOnKeyDownEvent() {
        // P key code is 35; both .command and .shift must be set.
        let modifierFlagsRawValue = UInt64(
            NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
        let isMatch = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: 35,
            modifierFlagsRawValue: modifierFlagsRawValue,
            eventType: .keyDown
        )
        #expect(isMatch == true)
    }

    @Test func ignoresKeyUpEvents() {
        let modifierFlagsRawValue = UInt64(
            NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
        let isMatch = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: 35,
            modifierFlagsRawValue: modifierFlagsRawValue,
            eventType: .keyUp
        )
        #expect(isMatch == false)
    }

    @Test func ignoresKeyDownWithoutBothModifiers() {
        // cmd alone is not the chat shortcut — that's the system cmd+P
        // (print) on most apps. We require both cmd and shift.
        let cmdOnlyFlags = UInt64(NSEvent.ModifierFlags([.command]).rawValue)
        let cmdOnly = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: 35,
            modifierFlagsRawValue: cmdOnlyFlags,
            eventType: .keyDown
        )
        #expect(cmdOnly == false)

        let shiftOnlyFlags = UInt64(NSEvent.ModifierFlags([.shift]).rawValue)
        let shiftOnly = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: 35,
            modifierFlagsRawValue: shiftOnlyFlags,
            eventType: .keyDown
        )
        #expect(shiftOnly == false)
    }

    @Test func ignoresKeyDownOnDifferentKeyCode() {
        // A key (key code 0) with cmd+shift is NOT the chat shortcut.
        let modifierFlagsRawValue = UInt64(
            NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
        let isMatch = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: 0,
            modifierFlagsRawValue: modifierFlagsRawValue,
            eventType: .keyDown
        )
        #expect(isMatch == false)
    }

    @Test func acceptsExtraModifiersBeyondTheRequiredSet() {
        // Power users sometimes have caps-lock or fn held when they
        // press the shortcut — the detector should still fire as long
        // as the required modifiers are present.
        let modifierFlagsRawValue = UInt64(
            NSEvent.ModifierFlags([.command, .shift, .function]).rawValue
        )
        let isMatch = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: 35,
            modifierFlagsRawValue: modifierFlagsRawValue,
            eventType: .keyDown
        )
        #expect(isMatch == true)
    }

    // MARK: - Publisher fan-out

    @Test func simulateShortcutPressedFiresPublisherExactlyOnce() async {
        let monitor = GlobalChatShortcutMonitor()
        var receivedSignalCount = 0
        let cancellable = monitor.chatShortcutPressed.sink { _ in
            receivedSignalCount += 1
        }

        monitor.simulateShortcutPressed()
        // Combine PassthroughSubject is synchronous, so the side-effect
        // should have fired by the time we inspect the counter.
        #expect(receivedSignalCount == 1)

        cancellable.cancel()
    }

    @Test func multipleSubscribersAllReceiveTheShortcutSignal() {
        let monitor = GlobalChatShortcutMonitor()
        var subscriberOneReceiveCount = 0
        var subscriberTwoReceiveCount = 0
        let cancellableOne = monitor.chatShortcutPressed.sink { _ in
            subscriberOneReceiveCount += 1
        }
        let cancellableTwo = monitor.chatShortcutPressed.sink { _ in
            subscriberTwoReceiveCount += 1
        }

        monitor.simulateShortcutPressed()
        monitor.simulateShortcutPressed()

        #expect(subscriberOneReceiveCount == 2)
        #expect(subscriberTwoReceiveCount == 2)

        cancellableOne.cancel()
        cancellableTwo.cancel()
    }
}
