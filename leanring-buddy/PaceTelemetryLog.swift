//
//  PaceTelemetryLog.swift
//  leanring-buddy
//
//  Single OSLog Logger for performance metrics. Each metric is emitted
//  alongside the existing `print(...)` so it shows in both the Xcode
//  console (for development) and the macOS unified log via
//  `log stream --subsystem com.pace.app --category metrics` (for the
//  `benchmark_ttfsw.sh` harness that aggregates real-world latency).
//
//  The unified-log path is what makes the "fastest voice tool" claim
//  measurable: anyone can run Pace, use it normally, and run the
//  benchmark script to get a reproducible TTFSW distribution.
//

import Foundation
import OSLog

enum PaceTelemetryLog {
    /// `subsystem` and `category` are the filter knobs `log stream`
    /// uses. `benchmark_ttfsw.sh` matches on exactly these values.
    static let logger = Logger(subsystem: "com.pace.app", category: "metrics")

    /// Time-to-first-spoken-word: the moment the user finished
    /// expressing intent (PTT release) to the moment audio playback
    /// dispatched. The headline product metric.
    static func recordTimeToFirstSpokenWord(milliseconds: Int) {
        logger.info("TTFSW=\(milliseconds, privacy: .public)ms")
    }

    /// Time-to-first-token from the planner: HTTP request sent to the
    /// first content chunk arriving over SSE. Useful for verifying
    /// prompt-cache hit rate and isolating planner latency from the
    /// rest of the pipeline.
    static func recordPlannerTimeToFirstToken(
        milliseconds: Int,
        modelIdentifier: String,
        messageCount: Int
    ) {
        logger.info("TTFT=\(milliseconds, privacy: .public)ms model=\(modelIdentifier, privacy: .public) msgs=\(messageCount, privacy: .public)")
    }

    /// Local retrieval query latency. Logs counts only, never excerpts,
    /// document titles, paths, or query text.
    static func recordRetrievalLatency(
        milliseconds: Int,
        resultCount: Int,
        sourceCount: Int
    ) {
        logger.info("RAG=\(milliseconds, privacy: .public)ms results=\(resultCount, privacy: .public) sources=\(sourceCount, privacy: .public)")
    }
}
