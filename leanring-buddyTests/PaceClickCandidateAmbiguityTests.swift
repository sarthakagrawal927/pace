//
//  PaceClickCandidateAmbiguityTests.swift
//  leanring-buddyTests
//
//  Pure-logic tests for the visual-target ambiguity decision rule
//  (PRD docs/prds/hud-intent-disambiguator.md). The rule decides when
//  several near-tied click candidates should surface one short HUD
//  clarification question instead of silently auto-clicking the top one.
//

import Foundation
import Testing
@testable import Pace

struct PaceClickCandidateAmbiguityTests {
    private func candidate(
        label: String?,
        confidence: Double,
        screenshotX: Int = 100,
        screenshotY: Int = 100
    ) -> PaceClickCandidate {
        PaceClickCandidate(
            location: ScreenshotPixelLocation(
                xInScreenshotPixels: screenshotX,
                yInScreenshotPixels: screenshotY,
                screenNumber: 1
            ),
            label: label,
            confidence: confidence,
            expectStateChange: true
        )
    }

    @Test func clearWinnerReturnsNilSoAutoClickStaysZeroFriction() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Save", confidence: 0.90),
                candidate(label: "Save As", confidence: 0.55)
            ],
            clickCount: 1
        )

        // 0.35 lead is far above the 0.12 threshold — clear winner.
        #expect(PaceClickCandidateAmbiguity.isAmbiguous(candidateSet) == nil)
    }

    @Test func nearTiedDistinguishableLabelsReturnBothOptions() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Save", confidence: 0.62),
                candidate(label: "Save As", confidence: 0.58)
            ],
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)
        #expect(offeredCandidates?.count == 2)
        #expect(offeredCandidates?.first?.label == "Save")
        #expect(offeredCandidates?.last?.label == "Save As")
    }

    @Test func nearTiedOffersAreCappedAtThreeEvenWithMoreCandidates() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Reply", confidence: 0.64),
                candidate(label: "Reply All", confidence: 0.62),
                candidate(label: "Forward", confidence: 0.60),
                candidate(label: "Delete", confidence: 0.59)
            ],
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)
        #expect(offeredCandidates?.count == 3)
        #expect(offeredCandidates?.map(\.label) == ["Reply", "Reply All", "Forward"])
    }

    @Test func nearTiedIdenticalLabelsReturnNilBecauseOfferingSameTwiceHelpsNobody() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Save", confidence: 0.62, screenshotX: 100),
                candidate(label: "Save", confidence: 0.58, screenshotX: 400)
            ],
            clickCount: 1
        )

        #expect(PaceClickCandidateAmbiguity.isAmbiguous(candidateSet) == nil)
    }

    @Test func singleLabelledCandidateReturnsNil() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [candidate(label: "Save", confidence: 0.40)],
            clickCount: 1
        )

        #expect(PaceClickCandidateAmbiguity.isAmbiguous(candidateSet) == nil)
    }

    @Test func unlabelledNearTiedCandidatesReturnNilBecauseChipsWouldBeBlank() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: nil, confidence: 0.62, screenshotX: 100),
                candidate(label: "   ", confidence: 0.58, screenshotX: 400)
            ],
            clickCount: 1
        )

        #expect(PaceClickCandidateAmbiguity.isAmbiguous(candidateSet) == nil)
    }

    @Test func exactlyAtThresholdCountsAsClearWinner() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Save", confidence: 0.62),
                candidate(label: "Save As", confidence: 0.50)
            ],
            clickCount: 1
        )

        // Lead is exactly 0.12 — at/above threshold means clear winner.
        #expect(PaceClickCandidateAmbiguity.isAmbiguous(candidateSet) == nil)
    }

    @Test func clarificationBuilderMapsOptionsBackToCandidateIndices() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Save", confidence: 0.62, screenshotX: 100),
                candidate(label: "Save As", confidence: 0.58, screenshotX: 400)
            ],
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)
        let clarification = PaceClickTargetClarificationBuilder.makeClarification(
            offeredCandidates: offeredCandidates ?? [],
            in: candidateSet
        )

        #expect(clarification?.options.map(\.label) == ["Save", "Save As"])
        #expect(clarification?.options.map(\.candidateIndex) == [0, 1])

        let resolvedCandidate = clarification?.candidate(forSelectedOptionLabel: "Save As")
        #expect(resolvedCandidate?.label == "Save As")
        #expect(resolvedCandidate?.location?.xInScreenshotPixels == 400)
    }

    @Test func dismissFallbackPreservesFullOriginalCandidateSetForTopCandidateAutoClick() {
        // On dismiss/timeout the turn must fall back to the executor's
        // top-candidate auto-click. The pending clarification therefore
        // holds the FULL original candidate set (not just the offered
        // subset) so the existing scoring picks the best of everything.
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Reply", confidence: 0.62),
                candidate(label: "Reply All", confidence: 0.58),
                candidate(label: "Forward", confidence: 0.30)
            ],
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)
        // Only the two near-tied targets are offered…
        #expect(offeredCandidates?.count == 2)

        let pendingClarification = PacePendingClickTargetClarification(
            prompt: PaceClickTargetClarificationBuilder.defaultPrompt,
            options: (offeredCandidates ?? []).enumerated().map { index, candidate in
                PaceClickTargetOption(label: candidate.label ?? "", candidateIndex: index)
            },
            candidateSet: candidateSet,
            screenCaptures: []
        )

        // …but the held set still contains every candidate, so dismiss
        // can auto-click the executor's top pick across all of them.
        #expect(pendingClarification.candidateSet.candidates.count == 3)
    }

    @Test func unmatchedOptionLabelReturnsNilSoResolverCanFallBack() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Reply", confidence: 0.62),
                candidate(label: "Reply All", confidence: 0.58)
            ],
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)
        let clarification = PaceClickTargetClarificationBuilder.makeClarification(
            offeredCandidates: offeredCandidates ?? [],
            in: candidateSet
        )

        // A label that was never offered yields no candidate; the
        // CompanionManager resolver treats this as a fall-back to the
        // full original set's top-candidate auto-click.
        #expect(clarification?.candidate(forSelectedOptionLabel: "Forward") == nil)
    }

    @Test func clarificationResolverMatchesOptionLabelCaseInsensitively() {
        let candidateSet = PaceClickCandidateSet(
            candidates: [
                candidate(label: "Reply", confidence: 0.62),
                candidate(label: "Reply All", confidence: 0.58)
            ],
            clickCount: 1
        )

        let offeredCandidates = PaceClickCandidateAmbiguity.isAmbiguous(candidateSet)
        let clarification = PaceClickTargetClarificationBuilder.makeClarification(
            offeredCandidates: offeredCandidates ?? [],
            in: candidateSet
        )

        let resolvedCandidate = clarification?.candidate(forSelectedOptionLabel: "  reply all  ")
        #expect(resolvedCandidate?.label == "Reply All")
    }
}
