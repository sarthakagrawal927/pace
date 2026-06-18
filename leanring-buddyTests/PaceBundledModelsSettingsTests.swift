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

    @Test func defaultPlannerIsQwen3_4BInstruct() async throws {
        // The default model is part of the bundled-models contract:
        // if it changes, the eval-gate fixtures need to be re-run.
        // Pinning it in tests catches accidental swaps in code review.
        #expect(PaceBundledModelsSettings.defaultPlannerModelIdentifier == "mlx-community/Qwen3-4B-Instruct-4bit")
    }

    @Test func defaultEmbedderIsNomicEmbedTextV1Point5() async throws {
        #expect(PaceBundledModelsSettings.defaultEmbedderModelIdentifier == "mlx-community/nomic-embed-text-v1.5")
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
