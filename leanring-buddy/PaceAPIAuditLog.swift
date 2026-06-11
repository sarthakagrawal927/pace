//
//  PaceAPIAuditLog.swift
//  leanring-buddy
//
//  Detailed, local-only audit log for every local API call Pace makes —
//  planner, VLM, embeddings, TTS sidecar, MCP servers. One JSON object
//  per line in Application Support so latency and failure patterns can
//  be studied across real use (`scripts/audit-summary.py` aggregates).
//
//  Privacy: entries carry timing, endpoint/model identifiers, outcome,
//  and SIZES of payloads — never their content. The file never leaves
//  the Mac.
//

import Foundation

nonisolated struct PaceAPIAuditEntry: Codable, Equatable {
    let at: Date
    /// Stable id shared by every entry recorded during the same user turn,
    /// so the audit log can be replayed as a timeline per question.
    let turnId: String?
    let subsystem: String
    let operation: String
    let target: String
    let durationMilliseconds: Int
    let outcome: String
    let inputCharacterCount: Int?
    let outputCharacterCount: Int?
    let detail: String?
}

nonisolated final class PaceAPIAuditLog: @unchecked Sendable {
    static let shared = PaceAPIAuditLog()

    /// Rotate when the log passes this size; one previous generation kept.
    static let rotationByteThreshold = 5 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.pace.api-audit", qos: .utility)
    private let logFileURL: URL
    private let encoder: JSONEncoder
    private let currentTurnIdLock = NSLock()
    private var _currentTurnId: String?

    /// Stable id shared by every audit record produced during one user
    /// turn. CompanionManager sets it on PTT-release / deeplink arrival;
    /// every subsystem (planner, VLM, TTS, MCP, action executor) picks it
    /// up automatically through `record(...)`.
    var currentTurnId: String? {
        currentTurnIdLock.lock()
        defer { currentTurnIdLock.unlock() }
        return _currentTurnId
    }

    func beginTurn() -> String {
        let newTurnId = UUID().uuidString
        currentTurnIdLock.lock()
        _currentTurnId = newTurnId
        currentTurnIdLock.unlock()
        return newTurnId
    }

    func endCurrentTurn() {
        currentTurnIdLock.lock()
        _currentTurnId = nil
        currentTurnIdLock.unlock()
    }

    init(logFileURL: URL? = nil) {
        self.logFileURL = logFileURL ?? Self.defaultLogFileURL()
        let configuredEncoder = JSONEncoder()
        configuredEncoder.dateEncodingStrategy = .iso8601
        configuredEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = configuredEncoder
    }

    /// Records one completed local API call. Fire-and-forget: encoding and
    /// disk append happen on a utility queue so call sites pay nothing.
    func record(
        subsystem: String,
        operation: String,
        target: String,
        durationMilliseconds: Int,
        outcome: String,
        inputCharacterCount: Int? = nil,
        outputCharacterCount: Int? = nil,
        detail: String? = nil,
        at timestamp: Date = Date()
    ) {
        let entry = PaceAPIAuditEntry(
            at: timestamp,
            turnId: currentTurnId,
            subsystem: subsystem,
            operation: operation,
            target: target,
            durationMilliseconds: durationMilliseconds,
            outcome: outcome,
            inputCharacterCount: inputCharacterCount,
            outputCharacterCount: outputCharacterCount,
            detail: detail
        )
        queue.async { [weak self] in
            self?.append(entry)
        }
    }

    /// Synchronously flushes pending writes — for tests.
    func waitForPendingWrites() {
        queue.sync {}
    }

    private func append(_ entry: PaceAPIAuditEntry) {
        guard var lineData = try? encoder.encode(entry) else { return }
        lineData.append(0x0A)

        let fileManager = FileManager.default
        let directoryURL = logFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        rotateIfNeeded(fileManager: fileManager)

        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: logFileURL)
        }
    }

    private func rotateIfNeeded(fileManager: FileManager) {
        guard let fileSize = (try? fileManager.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
              fileSize >= Self.rotationByteThreshold else {
            return
        }
        let rotatedURL = logFileURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: logFileURL, to: rotatedURL)
    }

    private static func defaultLogFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupportURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("api-audit.jsonl")
    }
}
