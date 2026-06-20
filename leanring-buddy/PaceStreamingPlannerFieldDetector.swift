//
//  PaceStreamingPlannerFieldDetector.swift
//  leanring-buddy
//
//  Incremental detection for v10 planner text fields beyond Mail.draft:
//  dictate.payload.text, edit.payload.replacement, and AX.setValue args.value.
//  Mirrors the Mail draft detector pattern in PaceMailDraftStreaming.swift.
//

import Foundation

enum PaceStreamingPlannerFieldKind: Equatable {
    case dictateText
    case editReplacement
    case setValue
}

struct PaceStreamingPlannerFieldSnapshot: Equatable {
    let kind: PaceStreamingPlannerFieldKind
    let text: String
    let setValueTarget: PaceSetTextValueTarget?
}

struct PaceStreamingPlannerFieldChange: Equatable {
    let snapshot: PaceStreamingPlannerFieldSnapshot
    /// New characters since the previous snapshot (full text on first emission).
    let typingDelta: String
}

final class PaceStreamingPlannerFieldDetector {
    private var lastEmittedSnapshot: PaceStreamingPlannerFieldSnapshot?

    func reset() {
        lastEmittedSnapshot = nil
    }

    /// Returns a change record when a streamable text field has changed.
    func detectChange(in accumulatedPlannerText: String) -> PaceStreamingPlannerFieldChange? {
        guard let snapshot = buildSnapshot(from: accumulatedPlannerText),
              snapshot != lastEmittedSnapshot else {
            return nil
        }

        let typingDelta: String
        if let lastEmittedSnapshot,
              lastEmittedSnapshot.kind == snapshot.kind,
              snapshot.text.hasPrefix(lastEmittedSnapshot.text) {
            typingDelta = String(snapshot.text.dropFirst(lastEmittedSnapshot.text.count))
        } else {
            typingDelta = snapshot.text
        }

        lastEmittedSnapshot = snapshot
        return PaceStreamingPlannerFieldChange(snapshot: snapshot, typingDelta: typingDelta)
    }

    private func buildSnapshot(from accumulatedPlannerText: String) -> PaceStreamingPlannerFieldSnapshot? {
        guard accumulatedPlannerText.localizedCaseInsensitiveContains(#""intent""#) else {
            return nil
        }

        let normalizedIntent = Self.firstJSONStringValue(for: ["intent"], in: accumulatedPlannerText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedIntent {
        case "dictate":
            guard Self.containsAnyKey(["text", "body", "value"], in: accumulatedPlannerText),
                  let text = Self.firstJSONStringValue(
                      for: ["text", "body", "value"],
                      in: accumulatedPlannerText
                  ) else {
                return nil
            }
            return makeSnapshot(kind: .dictateText, text: text, target: nil)

        case "edit":
            guard Self.containsAnyKey(["replacement", "text", "value"], in: accumulatedPlannerText),
                  let replacement = Self.firstJSONStringValue(
                      for: ["replacement", "text", "value"],
                      in: accumulatedPlannerText
                  ) else {
                return nil
            }
            return makeSnapshot(kind: .editReplacement, text: replacement, target: .selection)

        case "action":
            guard Self.looksLikeSetValueAction(in: accumulatedPlannerText),
                  Self.containsAnyKey(["value"], in: accumulatedPlannerText),
                  let value = Self.firstJSONStringValue(for: ["value"], in: accumulatedPlannerText) else {
                return nil
            }
            let target = Self.setValueTarget(from: accumulatedPlannerText)
            return makeSnapshot(kind: .setValue, text: value, target: target)

        default:
            return nil
        }
    }

    private func makeSnapshot(
        kind: PaceStreamingPlannerFieldKind,
        text: String,
        target: PaceSetTextValueTarget?
    ) -> PaceStreamingPlannerFieldSnapshot {
        PaceStreamingPlannerFieldSnapshot(kind: kind, text: text, setValueTarget: target)
    }

    private static func looksLikeSetValueAction(in text: String) -> Bool {
        guard text.localizedCaseInsensitiveContains(#""payload""#),
              text.localizedCaseInsensitiveContains(#""args""#) else {
            return false
        }
        let actionName = firstJSONStringValue(for: ["name"], in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
        return actionName == "ax.setvalue"
            || actionName == "setvalue"
            || actionName == "set_value"
    }

    private static func setValueTarget(from text: String) -> PaceSetTextValueTarget {
        let rawTarget = firstJSONStringValue(for: ["target"], in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return rawTarget == "selection" ? .selection : .focused
    }

    private static func containsAnyKey(_ keys: [String], in text: String) -> Bool {
        keys.contains { key in
            text.range(
                of: #""\#(key)"\s*:"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private static func firstJSONStringValue(for keys: [String], in text: String) -> String? {
        for key in keys {
            guard let keyRange = text.range(
                of: #""\#(key)"\s*:\s*""#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                continue
            }
            return parsePossiblyIncompleteJSONString(
                startingAt: keyRange.upperBound,
                in: text
            )
        }
        return nil
    }

    private static func parsePossiblyIncompleteJSONString(
        startingAt valueStartIndex: String.Index,
        in text: String
    ) -> String {
        var decodedValue = ""
        var cursor = valueStartIndex
        var escapeNextCharacter = false

        while cursor < text.endIndex {
            let character = text[cursor]
            cursor = text.index(after: cursor)

            if escapeNextCharacter {
                decodedValue.append(decodedEscapedCharacter(character))
                escapeNextCharacter = false
                continue
            }

            if character == "\\" {
                escapeNextCharacter = true
                continue
            }

            if character == "\"" {
                break
            }

            decodedValue.append(character)
        }

        return decodedValue
    }

    private static func decodedEscapedCharacter(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        default: return character
        }
    }
}
