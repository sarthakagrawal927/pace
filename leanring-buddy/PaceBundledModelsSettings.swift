//
//  PaceBundledModelsSettings.swift
//  leanring-buddy
//
//  User-facing toggle + model-identifier configuration for the
//  in-process MLX runtime. Pure state — actual model loading lives
//  in PaceMLXPlannerClient / PaceMLXEmbeddingClient.
//
//  Default posture: OFF. Existing users stay on LM Studio / Apple FM
//  byte-identically. New users + opted-in power users get the
//  bundled experience that doesn't need LM Studio installed.
//
//  Why a separate module instead of folding into
//  PaceUserPreferencesStore: keeping bundled-MLX state isolated lets
//  the factory wiring read just this surface, and lets the Settings
//  → Models tab render without crossing the larger preferences
//  surface. Mirrors how PacePlannerTierStore is structured.
//

import Foundation

nonisolated enum PaceBundledModelsSettings {

    /// UserDefaults key namespace. Kept under a single prefix so a
    /// future "clear bundled-model state" reset command can wipe
    /// the right thing.
    private static let useBundledMLXKey = "pace.bundledModels.useMLXInProcessPlanner"
    private static let useBundledMLXEmbedderKey = "pace.bundledModels.useMLXInProcessEmbedder"
    private static let bundledPlannerModelKey = "pace.bundledModels.plannerModelIdentifier"
    private static let bundledEmbedderModelKey = "pace.bundledModels.embedderModelIdentifier"

    nonisolated static let defaultPlannerModelIdentifier = "mlx-community/Qwen3-4B-Instruct-4bit"
    nonisolated static let defaultEmbedderModelIdentifier = "mlx-community/nomic-embed-text-v1.5"

    /// True when the user has opted in AND the runtime is linked.
    /// The runtime check uses `PaceMLXPlannerClient.isRuntimeAvailable`
    /// so a missing SPM dependency silently flips the answer to
    /// false — saving the factory from instantiating a client that
    /// would throw on every call.
    static func isUsingMLXInProcessPlanner() -> Bool {
        guard PaceMLXPlannerClient.isRuntimeAvailable else { return false }
        return UserDefaults.standard.bool(forKey: useBundledMLXKey)
    }

    static func setUsingMLXInProcessPlanner(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: useBundledMLXKey)
    }

    static func isUsingMLXInProcessEmbedder() -> Bool {
        guard PaceMLXEmbeddingClient.isRuntimeAvailable else { return false }
        return UserDefaults.standard.bool(forKey: useBundledMLXEmbedderKey)
    }

    static func setUsingMLXInProcessEmbedder(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: useBundledMLXEmbedderKey)
    }

    static func plannerModelIdentifier() -> String {
        UserDefaults.standard.string(forKey: bundledPlannerModelKey) ?? defaultPlannerModelIdentifier
    }

    static func setPlannerModelIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: bundledPlannerModelKey)
    }

    static func embedderModelIdentifier() -> String {
        UserDefaults.standard.string(forKey: bundledEmbedderModelKey) ?? defaultEmbedderModelIdentifier
    }

    static func setEmbedderModelIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: bundledEmbedderModelKey)
    }

    /// Runtime-availability summary surfaced by the Settings UI.
    /// Tells the user at a glance whether the SPM dependency is
    /// linked. Pure helper for unit testing — the real check uses
    /// the static `isRuntimeAvailable` of each client.
    nonisolated static func runtimeStatusSummary(
        plannerRuntimeAvailable: Bool,
        embedderRuntimeAvailable: Bool
    ) -> String {
        switch (plannerRuntimeAvailable, embedderRuntimeAvailable) {
        case (true, true):
            return "MLX runtime linked — bundled models ready"
        case (true, false):
            return "MLX planner linked; embedder runtime missing"
        case (false, true):
            return "MLX embedder linked; planner runtime missing"
        case (false, false):
            return "MLX runtime not linked. Add mlx-swift-examples to Package Dependencies in Xcode."
        }
    }
}
