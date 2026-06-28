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

    /// End-to-end turn latency: PTT press → last spoken word. This is
    /// the metric that matters to users — "how long from when I start
    /// talking to when Pace finishes talking back." RCLI publishes
    /// sub-200ms; this lets Pace publish a comparable number.
    static func recordEndToEndLatency(
        milliseconds: Int,
        spokenWordCount: Int,
        plannerTokenCount: Int
    ) {
        logger.info("E2E=\(milliseconds, privacy: .public)ms words=\(spokenWordCount, privacy: .public) tokens=\(plannerTokenCount, privacy: .public)")
    }

    /// STT latency: PTT press → final transcript ready. Isolates the
    /// speech recognition cost from the rest of the pipeline.
    static func recordSTTLatency(milliseconds: Int, transcriptWordCount: Int) {
        logger.info("STT=\(milliseconds, privacy: .public)ms words=\(transcriptWordCount, privacy: .public)")
    }

    /// VLM latency: screenshot capture → element map ready. Isolates
    /// the screen analysis cost.
    static func recordVLMLatency(milliseconds: Int, elementCount: Int) {
        logger.info("VLM=\(milliseconds, privacy: .public)ms elements=\(elementCount, privacy: .public)")
    }

    /// Token throughput: planner tokens generated per second. RCLI
    /// publishes 550 tok/s with MetalRT; this lets Pace publish a
    /// comparable number for LM Studio / Apple FM / Direct API.
    static func recordTokenThroughput(
        tokensPerSecond: Double,
        totalTokens: Int,
        modelIdentifier: String
    ) {
        logger.info("TPS=\(String(format: "%.1f", tokensPerSecond), privacy: .public) total=\(totalTokens, privacy: .public) model=\(modelIdentifier, privacy: .public)")
    }
}
