//
//  BuddyPlannerClient.swift
//  leanring-buddy
//
//  Shared protocol surface for the reasoning/planning model — the
//  cold-path LLM that takes the user's transcript + (optional) screen
//  context and produces pace's spoken response and action tags.
//
//  Conformers today:
//    - LocalPlannerClient          — text-only, LM Studio (default)
//    - AppleFoundationModelsPlannerClient — short on-device answer turns
//    - CloudBridgePlannerClient    — opt-in bridge to Claude/Codex/Gemini
//    - HybridPlannerClient         — routes per routingHintForNextCall
//
//  The protocol is intentionally kept generic so an alternate local
//  runtime (Ollama, raw llama.cpp, MLX-server) can drop in by writing
//  a new conformer — no other layer of the app would need to change.
//
//  Earlier versions had a cloud Claude conformer; that was removed
//  when the project committed to a no-cloud-LLM stance. CloudBridgePlannerClient
//  is the one deliberate opt-in exception — consent-gated and default-off.
//

import Foundation
import FoundationModels

// MARK: - Routing hint

/// Signals to `HybridPlannerClient` which tier this turn should use.
/// All other conformers ignore this — it is advisory only.
enum PaceLargeModelHint: Equatable {
    /// Keep this turn local (low latency, no cloud egress). Default for every
    /// turn that has not been explicitly flagged as needing a larger model.
    case preferLocal
    /// This turn may route to the cloud bridge (higher capability, higher
    /// latency). Used when `PaceIntentClassifier` returns `.phoneLargeModel`
    /// and the user has accepted the cloud-bridge consent dialog.
    case preferLarge
}

// MARK: - BuddyPlannerClient protocol

@MainActor
protocol BuddyPlannerClient: AnyObject {
    /// Human-readable name used in logs and the panel UI.
    var displayName: String { get }

    /// Whether this planner can consume screenshot images directly. False
    /// for the local 4B/8B reasoners which are text-only. Pipeline uses
    /// this to decide whether to even attach images.
    var supportsImageInput: Bool { get }

    /// Called at the start of each new user turn (PTT release with a
    /// fresh transcript). Implementations that hold cross-call state —
    /// notably Apple Foundation Models' stateful `LanguageModelSession`
    /// whose internal transcript accumulates unboundedly — reset that
    /// state here so the next turn starts within budget. Default no-op
    /// for stateless conformers.
    func resetForNewTurn()

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

extension BuddyPlannerClient {
    func resetForNewTurn() { /* default no-op for stateless conformers */ }
}

// MARK: - HybridPlannerClient

/// Wraps a local planner and a cloud-bridge planner.
/// The caller sets `routingHintForNextCall` before invoking
/// `generateResponseStreaming`; after each call it resets to `.preferLocal`
/// so forgetfulness always falls back to the safe local path.
@MainActor
final class HybridPlannerClient: BuddyPlannerClient {
    let displayName: String

    /// Images are supported only when the local planner supports them.
    /// The bridge always discards images regardless.
    var supportsImageInput: Bool { localPlannerClient.supportsImageInput }

    private let localPlannerClient: any BuddyPlannerClient
    private let cloudBridgePlannerClient: CloudBridgePlannerClient

    /// CompanionManager sets this to `.preferLarge` immediately before calling
    /// `generateResponseStreaming` for a `phoneLargeModel` turn, then the client
    /// resets it to `.preferLocal` after each call so the next turn stays local
    /// by default.
    var routingHintForNextCall: PaceLargeModelHint = .preferLocal

    init(
        localPlannerClient: any BuddyPlannerClient,
        cloudBridgePlannerClient: CloudBridgePlannerClient
    ) {
        self.localPlannerClient = localPlannerClient
        self.cloudBridgePlannerClient = cloudBridgePlannerClient
        self.displayName = "Hybrid (local + \(cloudBridgePlannerClient.displayName))"
    }

    func resetForNewTurn() {
        localPlannerClient.resetForNewTurn()
        cloudBridgePlannerClient.resetForNewTurn()
        // Do NOT reset routingHintForNextCall here — the caller sets it
        // immediately before the call, and resetForNewTurn is called at the
        // top of the turn before the routing decision is made.
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let currentHint = routingHintForNextCall
        // Always reset to local after consuming the hint so forgetfulness
        // at the call site defaults to the safe on-device path.
        routingHintForNextCall = .preferLocal

        switch currentHint {
        case .preferLarge:
            return try await cloudBridgePlannerClient.generateResponseStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .preferLocal:
            return try await localPlannerClient.generateResponseStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }
    }
}

// MARK: - BuddyPlannerClientFactory

enum BuddyPlannerClientFactory {
    private enum PlannerProvider: String {
        /// macOS 26 built-in 3B model via FoundationModels framework.
        /// Stateful session, KV cache persists across turns.
        /// Sub-second TTFT for short voice answers but loses on
        /// harder eval fixtures vs the larger LM Studio models.
        case appleFoundationModels = "appleFoundationModels"
        /// Local OpenAI-compatible endpoint (LM Studio at localhost:1234
        /// today). Current default — Qwen3-30B-A3B via LM Studio scored
        /// 15/15 on the FM eval set at 925ms mean.
        case local = "local"
    }

    /// Resolve the active planner from Info.plist key `PlannerProvider`,
    /// then layer the cloud-bridge mode on top if the user has consented.
    ///
    /// Priority order:
    ///   1. `alwaysBridge` + consent → CloudBridgePlannerClient (all turns go to bridge)
    ///   2. `hybrid` + consent       → HybridPlannerClient (bridge for preferLarge turns)
    ///   3. Anything else            → local planner from PlannerProvider (default behavior)
    ///
    /// **Falls back to LocalPlannerClient automatically when Foundation
    /// Models isn't available** — most commonly because the user
    /// hasn't enabled Apple Intelligence in System Settings.
    @MainActor
    static func makeDefault() -> any BuddyPlannerClient {
        let cloudBridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()

        // Gate: both conditions must be true before the bridge code path activates.
        // If the user somehow has a non-off mode saved but hasn't accepted the
        // consent dialog (e.g. from a previous install), we fall through to local.
        if cloudBridgeConfiguration.hasUserAcceptedConsent {
            switch cloudBridgeConfiguration.mode {
            case .alwaysBridge:
                let cloudBridgePlanner = CloudBridgePlannerClient(
                    configuration: cloudBridgeConfiguration
                )
                print("🧠 Planner: using \(cloudBridgePlanner.displayName) [alwaysBridge]")
                return cloudBridgePlanner

            case .hybrid:
                let localBaselineForHybrid = makeLocalOrFoundationModelsPlanner()
                let cloudBridgePlanner = CloudBridgePlannerClient(
                    configuration: cloudBridgeConfiguration
                )
                let hybridPlanner = HybridPlannerClient(
                    localPlannerClient: localBaselineForHybrid,
                    cloudBridgePlannerClient: cloudBridgePlanner
                )
                print("🧠 Planner: using \(hybridPlanner.displayName) [hybrid]")
                return hybridPlanner

            case .off:
                break
            }
        }

        // Default: no bridge. Use local planner from PlannerProvider.
        return makeLocalOrFoundationModelsPlanner()
    }

    // MARK: - Internal factory helpers

    @MainActor
    private static func makeLocalOrFoundationModelsPlanner() -> any BuddyPlannerClient {
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
        case .appleFoundationModels:
            return makeFoundationModelsPlannerOrFallback()
        case .none:
            // No PlannerProvider key — default to LocalPlannerClient
            // since the current shipped default in Info.plist is
            // PlannerProvider=local with Qwen3-30B-A3B.
            let localPlanner = LocalPlannerClient.makeFromInfoPlist()
            print("🧠 Planner: using \(localPlanner.displayName) (default)")
            return localPlanner
        }
    }

    /// Short answer turns are a different latency class from screen/action
    /// planning. Prefer Apple's in-process on-device model when it is
    /// available, even if the main planner remains LM Studio for harder
    /// fixtures. Fall back to the configured local planner when Apple
    /// Intelligence is unavailable or its model assets are not ready.
    @MainActor
    static func makeFastTextOnlyPlannerOrFallback() -> any BuddyPlannerClient {
        return makeFoundationModelsPlannerOrFallback()
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
            @unknown default:
                humanReadableReason = "Apple Foundation Models is unavailable"
                actionableHint = "Falling back to LM Studio for now."
            }
            print("⚠️  Planner: Foundation Models unavailable — \(humanReadableReason).")
            print("    → \(actionableHint)")
            let localPlanner = LocalPlannerClient.makeFromInfoPlist()
            print("🧠 Planner: using \(localPlanner.displayName)")
            return localPlanner
        }
    }
}
