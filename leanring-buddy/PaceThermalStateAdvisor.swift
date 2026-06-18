//
//  PaceThermalStateAdvisor.swift
//  leanring-buddy
//
//  Reads `ProcessInfo.processInfo.thermalState` and turns it into a
//  small typed recommendation other modules can act on without each
//  having to know what `.fair` / `.serious` / `.critical` mean for
//  Pace's particular workload mix.
//
//  Pace runs a lot in parallel: VLM (Qwen3-VL-8B), planner (qwen3-
//  30b-a3b or Apple FM), TTS sidecar, OCR, AX walk, optional watch-
//  mode sampling, optional posture camera. On a MacBook on battery
//  the fans spin up fast. Without throttling we keep ALL these
//  surfaces running at full cadence regardless of thermal pressure,
//  which is both annoying (fan noise) and counterproductive (the
//  OS starts throttling our processes externally, making the
//  user-facing turn SLOWER).
//
//  Recommendations escalate:
//
//    .nominal → run everything at full quality
//    .fair    → skip the speculative race (saves one full planner
//               call per first-step screen turn); keep watch mode
//    .serious → drop watch mode cadence to 30s, prefer Apple FM
//               over the heavy local planner, suppress proactive
//               surfaces
//    .critical → suspend all proactive surfaces, suspend watch mode
//               entirely, prefer Apple FM for everything; only
//               user-initiated PTT runs
//
//  Pure value-type advisor over the ProcessInfo enum so unit tests
//  drive each recommendation in isolation. The MainActor wrapper
//  is just for the `@Published` published-state observer pattern.
//

import Combine
import Foundation

nonisolated enum PaceThermalRecommendation: String, Equatable, CaseIterable {
    /// Full quality everywhere.
    case unrestricted
    /// Cool the speculative race (one extra planner call per first
    /// screen turn) while keeping every user-facing path intact.
    case dampenSpeculativeRace
    /// Drop proactive surface cadence and prefer the cheaper planner.
    case dampenBackgroundLoops
    /// Only user-initiated turns. Everything proactive is suspended.
    case suspendBackground
}

@MainActor
final class PaceThermalStateAdvisor: ObservableObject {

    /// Published so SwiftUI surfaces (e.g. Settings → Diagnostics)
    /// can show the current advisor state without manually polling.
    @Published private(set) var currentRecommendation: PaceThermalRecommendation = .unrestricted

    private var thermalStateObserver: NSObjectProtocol?

    deinit {
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
        }
    }

    func start() {
        guard thermalStateObserver == nil else { return }
        refreshCurrentRecommendation()
        let observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentRecommendation()
            }
        }
        thermalStateObserver = observer
    }

    func stop() {
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
            self.thermalStateObserver = nil
        }
    }

    /// Test seam — drive the advisor from a synthetic thermal state
    /// without depending on the real ProcessInfo singleton.
    func applyThermalStateForTesting(_ thermalState: ProcessInfo.ThermalState) {
        currentRecommendation = Self.recommendation(forThermalState: thermalState)
    }

    private func refreshCurrentRecommendation() {
        currentRecommendation = Self.recommendation(
            forThermalState: ProcessInfo.processInfo.thermalState
        )
    }

    // MARK: - Pure mapping (unit-testable)

    nonisolated static func recommendation(
        forThermalState thermalState: ProcessInfo.ThermalState
    ) -> PaceThermalRecommendation {
        switch thermalState {
        case .nominal:
            return .unrestricted
        case .fair:
            return .dampenSpeculativeRace
        case .serious:
            return .dampenBackgroundLoops
        case .critical:
            return .suspendBackground
        @unknown default:
            // Unknown future enum case — err on the side of staying
            // unrestricted so we don't silently degrade behaviour on
            // an OS that introduces a new state we haven't audited.
            return .unrestricted
        }
    }

    // MARK: - Per-surface gates (composable predicates)

    /// True when the speculative planner race should fire. False
    /// once thermal pressure is `.fair` or worse — the race trades
    /// a full extra planner call for ~150 ms TTFSW, which isn't a
    /// good trade when the machine is already heating up.
    nonisolated static func shouldRunSpeculativeRace(
        underRecommendation recommendation: PaceThermalRecommendation
    ) -> Bool {
        switch recommendation {
        case .unrestricted:
            return true
        case .dampenSpeculativeRace, .dampenBackgroundLoops, .suspendBackground:
            return false
        }
    }

    /// True when proactive surfaces (morning brief, posture, fatigue,
    /// watch-mode nudges) should be allowed to speak.
    nonisolated static func shouldRunProactiveSurfaces(
        underRecommendation recommendation: PaceThermalRecommendation
    ) -> Bool {
        switch recommendation {
        case .unrestricted, .dampenSpeculativeRace:
            return true
        case .dampenBackgroundLoops, .suspendBackground:
            return false
        }
    }

    /// True when watch mode's screen sampling should run at its full
    /// configured cadence. False past `.serious` — watch mode runs at
    /// a longer interval (or pauses entirely) to give the system room
    /// to cool down.
    nonisolated static func shouldRunWatchModeAtFullCadence(
        underRecommendation recommendation: PaceThermalRecommendation
    ) -> Bool {
        switch recommendation {
        case .unrestricted, .dampenSpeculativeRace:
            return true
        case .dampenBackgroundLoops, .suspendBackground:
            return false
        }
    }

    /// True when the PTT-press screen-context prewarm should fire.
    /// `.suspendBackground` skips it — the user can still press PTT
    /// and get a screen-aware turn, it just pays the full VLM
    /// latency synchronously because nothing was prewarmed.
    nonisolated static func shouldRunScreenContextPrewarm(
        underRecommendation recommendation: PaceThermalRecommendation
    ) -> Bool {
        switch recommendation {
        case .unrestricted, .dampenSpeculativeRace, .dampenBackgroundLoops:
            return true
        case .suspendBackground:
            return false
        }
    }
}
