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
    private static let useBundledMLXVLMKey = "pace.bundledModels.useMLXInProcessVLM"
    private static let useBundledQwen3TTSKey = "pace.bundledModels.useQwen3TTSInProcess"
    private static let bundledPlannerModelKey = "pace.bundledModels.plannerModelIdentifier"
    private static let bundledEmbedderModelKey = "pace.bundledModels.embedderModelIdentifier"
    private static let bundledVLMModelKey = "pace.bundledModels.vlmModelIdentifier"

    // Compile-time fallback identifiers. Used when:
    //   - The corresponding Info.plist key is missing (e.g. running
    //     from a dev build that hasn't been updated yet)
    //   - The Info.plist value is blank
    //
    // The Info.plist keys (BundledMLXPlannerModelIdentifier etc.)
    // are the SHIPPING surface. Future releases bump those keys to
    // point at Pace-tuned models (e.g. `pace-ai/pace-planner-v1`)
    // without touching this source file.
    nonisolated static let compileTimeFallbackPlannerModelIdentifier = "mlx-community/Qwen3-4B-Instruct-2507-bf16"

    // Fast Mode preset — the 4-bit variant of the same checkpoint.
    // ~2x faster inference (less memory bandwidth on the same
    // weights), ~3x less RAM (fits comfortably on 16 GB Macs),
    // ~1-2 points lower on the FM-fixture eval set. Exposed as a
    // one-click preset in Settings → Models.
    nonisolated static let fastModePlannerModelIdentifier = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    nonisolated static let compileTimeFallbackEmbedderModelIdentifier = "mlx-community/nomic-embed-text-v1.5"
    nonisolated static let compileTimeFallbackVLMModelIdentifier = "mlx-community/Qwen3-VL-4B-Instruct-4bit"

    // The default-identifier accessors prefer the Info.plist
    // manifest, falling back to the compile-time constants when
    // unset. This lets a Sparkle release push a new bundled-model
    // default by updating the Info.plist alone — no code change to
    // this file.
    nonisolated static var defaultPlannerModelIdentifier: String {
        let infoPlistDefault = modelIdentifierFromInfoPlist(key: "BundledMLXPlannerModelIdentifier")
            ?? compileTimeFallbackPlannerModelIdentifier
        return PaceRemoteModelManifest.resolvedPlannerModelIdentifier(fallback: infoPlistDefault)
    }
    nonisolated static var defaultEmbedderModelIdentifier: String {
        let infoPlistDefault = modelIdentifierFromInfoPlist(key: "BundledMLXEmbedderModelIdentifier")
            ?? compileTimeFallbackEmbedderModelIdentifier
        return PaceRemoteModelManifest.resolvedEmbedderModelIdentifier(fallback: infoPlistDefault)
    }
    nonisolated static var defaultVLMModelIdentifier: String {
        let infoPlistDefault = modelIdentifierFromInfoPlist(key: "BundledMLXVLMModelIdentifier")
            ?? compileTimeFallbackVLMModelIdentifier
        return PaceRemoteModelManifest.resolvedVLMModelIdentifier(fallback: infoPlistDefault)
    }

    nonisolated private static func modelIdentifierFromInfoPlist(key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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

    // MARK: - VLM (Phase C)

    static func isUsingMLXInProcessVLM() -> Bool {
        guard PaceMLXScreenAnalysisClient.isRuntimeAvailable else { return false }
        return UserDefaults.standard.bool(forKey: useBundledMLXVLMKey)
    }

    static func setUsingMLXInProcessVLM(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: useBundledMLXVLMKey)
    }

    static func vlmModelIdentifier() -> String {
        UserDefaults.standard.string(forKey: bundledVLMModelKey) ?? defaultVLMModelIdentifier
    }

    static func setVLMModelIdentifier(_ identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: bundledVLMModelKey)
    }

    // MARK: - TTS (Phase D — Qwen3 TTS via WhisperKit TTSKit)

    static func isUsingQwen3TTSInProcess() -> Bool {
        guard PaceQwen3TTSClient.isRuntimeAvailable else { return false }
        return UserDefaults.standard.bool(forKey: useBundledQwen3TTSKey)
    }

    static func setUsingQwen3TTSInProcess(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: useBundledQwen3TTSKey)
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
