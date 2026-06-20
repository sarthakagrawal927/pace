//
//  PaceStreamingPlannerFieldDetectorTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

struct PaceStreamingPlannerFieldDetectorTests {

    @Test func dictateTextStreamsIncrementally() async throws {
        let detector = PaceStreamingPlannerFieldDetector()

        let firstChange = detector.detectChange(in: """
        {"spokenText":"typing","intent":"dictate","payload":{"text":"Hel
        """)
        #expect(firstChange?.snapshot.kind == .dictateText)
        #expect(firstChange?.snapshot.text == "Hel")
        #expect(firstChange?.typingDelta == "Hel")

        let secondChange = detector.detectChange(in: """
        {"spokenText":"typing","intent":"dictate","payload":{"text":"Hello"}
        """)
        #expect(secondChange?.typingDelta == "lo")
    }

    @Test func editReplacementDetectsStreamingReplacement() async throws {
        let detector = PaceStreamingPlannerFieldDetector()
        let change = detector.detectChange(in: """
        {"spokenText":"editing","intent":"edit","payload":{"operation":"shorten","replacement":"Shorter"}
        """)
        #expect(change?.snapshot.kind == .editReplacement)
        #expect(change?.snapshot.text == "Shorter")
    }

    @Test func setValueDetectsStreamingAXValue() async throws {
        let detector = PaceStreamingPlannerFieldDetector()
        let change = detector.detectChange(in: """
        {"spokenText":"","intent":"action","payload":{"name":"AX.setValue","args":{"target":"focused","value":"Project sta
        """)
        #expect(change?.snapshot.kind == .setValue)
        #expect(change?.snapshot.text == "Project sta")
        #expect(change?.snapshot.setValueTarget == .focused)
    }

    @Test func unrelatedIntentDoesNotEmitChanges() async throws {
        let detector = PaceStreamingPlannerFieldDetector()
        #expect(detector.detectChange(in: """
        {"spokenText":"hi","intent":"answer","payload":{"answer":"HTML is markup."}}
        """) == nil)
    }
}
