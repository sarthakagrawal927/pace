//
//  PaceProviderCostEstimatorTests.swift
//  leanring-buddyTests
//
//  Pure tests for the rate-card lookup that powers the audit log's
//  cost column. No network, no model inference — just math against a
//  static dictionary of per-million-tokens rates.
//

import Foundation
import Testing
@testable import Pace

struct PaceProviderCostEstimatorTests {

    // MARK: - estimatedCostInDollars

    @Test func anthropicOpusRoundTripsKnownRate() async throws {
        // 1k input × $15/1M + 8k output × $75/1M = $0.015 + $0.6 = $0.615
        let estimatedCost = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "anthropic/claude-opus-4-7",
            inputTokenCount: 1_000,
            outputTokenCount: 8_000
        )
        try #require(estimatedCost != nil)
        #expect(abs(estimatedCost! - 0.615) < 0.0001)
    }

    @Test func openAIGPT4oMiniRoundTripsKnownRate() async throws {
        // 10k input × $0.15/1M + 5k output × $0.60/1M = $0.0015 + $0.003 = $0.0045
        let estimatedCost = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "openai/gpt-4o-mini",
            inputTokenCount: 10_000,
            outputTokenCount: 5_000
        )
        try #require(estimatedCost != nil)
        #expect(abs(estimatedCost! - 0.0045) < 0.0001)
    }

    @Test func unknownTargetReturnsNilCost() async throws {
        // Target Pace will write for any future / unmapped model.
        // We deliberately don't guess — the audit row reads "—".
        let estimatedCost = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "anthropic/some-future-model-id",
            inputTokenCount: 1_000,
            outputTokenCount: 1_000
        )
        #expect(estimatedCost == nil)
    }

    @Test func nilTokenCountsReturnNilCost() async throws {
        // Local-planner rows (target = e.g. "qwen/qwen3-30b-a3b")
        // never carry token counts because they're free. The cost
        // column must read "—" rather than show a meaningless $0.
        let estimatedCostMissingInput = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "anthropic/claude-opus-4-7",
            inputTokenCount: nil,
            outputTokenCount: 100
        )
        let estimatedCostMissingOutput = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "anthropic/claude-opus-4-7",
            inputTokenCount: 100,
            outputTokenCount: nil
        )
        let estimatedCostMissingBoth = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "anthropic/claude-opus-4-7",
            inputTokenCount: nil,
            outputTokenCount: nil
        )
        #expect(estimatedCostMissingInput == nil)
        #expect(estimatedCostMissingOutput == nil)
        #expect(estimatedCostMissingBoth == nil)
    }

    @Test func negativeTokenCountsReturnNilCost() async throws {
        // Defensive — if some future upstream returns -1 as a sentinel
        // for "couldn't measure," we treat that as "no data" rather
        // than feeding a negative number into the multiplication.
        let estimatedCost = PaceProviderCostEstimator.estimatedCostInDollars(
            target: "anthropic/claude-opus-4-7",
            inputTokenCount: -1,
            outputTokenCount: 100
        )
        #expect(estimatedCost == nil)
    }

    // MARK: - formatCostInDollars

    @Test func formatCostUsesApproximateMarkerAlways() async throws {
        let formatted = PaceProviderCostEstimator.formatCostInDollars(0.42)
        #expect(formatted.hasPrefix("~"))
    }

    @Test func formatCostUnderOneCentReadsAsLessThanOneCent() async throws {
        // A 1-token turn shouldn't read as "$0.00" — the user would
        // think it was free. Show "<$0.01" so the cost is visible.
        let formatted = PaceProviderCostEstimator.formatCostInDollars(0.0005)
        #expect(formatted == "~<$0.01")
    }

    @Test func formatCostFractionalDollarsKeepsTwoDecimalPlaces() async throws {
        #expect(PaceProviderCostEstimator.formatCostInDollars(0.42) == "~$0.42")
        #expect(PaceProviderCostEstimator.formatCostInDollars(3.50) == "~$3.50")
    }

    @Test func formatCostMultiDollarRoundsToWhole() async throws {
        // Past $10 the cents stop mattering — show the round dollar
        // so the column doesn't grow wider on a runaway research turn.
        #expect(PaceProviderCostEstimator.formatCostInDollars(42.7) == "~$43")
    }

    // MARK: - formatTokenCounts

    @Test func formatTokenCountsCompactsAboveOneThousand() async throws {
        let formatted = PaceProviderCostEstimator.formatTokenCounts(
            inputTokenCount: 1_234,
            outputTokenCount: 8_400
        )
        #expect(formatted == "1.2k/8.4k")
    }

    @Test func formatTokenCountsKeepsRawNumberUnderOneThousand() async throws {
        let formatted = PaceProviderCostEstimator.formatTokenCounts(
            inputTokenCount: 850,
            outputTokenCount: 200
        )
        #expect(formatted == "850/200")
    }

    @Test func formatTokenCountsUsesEmDashForMissingHalf() async throws {
        let formatted = PaceProviderCostEstimator.formatTokenCounts(
            inputTokenCount: 100,
            outputTokenCount: nil
        )
        #expect(formatted == "100/—")
    }

    @Test func formatTokenCountsReturnsNilWhenBothMissing() async throws {
        // Local-planner rows have neither count — the column should
        // skip them entirely so it doesn't read as "—/—" on every row.
        let formatted = PaceProviderCostEstimator.formatTokenCounts(
            inputTokenCount: nil,
            outputTokenCount: nil
        )
        #expect(formatted == nil)
    }

    @Test func formatTokenCountsRoundsAboveTenThousand() async throws {
        // 12_800 → 12.8k → "13k" (round half up).
        // 99_700 → 99.7k → "100k". Avoid the .5 banker's-rounding
        // edge cases — they're irrelevant to the user-visible behavior
        // we're pinning.
        let formatted = PaceProviderCostEstimator.formatTokenCounts(
            inputTokenCount: 12_800,
            outputTokenCount: 99_700
        )
        #expect(formatted == "13k/100k")
    }

    // MARK: - Rate card sanity

    @Test func ratesCoverAllTiersResearchDefaultsAt() async throws {
        // The research-tier default is Anthropic Opus 4.7. If that
        // rate ever drops out of the card, the audit log goes silent
        // on cost for the user's most expensive turns.
        #expect(PaceProviderCostEstimator.knownRates["anthropic/claude-opus-4-7"] != nil)
    }

    @Test func everyRateIsPositive() async throws {
        for (target, rate) in PaceProviderCostEstimator.knownRates {
            #expect(rate.inputRatePerMillionTokens > 0, "input rate for \(target) must be positive")
            #expect(rate.outputRatePerMillionTokens > 0, "output rate for \(target) must be positive")
        }
    }

    @Test func outputRatesNeverCheaperThanInput() async throws {
        // Anthropic + OpenAI both charge output > input. If a future
        // entry inverts that, it's almost certainly a typo.
        for (target, rate) in PaceProviderCostEstimator.knownRates {
            #expect(
                rate.outputRatePerMillionTokens >= rate.inputRatePerMillionTokens,
                "\(target) has output rate cheaper than input — likely a typo"
            )
        }
    }
}
