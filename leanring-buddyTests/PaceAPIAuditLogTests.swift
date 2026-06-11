//
//  PaceAPIAuditLogTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceAPIAuditLogTests {
    private func makeTemporaryLogURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-audit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("api-audit.jsonl")
    }

    @Test func recordsAppendOneJSONObjectPerLine() async throws {
        let logURL = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent()) }
        let auditLog = PaceAPIAuditLog(logFileURL: logURL)

        auditLog.record(
            subsystem: "planner",
            operation: "chat.completions.stream",
            target: "qwen/qwen3-30b-a3b",
            durationMilliseconds: 925,
            outcome: "ok",
            outputCharacterCount: 240,
            detail: "3 msgs"
        )
        auditLog.record(
            subsystem: "tts",
            operation: "audio.speech",
            target: "kokoro/af_heart",
            durationMilliseconds: 150,
            outcome: "transport_error"
        )
        auditLog.waitForPendingWrites()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)

        let firstEntry = try JSONDecoder.auditDecoder.decode(
            PaceAPIAuditEntry.self,
            from: Data(lines[0].utf8)
        )
        #expect(firstEntry.subsystem == "planner")
        #expect(firstEntry.durationMilliseconds == 925)
        #expect(firstEntry.outcome == "ok")
        #expect(firstEntry.outputCharacterCount == 240)

        let secondEntry = try JSONDecoder.auditDecoder.decode(
            PaceAPIAuditEntry.self,
            from: Data(lines[1].utf8)
        )
        #expect(secondEntry.subsystem == "tts")
        #expect(secondEntry.outcome == "transport_error")
        #expect(secondEntry.inputCharacterCount == nil)
    }

    @Test func rotationMovesOversizedLogToPreviousGeneration() async throws {
        let logURL = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Pre-seed an oversized file so the next record rotates it away.
        let oversizedContents = String(
            repeating: "x",
            count: PaceAPIAuditLog.rotationByteThreshold
        )
        try oversizedContents.write(to: logURL, atomically: true, encoding: .utf8)

        let auditLog = PaceAPIAuditLog(logFileURL: logURL)
        auditLog.record(
            subsystem: "mcp",
            operation: "tools/call",
            target: "apple.notes",
            durationMilliseconds: 80,
            outcome: "ok"
        )
        auditLog.waitForPendingWrites()

        let rotatedURL = logURL.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))
        let freshLines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(freshLines.count == 1)
    }
}

private extension JSONDecoder {
    static var auditDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
