//
//  BuddyPlannerClient.swift
//  leanring-buddy
//
//  Shared protocol surface for the reasoning/planning model — the
//  cold-path LLM that takes the user's transcript + (optional) screen
//  context and produces pace's spoken response and action tags.
//
//  Only one conformer ships today: `LocalPlannerClient` (text-only,
//  talks to a local OpenAI-compatible reasoner like LM Studio).
//
//  The protocol is intentionally kept generic so an alternate local
//  runtime (Ollama, raw llama.cpp, MLX-server) can drop in by writing
//  a new conformer — no other layer of the app would need to change.
//
//  Earlier versions had a cloud Claude conformer; that was removed
//  when the project committed to a no-cloud-LLM stance.
//

import Foundation
import FoundationModels

@MainActor
protocol BuddyPlannerClient: AnyObject {
    /// Human-readable name used in logs and the panel UI.
    var displayName: String { get }

    /// Whether this planner can consume screenshot images directly. False
    /// for the local 4B/8B reasoners which are text-only. Pipeline uses
    /// this to decide whether to even attach images.
    var supportsImageInput: Bool { get }

    /// Generate the next assistant turn as a streamed text response.
    /// `images` are passed only when `supportsImageInput` is true. The
    /// returned text is the full accumulated response after the stream
    /// completes; `onTextChunk` is called progressively for UI display.
    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

enum BuddyPlannerClientFactory {
    private enum PlannerProvider: String {
        /// macOS 26 built-in 3B model via FoundationModels framework.
        /// Stateful session, KV cache persists across turns. Default —
        /// fastest path for short voice answers.
        case appleFoundationModels = "appleFoundationModels"
        /// Local OpenAI-compatible endpoint (LM Studio at localhost:1234
        /// today). Bigger models, slower TTFT. Use when Foundation
        /// Models' 3B reasoning isn't enough.
        case local = "local"
    }

    /// Resolve the active planner from Info.plist key `PlannerProvider`.
    /// Default is `appleFoundationModels` since macOS 26+ is the
    /// supported floor and Foundation Models gives sub-second TTFT
    /// for free. Set to `local` to route through LocalPlannerClient
    /// (LM Studio) when you need a bigger model.
    ///
    /// **Falls back to LocalPlannerClient automatically when Foundation
    /// Models isn't available** — most commonly because the user
    /// hasn't enabled Apple Intelligence in System Settings. We don't
    /// silently degrade: a clear log line tells the user what to do.
    @MainActor
    static func makeDefault() -> any BuddyPlannerClient {
        let configuredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "PlannerProvider")?
            .lowercased()
        let configuredProvider = configuredProviderRawValue
            .flatMap(PlannerProvider.init(rawValue:))

        switch configuredProvider {
        case .local:
            let localPlanner = LocalPlannerClient.makeFromInfoPlist()
            print("🧠 Planner: using \(localPlanner.displayName)")
            return localPlanner
        case .appleFoundationModels, .none:
            return makeFoundationModelsPlannerOrFallback()
        }
    }

    /// Construct the Foundation Models planner only if `SystemLanguageModel
    /// .default.availability == .available`. Otherwise log an actionable
    /// message and fall back to LocalPlannerClient so the user isn't
    /// stuck staring at "Apple Intelligence is not enabled" errors mid-
    /// voice-turn.
    @MainActor
    private static func makeFoundationModelsPlannerOrFallback() -> any BuddyPlannerClient {
        let systemLanguageModel = SystemLanguageModel.default
        switch systemLanguageModel.availability {
        case .available:
            let foundationModelsPlanner = AppleFoundationModelsPlannerClient()
            print("🧠 Planner: using \(foundationModelsPlanner.displayName)")
            return foundationModelsPlanner
        case .unavailable(let unavailableReason):
            let humanReadableReason: String
            let actionableHint: String
            switch unavailableReason {
            case .deviceNotEligible:
                humanReadableReason = "this Mac isn't eligible for Apple Intelligence"
                actionableHint = "Pace's Foundation Models fast path needs an M1 or newer with ≥8GB RAM. Falling back to LM Studio (`LocalPlannerClient`)."
            case .appleIntelligenceNotEnabled:
                humanReadableReason = "Apple Intelligence is not enabled"
                actionableHint = "Open System Settings → Apple Intelligence & Siri → turn Apple Intelligence on, wait for the ~3GB model download to finish, then relaunch Pace. Falling back to LM Studio for now."
            case .modelNotReady:
                humanReadableReason = "the on-device model is still downloading"
                actionableHint = "Apple Intelligence is enabled but the model assets aren't ready yet. Wait a few minutes for the download to finish, then relaunch Pace. Falling back to LM Studio for now."
            }
            print("⚠️  Planner: Foundation Models unavailable — \(humanReadableReason).")
            print("    → \(actionableHint)")
            let localPlanner = LocalPlannerClient.makeFromInfoPlist()
            print("🧠 Planner: using \(localPlanner.displayName)")
            return localPlanner
        }
    }
}
