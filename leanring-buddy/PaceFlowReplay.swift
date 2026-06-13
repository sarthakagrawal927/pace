//
//  PaceFlowReplay.swift
//  leanring-buddy
//
//  Voice-command parser plus replay-planner heuristic for recorded
//  demonstration flows. The on-disk store moved to
//  `PaceFlowStore.swift` (Wave 3a split) and the live event recorder
//  moved to `PaceFlowRecorder.swift`. This file keeps the small pure
//  helpers that don't depend on either runtime layer so they can be
//  unit-tested in isolation and re-used wherever they make sense.
//
//  - `PaceRecordedFlow` / `PaceRecordedStep`: the on-disk schema.
//    Schema-identical to the bundled recipe JSON shape.
//  - `PaceFlowCommand` / `PaceFlowCommandParser`: voice-side parser
//    that routes "remember this flow as …" / "stop recording" / "run
//    …" / "delete the flow …" before the planner.
//  - `PaceFlowReplayPlanner`: pause-before-send heuristic so a saved
//    flow stops at the final "Send" button and asks for confirmation
//    rather than firing destructive UI on autopilot.
//

import Foundation

nonisolated struct PaceRecordedFlow: Codable, Equatable, Identifiable {
    let name: String
    let createdAt: Date
    var steps: [PaceRecordedStep]

    var id: String { name }
}

nonisolated enum PaceRecordedStep: Codable, Equatable {
    case activateApp(bundleIdentifier: String)
    case axPress(rolePath: [String], label: String)
    case typeText(text: String, secure: Bool)
    case keyShortcut(key: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIdentifier
        case rolePath
        case label
        case text
        case secure
        case key
    }

    private enum Kind: String, Codable {
        case activateApp
        case axPress
        case typeText
        case keyShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .activateApp:
            self = .activateApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case .axPress:
            self = .axPress(
                rolePath: try container.decode([String].self, forKey: .rolePath),
                label: try container.decode(String.self, forKey: .label)
            )
        case .typeText:
            self = .typeText(
                text: try container.decode(String.self, forKey: .text),
                secure: try container.decode(Bool.self, forKey: .secure)
            )
        case .keyShortcut:
            self = .keyShortcut(key: try container.decode(String.self, forKey: .key))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .activateApp(let bundleIdentifier):
            try container.encode(Kind.activateApp, forKey: .kind)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        case .axPress(let rolePath, let label):
            try container.encode(Kind.axPress, forKey: .kind)
            try container.encode(rolePath, forKey: .rolePath)
            try container.encode(label, forKey: .label)
        case .typeText(let text, let secure):
            try container.encode(Kind.typeText, forKey: .kind)
            try container.encode(secure ? "<password redacted>" : text, forKey: .text)
            try container.encode(secure, forKey: .secure)
        case .keyShortcut(let key):
            try container.encode(Kind.keyShortcut, forKey: .kind)
            try container.encode(key, forKey: .key)
        }
    }
}

enum PaceFlowCommand: Equatable {
    case startRecording(name: String)
    case stopRecording
    case run(name: String)
    case delete(name: String)
}

enum PaceFlowCommandParser {
    static func parse(_ transcript: String) -> PaceFlowCommand? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = trimmedTranscript.lowercased()
        guard !normalizedTranscript.isEmpty else { return nil }

        if normalizedTranscript == "stop recording" || normalizedTranscript == "i'm done" {
            return .stopRecording
        }

        for prefix in ["remember this flow as ", "remember this as ", "save this as a flow called "] {
            if normalizedTranscript.hasPrefix(prefix) {
                let name = String(trimmedTranscript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : .startRecording(name: name)
            }
        }

        for prefix in ["delete the flow ", "forget the flow "] {
            if normalizedTranscript.hasPrefix(prefix) {
                let name = String(trimmedTranscript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : .delete(name: name)
            }
        }

        for prefix in ["run ", "play back ", "do "] {
            if normalizedTranscript.hasPrefix(prefix) {
                let name = String(trimmedTranscript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : .run(name: name)
            }
        }

        return nil
    }
}

enum PaceFlowReplayPlanner {
    static func shouldPauseBeforeSend(step: PaceRecordedStep, isLastStep: Bool) -> Bool {
        guard isLastStep else { return false }
        guard case .axPress(_, let label) = step else { return false }
        let normalizedLabel = label.lowercased()
        return ["send", "submit", "post", "reply"].contains { sendWord in
            normalizedLabel == sendWord || normalizedLabel.contains(sendWord)
        }
    }

    static func replayObservations(for flow: PaceRecordedFlow) -> [String] {
        flow.steps.enumerated().map { index, step in
            if shouldPauseBeforeSend(step: step, isLastStep: index == flow.steps.count - 1) {
                return "ready to send - say go ahead"
            }
            switch step {
            case .activateApp(let bundleIdentifier):
                return "activate \(bundleIdentifier)"
            case .axPress(_, let label):
                return "press \(label)"
            case .typeText(let text, let secure):
                return secure ? "type secure text" : "type \(text.count) characters"
            case .keyShortcut(let key):
                return "press \(key)"
            }
        }
    }
}
