//
//  PaceFocusModeMonitorTests.swift
//  leanring-buddyTests
//
//  The live INFocusStatusCenter binding can't be tested without
//  process-level permission; what we CAN pin is the pure mapping
//  from "framework returned nil because permission denied" to
//  "treat as not focused, do not silently overcautious-defer."
//

import Foundation
import Testing
@testable import Pace

struct PaceFocusModeMonitorTests {

    @Test func mapsTrueFrameworkReadingToIsFocused() async throws {
        #expect(PaceFocusModeMonitor.resolveIsFocusedFromFrameworkReading(true) == true)
    }

    @Test func mapsFalseFrameworkReadingToNotFocused() async throws {
        #expect(PaceFocusModeMonitor.resolveIsFocusedFromFrameworkReading(false) == false)
    }

    @Test func mapsNilFrameworkReadingToNotFocused() async throws {
        // Nil means "we have no permission to read." If we mapped
        // this to true ("assume focused, stay quiet"), Pace would
        // silently stop speaking the moment the user denied the
        // permission — which would be indistinguishable from a bug.
        // Mapping to false means denied-permission users get the
        // pre-Focus-integration behavior with no surprises.
        #expect(PaceFocusModeMonitor.resolveIsFocusedFromFrameworkReading(nil) == false)
    }
}
