//
//  PaceMailDraftStreaming.swift
//  leanring-buddy
//
//  Incremental detection for v10 Mail.draft planner JSON. This lets Pace
//  start filling a local Mail draft while the planner is still streaming
//  the body field, without making the final parser depend on incomplete JSON.
//

import Foundation

struct PaceStreamingMailDraftSnapshot: Equatable {
    let recipients: [String]
    let subject: String
    let body: String

    var normalizedMailDraft: PaceMailDraft {
        PaceMailDraft(
            recipients: recipients,
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled"
                : subject.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body
        )
    }
}

final class PaceStreamingMailDraftDetector {
    private var lastEmittedSnapshot: PaceStreamingMailDraftSnapshot?

    func reset() {
        lastEmittedSnapshot = nil
    }

    func detectChange(in accumulatedPlannerText: String) -> PaceStreamingMailDraftSnapshot? {
        guard Self.looksLikeMailDraftPlannerResponse(accumulatedPlannerText) else {
            return nil
        }

        let recipients = Self.extractRecipients(from: accumulatedPlannerText)
        let subject = Self.firstJSONStringValue(
            for: ["subject", "title"],
            in: accumulatedPlannerText
        ) ?? ""
        let body = Self.firstJSONStringValue(
            for: ["body", "bodyText", "text"],
            in: accumulatedPlannerText
        ) ?? ""

        // Wait until the body field has started. Opening a blank draft from
        // an accidental early `"name":"Mail.draft"` token is too jumpy.
        guard Self.containsAnyKey(["body", "bodyText", "text"], in: accumulatedPlannerText) else {
            return nil
        }

        let snapshot = PaceStreamingMailDraftSnapshot(
            recipients: recipients,
            subject: subject,
            body: body
        )
        guard snapshot != lastEmittedSnapshot else {
            return nil
        }

        lastEmittedSnapshot = snapshot
        return snapshot
    }

    static func firstMailDraft(in actionExecutionPlan: PaceActionExecutionPlan) -> PaceMailDraft? {
        for action in actionExecutionPlan.flattenedActions {
            if case .composeMail(let mailDraft) = action {
                return mailDraft
            }
        }
        return nil
    }

    private static func looksLikeMailDraftPlannerResponse(_ text: String) -> Bool {
        guard text.localizedCaseInsensitiveContains(#""payload""#),
              text.localizedCaseInsensitiveContains(#""args""#) else {
            return false
        }

        let actionName = firstJSONStringValue(for: ["name"], in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")

        return actionName == "mail.draft" || actionName == "mail.compose"
    }

    private static func extractRecipients(from text: String) -> [String] {
        var recipients: [String] = []

        if let recipientString = firstJSONStringValue(for: ["to", "recipient"], in: text) {
            recipients.append(contentsOf: splitRecipientString(recipientString))
        }

        if let recipientArray = firstJSONStringArray(for: ["to", "recipients"], in: text) {
            recipients.append(contentsOf: recipientArray.flatMap(splitRecipientString))
        }

        var seenRecipients: Set<String> = []
        return recipients.filter { recipient in
            let normalizedRecipient = recipient.lowercased()
            guard !seenRecipients.contains(normalizedRecipient) else {
                return false
            }
            seenRecipients.insert(normalizedRecipient)
            return true
        }
    }

    private static func splitRecipientString(_ rawRecipientString: String) -> [String] {
        rawRecipientString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

            let valueStartIndex = keyRange.upperBound
            return parsePossiblyIncompleteJSONString(startingAt: valueStartIndex, in: text)
        }

        return nil
    }

    private static func firstJSONStringArray(for keys: [String], in text: String) -> [String]? {
        for key in keys {
            guard let keyRange = text.range(
                of: #""\#(key)"\s*:\s*\["#,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                continue
            }

            var cursor = keyRange.upperBound
            var values: [String] = []
            while cursor < text.endIndex {
                guard let quoteRange = text[cursor...].range(of: #"""#) else {
                    break
                }
                let valueStartIndex = quoteRange.upperBound
                let value = parsePossiblyIncompleteJSONString(
                    startingAt: valueStartIndex,
                    in: text
                )
                values.append(value)

                guard let closingQuoteIndex = closingQuoteIndex(
                    startingAt: valueStartIndex,
                    in: text
                ) else {
                    break
                }
                cursor = text.index(after: closingQuoteIndex)

                if let remainingArrayRange = text[cursor...].range(of: "]"),
                   let nextQuoteRange = text[cursor...].range(of: #"""#),
                   remainingArrayRange.lowerBound < nextQuoteRange.lowerBound {
                    break
                }
            }

            return values
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

    private static func closingQuoteIndex(
        startingAt valueStartIndex: String.Index,
        in text: String
    ) -> String.Index? {
        var cursor = valueStartIndex
        var escapeNextCharacter = false

        while cursor < text.endIndex {
            let character = text[cursor]
            if escapeNextCharacter {
                escapeNextCharacter = false
            } else if character == "\\" {
                escapeNextCharacter = true
            } else if character == "\"" {
                return cursor
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func decodedEscapedCharacter(_ character: Character) -> Character {
        switch character {
        case "n":
            return "\n"
        case "t":
            return "\t"
        case "r":
            return "\r"
        case "\"":
            return "\""
        case "\\":
            return "\\"
        case "/":
            return "/"
        default:
            return character
        }
    }
}

extension PaceActionExecutionPlan {
    func removingFirstMailDraftAction() -> PaceActionExecutionPlan {
        var hasRemovedMailDraft = false
        let filteredSteps = steps.compactMap { step -> PaceActionExecutionStep? in
            let filteredActions = step.actions.filter { action in
                guard !hasRemovedMailDraft else {
                    return true
                }
                if case .composeMail = action {
                    hasRemovedMailDraft = true
                    return false
                }
                return true
            }
            return filteredActions.isEmpty ? nil : PaceActionExecutionStep(actions: filteredActions)
        }
        return PaceActionExecutionPlan(steps: filteredSteps)
    }
}
