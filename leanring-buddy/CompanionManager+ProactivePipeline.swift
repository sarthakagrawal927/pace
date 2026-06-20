//
//  CompanionManager+ProactivePipeline.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A5):
//  thin forwarders to `PaceProactivityPipeline` (queue enqueue/snapshot/drain).
//

import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Proactive pipeline (Wave 7a extraction)

    /// Thin forwarder. Tests and the morning-triage scheduler call
    /// this to park an utterance for the idle drain.
    func enqueueProactiveUtterance(_ utterance: PaceProactiveUtterance) {
        proactivityPipeline.enqueueProactiveUtterance(utterance)
    }

    /// Test seam preserved from the pre-extraction surface.
    func proactiveUtteranceQueueSnapshot() -> [PaceProactiveUtterance] {
        return proactivityPipeline.proactiveUtteranceQueueSnapshot()
    }

    /// Test seam preserved from the pre-extraction surface. Lets the
    /// HerArc tests trigger a drain attempt without waiting for the
    /// 10-second timer to fire.
    func drainProactiveQueueIfIdle(now: Date = Date()) {
        proactivityPipeline.drainProactiveQueueIfIdle(now: now)
    }
}
