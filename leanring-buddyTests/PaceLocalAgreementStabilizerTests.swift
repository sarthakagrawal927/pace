//
//  PaceLocalAgreementStabilizerTests.swift
//  leanring-buddyTests
//

import Testing

@testable import Pace

struct PaceLocalAgreementStabilizerTests {
    @Test func stabilizerEmitsOnlyWordsThatAgreeAcrossConsecutiveHypotheses() async throws {
        var stabilizer = PaceLocalAgreementStabilizer()

        #expect(stabilizer.acceptHypothesis("open the sa") == "")
        #expect(stabilizer.acceptHypothesis("open the save button") == "open the")
        #expect(stabilizer.acceptHypothesis("open the save dialog") == "open the save")
    }

    @Test func stabilizerNeverRetractsStablePrefixOnLaterDisagreement() async throws {
        var stabilizer = PaceLocalAgreementStabilizer()

        _ = stabilizer.acceptHypothesis("draft mail to")
        #expect(stabilizer.acceptHypothesis("draft mail to alex") == "draft mail to")
        #expect(stabilizer.acceptHypothesis("draft message for alex") == "draft mail to")
    }

    @Test func stabilizerNormalizesWhitespaceBeforeAgreement() async throws {
        #expect(PaceLocalAgreementStabilizer.commonPrefixByWord(
            "  make   this shorter ",
            "make this   more direct"
        ) == "make this")
    }
}
