//
//  PaceThermalStateAdvisorTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceThermalStateAdvisorTests {

    // MARK: - thermal-state → recommendation mapping

    @Test func nominalThermalStateMapsToUnrestricted() async throws {
        #expect(
            PaceThermalStateAdvisor.recommendation(forThermalState: .nominal) == .unrestricted
        )
    }

    @Test func fairThermalStateDampensTheSpeculativeRace() async throws {
        #expect(
            PaceThermalStateAdvisor.recommendation(forThermalState: .fair) == .dampenSpeculativeRace
        )
    }

    @Test func seriousThermalStateDampensBackgroundLoops() async throws {
        #expect(
            PaceThermalStateAdvisor.recommendation(forThermalState: .serious) == .dampenBackgroundLoops
        )
    }

    @Test func criticalThermalStateSuspendsBackground() async throws {
        #expect(
            PaceThermalStateAdvisor.recommendation(forThermalState: .critical) == .suspendBackground
        )
    }

    // MARK: - per-surface gates

    @Test func speculativeRaceGateOnlyRunsUnderUnrestricted() async throws {
        #expect(PaceThermalStateAdvisor.shouldRunSpeculativeRace(underRecommendation: .unrestricted))
        #expect(!PaceThermalStateAdvisor.shouldRunSpeculativeRace(underRecommendation: .dampenSpeculativeRace))
        #expect(!PaceThermalStateAdvisor.shouldRunSpeculativeRace(underRecommendation: .dampenBackgroundLoops))
        #expect(!PaceThermalStateAdvisor.shouldRunSpeculativeRace(underRecommendation: .suspendBackground))
    }

    @Test func proactiveSurfacesGateStaysOnUntilDampenBackgroundLoops() async throws {
        // We keep proactives running through `.dampenSpeculativeRace`
        // because that level is only about skipping the second
        // planner call — it doesn't reach background-loop territory.
        #expect(PaceThermalStateAdvisor.shouldRunProactiveSurfaces(underRecommendation: .unrestricted))
        #expect(PaceThermalStateAdvisor.shouldRunProactiveSurfaces(underRecommendation: .dampenSpeculativeRace))
        #expect(!PaceThermalStateAdvisor.shouldRunProactiveSurfaces(underRecommendation: .dampenBackgroundLoops))
        #expect(!PaceThermalStateAdvisor.shouldRunProactiveSurfaces(underRecommendation: .suspendBackground))
    }

    @Test func watchModeFullCadenceGateMatchesProactivesGate() async throws {
        // Same threshold semantics: watch mode is the heaviest of
        // the background loops, so the dampener trips at the same
        // recommendation that suppresses proactive surfaces.
        #expect(PaceThermalStateAdvisor.shouldRunWatchModeAtFullCadence(underRecommendation: .unrestricted))
        #expect(PaceThermalStateAdvisor.shouldRunWatchModeAtFullCadence(underRecommendation: .dampenSpeculativeRace))
        #expect(!PaceThermalStateAdvisor.shouldRunWatchModeAtFullCadence(underRecommendation: .dampenBackgroundLoops))
        #expect(!PaceThermalStateAdvisor.shouldRunWatchModeAtFullCadence(underRecommendation: .suspendBackground))
    }

    @Test func prewarmGateOnlySuspendsAtCriticalThreshold() async throws {
        // PTT prewarm is the cheapest of the background loops — it
        // runs at most once per PTT press. Stays on through
        // `.dampenBackgroundLoops` so the user's first PTT after
        // thermal pressure starts still feels snappy.
        #expect(PaceThermalStateAdvisor.shouldRunScreenContextPrewarm(underRecommendation: .unrestricted))
        #expect(PaceThermalStateAdvisor.shouldRunScreenContextPrewarm(underRecommendation: .dampenSpeculativeRace))
        #expect(PaceThermalStateAdvisor.shouldRunScreenContextPrewarm(underRecommendation: .dampenBackgroundLoops))
        #expect(!PaceThermalStateAdvisor.shouldRunScreenContextPrewarm(underRecommendation: .suspendBackground))
    }

    // MARK: - test seam

    @MainActor
    @Test func applyThermalStateForTestingDrivesPublishedRecommendation() async throws {
        let advisor = PaceThermalStateAdvisor()
        #expect(advisor.currentRecommendation == .unrestricted)
        advisor.applyThermalStateForTesting(.critical)
        #expect(advisor.currentRecommendation == .suspendBackground)
        advisor.applyThermalStateForTesting(.nominal)
        #expect(advisor.currentRecommendation == .unrestricted)
    }
}
