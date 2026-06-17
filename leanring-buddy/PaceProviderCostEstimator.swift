//
//  PaceProviderCostEstimator.swift
//  leanring-buddy
//
//  Pure helper that turns a (provider/model target, input tokens,
//  output tokens) triple into an estimated USD cost. Used by the
//  Privacy Dashboard's audit-log table to surface a ~$0.42 column
//  next to Direct API rows so the user sees what a research turn
//  actually cost.
//
//  Rate data is a hardcoded snapshot taken at branch-author time. It
//  WILL go stale as providers shift pricing — we surface "~$X.XX"
//  with an explicit ~ to set the expectation. The audit log carries
//  authoritative token counts; this estimator is for the casual
//  glance, not invoicing.
//
//  Adding a new model: append a rate to `knownRates`. Unknown models
//  return nil cost — the audit-log row still shows the raw token
//  counts but the cost column reads "—".
//

import Foundation

/// One model's per-million-tokens cost in USD. Captures both the input
/// and output rates because every modern provider bills them
/// asymmetrically.
nonisolated struct PaceProviderCostRate: Equatable {
    let inputRatePerMillionTokens: Double
    let outputRatePerMillionTokens: Double
}

nonisolated enum PaceProviderCostEstimator {

    /// Per-model rate card. Targets are the same strings the
    /// DirectAPIPlannerClient writes into its audit-log target field:
    /// `"<provider>/<model-id>"`. Keep these conservative — the user
    /// reads the audit log expecting a ballpark, not a billing
    /// statement.
    ///
    /// Sources (snapshot at branch-author time — verify before
    /// shipping rate-sensitive UI):
    ///   - Anthropic public pricing page
    ///   - OpenAI public pricing page
    ///   - OpenRouter routes to a specific provider; we charge the
    ///     underlying provider's rate when we can map it.
    static let knownRates: [String: PaceProviderCostRate] = [
        // Anthropic — Claude Opus 4.7 (the research-tier default).
        "anthropic/claude-opus-4-7": PaceProviderCostRate(
            inputRatePerMillionTokens: 15.0,
            outputRatePerMillionTokens: 75.0
        ),
        // Anthropic — Sonnet 4.5 / 4.6 (current main-planner defaults).
        "anthropic/claude-sonnet-4-5-20251001": PaceProviderCostRate(
            inputRatePerMillionTokens: 3.0,
            outputRatePerMillionTokens: 15.0
        ),
        "anthropic/claude-sonnet-4-6": PaceProviderCostRate(
            inputRatePerMillionTokens: 3.0,
            outputRatePerMillionTokens: 15.0
        ),
        // OpenAI.
        "openai/gpt-4o-mini": PaceProviderCostRate(
            inputRatePerMillionTokens: 0.15,
            outputRatePerMillionTokens: 0.60
        ),
        "openai/gpt-4o": PaceProviderCostRate(
            inputRatePerMillionTokens: 2.50,
            outputRatePerMillionTokens: 10.0
        ),
        // OpenRouter — the Sonnet route is the most common one we set
        // as a planner default. Other OpenRouter routes return nil
        // (the user pays through OpenRouter's own dashboard anyway).
        "openrouter/anthropic/claude-sonnet-4": PaceProviderCostRate(
            inputRatePerMillionTokens: 3.0,
            outputRatePerMillionTokens: 15.0
        )
    ]

    /// Returns the USD cost estimate for one audit entry's token
    /// counts, or nil when either token count is missing OR the
    /// target model has no rate-card entry. The display layer reads
    /// nil as "—" rather than "$0".
    static func estimatedCostInDollars(
        target: String,
        inputTokenCount: Int?,
        outputTokenCount: Int?
    ) -> Double? {
        guard let inputTokenCount, let outputTokenCount,
              inputTokenCount >= 0, outputTokenCount >= 0,
              let rate = knownRates[target] else {
            return nil
        }
        let inputCost = Double(inputTokenCount) * rate.inputRatePerMillionTokens / 1_000_000.0
        let outputCost = Double(outputTokenCount) * rate.outputRatePerMillionTokens / 1_000_000.0
        return inputCost + outputCost
    }

    /// Display string for a cost estimate. Keeps the leading `~` so
    /// the user reads "approximately" rather than "exactly". Sub-cent
    /// costs round to `<$0.01` so a tiny research turn doesn't read
    /// as free.
    static func formatCostInDollars(_ estimatedCost: Double) -> String {
        if estimatedCost < 0.01 {
            return "~<$0.01"
        }
        if estimatedCost < 1.0 {
            return String(format: "~$%.2f", estimatedCost)
        }
        if estimatedCost < 10.0 {
            return String(format: "~$%.2f", estimatedCost)
        }
        return String(format: "~$%.0f", estimatedCost)
    }

    /// Compact "1.2k/8.4k" token display for the audit-log table.
    /// Returns nil when both counts are absent — the column reads
    /// "—" then. Local-planner / VLM / TTS subsystems never set
    /// token counts, so most rows in the table will be nil.
    static func formatTokenCounts(
        inputTokenCount: Int?,
        outputTokenCount: Int?
    ) -> String? {
        guard inputTokenCount != nil || outputTokenCount != nil else { return nil }
        let inputDisplay = formatTokenCount(inputTokenCount)
        let outputDisplay = formatTokenCount(outputTokenCount)
        return "\(inputDisplay)/\(outputDisplay)"
    }

    private static func formatTokenCount(_ tokenCount: Int?) -> String {
        guard let tokenCount, tokenCount >= 0 else { return "—" }
        if tokenCount < 1_000 {
            return "\(tokenCount)"
        }
        let thousands = Double(tokenCount) / 1_000.0
        if thousands < 10 {
            return String(format: "%.1fk", thousands)
        }
        return String(format: "%.0fk", thousands)
    }
}
