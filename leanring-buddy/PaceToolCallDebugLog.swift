//
//  PaceToolCallDebugLog.swift
//  leanring-buddy
//
//  One captured turn for the Settings → Debug "Tool Calls" view, plus a
//  JSONL trace store that PERSISTS those captures to disk.
//
//  Why this exists
//  ---------------
//  PaceActionResultCenter records actions that *executed*. But a turn that
//  SPEAKS something and does nothing — e.g. "opening chrome" with no action —
//  leaves no action record at all, so the existing surface goes blank and
//  tells us nothing about *why*. This record captures the missing middle: the
//  exact transcript, how the turn routed, which planner produced the audio,
//  per-turn latency, the planner's RAW output (before stripping), the planner
//  INPUT prompt (so a failing turn can be reproduced offline), the parsed tool
//  calls, and the dispatch outcome.
//
//  Persistence: every record is appended as one JSON line to
//  ~/Library/Application Support/Pace/tool-call-traces.jsonl (capped, newest
//  kept), so the history survives restarts and can be inspected outside the
//  app. CompanionManager seeds the in-memory list from this file on launch.
//

import Foundation

nonisolated struct PaceToolCallDebugRecord: Identifiable, Equatable, Codable {
    /// Which routing lane handled the turn — the single most useful first
    /// fact when a command misbehaves, because the lanes emit actions in
    /// completely different ways.
    enum Lane: String, Equatable, Codable {
        case fastPath = "fast path"
        case textOnly = "text-only planner"
        case planner = "planner"
    }

    let id: UUID
    let createdAt: Date
    /// Exactly what ASR produced — the first place "open google.com" vs
    /// "open google dot com" (which the fast path can't URL-ify) diverges.
    let transcript: String
    let lane: Lane
    /// Intent + confidence + route, or "fast path matched", etc.
    let routingDetail: String
    /// "speculative race · lite won", "single planner", or nil for the
    /// fast path.
    let plannerPathDetail: String?
    /// The lite (screenless Apple FM) spoken text the user actually heard,
    /// set ONLY when the lite path won the race. nil otherwise.
    let userHeardScreenlessAnswer: String?
    /// Count of element-map lines sent to the planner this step.
    let screenElementCount: Int?
    /// The planner's complete raw output BEFORE tag/think stripping.
    let rawPlannerOutput: String
    /// The cleaned text actually spoken through TTS.
    let spokenText: String
    /// One line per parsed tool call, or "no actions parsed".
    let parsedActionsSummary: String
    /// What dispatch did.
    let dispatchSummary: String
    /// Planner round-trip latency in ms (request → full response). nil on the
    /// fast path (no planner ran).
    let plannerLatencyMs: Int?
    /// Whole-turn latency in ms (turn start → this record).
    let totalTurnLatencyMs: Int?
    /// The exact user prompt sent to the planner — transcript + element map +
    /// any retrieval/MCP context. The variable half of the planner input
    /// (the system prompt is static in CompanionSystemPrompt), so this plus
    /// the source system prompt reproduces the turn offline. Empty on the
    /// fast path. Capped so a pathological screen can't bloat the trace file.
    let userPrompt: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcript: String,
        lane: Lane,
        routingDetail: String,
        plannerPathDetail: String? = nil,
        userHeardScreenlessAnswer: String? = nil,
        screenElementCount: Int? = nil,
        rawPlannerOutput: String,
        spokenText: String,
        parsedActionsSummary: String,
        dispatchSummary: String,
        plannerLatencyMs: Int? = nil,
        totalTurnLatencyMs: Int? = nil,
        userPrompt: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.lane = lane
        self.routingDetail = routingDetail
        self.plannerPathDetail = plannerPathDetail
        self.userHeardScreenlessAnswer = userHeardScreenlessAnswer
        self.screenElementCount = screenElementCount
        self.rawPlannerOutput = rawPlannerOutput
        self.spokenText = spokenText
        self.parsedActionsSummary = parsedActionsSummary
        self.dispatchSummary = dispatchSummary
        self.plannerLatencyMs = plannerLatencyMs
        self.totalTurnLatencyMs = totalTurnLatencyMs
        self.userPrompt = String(userPrompt.prefix(12_000))
    }

    /// Compact one-line latency string for the UI, e.g. "planner 1820ms ·
    /// turn 2310ms". Empty when no timing was captured.
    var latencyDisplay: String {
        var parts: [String] = []
        if let plannerLatencyMs { parts.append("planner \(plannerLatencyMs)ms") }
        if let totalTurnLatencyMs { parts.append("turn \(totalTurnLatencyMs)ms") }
        return parts.joined(separator: " · ")
    }
}

/// JSONL persistence for tool-call debug records. Append-only with a line
/// cap; file lives next to Pace's other local data under Application Support.
/// All disk I/O hops onto a private serial queue so the @MainActor capture
/// site never blocks on the filesystem.
enum PaceToolCallDebugTrace {
    /// Keep the trace bounded — a debug aid, not an archive.
    static let maximumRetainedLines = 500

    private static let ioQueue = DispatchQueue(label: "com.pace.app.toolCallDebugTrace")

    static var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("tool-call-traces.jsonl", isDirectory: false)
    }

    /// Append one record as a JSON line (fire-and-forget, off the main actor).
    static func append(_ record: PaceToolCallDebugRecord) {
        guard let fileURL else { return }
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let lineData = try? encoder.encode(record),
                  let line = String(data: lineData, encoding: .utf8) else { return }

            let directoryURL = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true
            )

            var lines = (try? String(contentsOf: fileURL, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []
            lines.append(line)
            if lines.count > maximumRetainedLines {
                lines.removeFirst(lines.count - maximumRetainedLines)
            }
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Load the most recent records (oldest→newest in the file; this returns
    /// them newest-first to match the in-memory list). Synchronous — only
    /// called once at launch with a small bounded file.
    static func loadRecent(limit: Int) -> [PaceToolCallDebugRecord] {
        guard let fileURL,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { line -> PaceToolCallDebugRecord? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(PaceToolCallDebugRecord.self, from: data)
            }
        return records.reversed()
    }

    /// Clear the persisted trace file.
    static func clear() {
        guard let fileURL else { return }
        ioQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
