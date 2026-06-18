//
//  PaceBundledModelsSettingsTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceBundledModelsSettingsTests {

    // MARK: - Runtime status summary

    @Test func summaryWhenBothRuntimesPresent() async throws {
        let summary = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: true,
            embedderRuntimeAvailable: true
        )
        #expect(summary.contains("ready"))
    }

    @Test func summaryWhenNoRuntimesPresent() async throws {
        // First-launch state before the user adds the SPM
        // dependency. The summary must explicitly point them to
        // the Xcode step — silent "MLX unavailable" would leave
        // users wondering what to do.
        let summary = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: false,
            embedderRuntimeAvailable: false
        )
        #expect(summary.contains("Package Dependencies"))
        #expect(summary.contains("mlx-swift-examples"))
    }

    @Test func summaryWhenOnlyPlannerLinked() async throws {
        let summary = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: true,
            embedderRuntimeAvailable: false
        )
        #expect(summary.contains("planner linked"))
    }

    @Test func summaryWhenOnlyEmbedderLinked() async throws {
        let summary = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: false,
            embedderRuntimeAvailable: true
        )
        #expect(summary.contains("embedder linked"))
    }

    // MARK: - Default model identifiers

    @Test func compileTimeFallbackPlannerIsQwen3_4BInstruct() async throws {
        // Pinning the fallback in tests catches accidental swaps in
        // code review. The runtime default reads from Info.plist
        // first — see `defaultPlannerModelIdentifierPrefersInfoPlist`
        // below.
        #expect(PaceBundledModelsSettings.compileTimeFallbackPlannerModelIdentifier == "mlx-community/Qwen3-4B-Instruct-4bit")
    }

    @Test func compileTimeFallbackEmbedderIsNomicEmbedTextV1Point5() async throws {
        #expect(PaceBundledModelsSettings.compileTimeFallbackEmbedderModelIdentifier == "mlx-community/nomic-embed-text-v1.5")
    }

    @Test func defaultModelIdentifiersResolveToNonEmptyStrings() async throws {
        // Sanity: the Info.plist values in the production build are
        // present and non-blank. If a future release accidentally
        // clears them, this test catches it before users hit the
        // load failure.
        #expect(!PaceBundledModelsSettings.defaultPlannerModelIdentifier.isEmpty)
        #expect(!PaceBundledModelsSettings.defaultEmbedderModelIdentifier.isEmpty)
        #expect(!PaceBundledModelsSettings.defaultVLMModelIdentifier.isEmpty)
    }

    @Test func defaultPlannerIdentifierMatchesShippingDefault() async throws {
        // The shipping default in the Info.plist must be a model
        // identifier the eval-gate has been run against. If a future
        // Sparkle release bumps this — e.g. to `pace-ai/pace-planner-v1`
        // — the eval suite needs to be re-run against the new model
        // BEFORE the release goes out. This test acts as a pin so
        // bumps are deliberate (the test fails until updated).
        let shippingDefaults: Set<String> = [
            "mlx-community/Qwen3-4B-Instruct-4bit",
            // Add future pace-tuned identifiers here as they ship.
        ]
        #expect(shippingDefaults.contains(PaceBundledModelsSettings.defaultPlannerModelIdentifier))
    }

    // MARK: - Identifier validation

    @MainActor
    @Test func emptyOrWhitespaceIdentifierIsRefused() async throws {
        // Writing an empty identifier would brick the next inference
        // call. Refuse and keep the prior value.
        let original = PaceBundledModelsSettings.plannerModelIdentifier()
        PaceBundledModelsSettings.setPlannerModelIdentifier("")
        #expect(PaceBundledModelsSettings.plannerModelIdentifier() == original)
        PaceBundledModelsSettings.setPlannerModelIdentifier("   \t  ")
        #expect(PaceBundledModelsSettings.plannerModelIdentifier() == original)
    }
}
