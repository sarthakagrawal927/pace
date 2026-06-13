//
//  PaceVoiceEditProcessor.swift
//  leanring-buddy
//
//  Deterministic selected-text edit scaffold. A trained local editor can
//  replace this once it beats these rules, but the action path stays the same.
//

import Foundation

nonisolated struct PaceVoiceEditRequest: Equatable {
    let operation: PaceVoiceEditOperation
}

nonisolated enum PaceVoiceEditOperation: Equatable {
    case shorten
    case makeDirect
    case fixGrammar
    case replace(oldText: String, newText: String)
    case deleteLastSentence
    case makeBullets

    var displayName: String {
        switch self {
        case .shorten:
            return "shorten selected text"
        case .makeDirect:
            return "make selected text direct"
        case .fixGrammar:
            return "fix selected text grammar"
        case .replace(let oldText, let newText):
            return "replace \(oldText) with \(newText)"
        case .deleteLastSentence:
            return "delete last selected sentence"
        case .makeBullets:
            return "turn selected text into bullets"
        }
    }
}

nonisolated enum PaceVoiceEditProcessor {
    static func process(
        selectedText: String,
        request: PaceVoiceEditRequest
    ) -> String? {
        let trimmedSelectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelectedText.isEmpty else { return nil }

        switch request.operation {
        case .shorten:
            return shorten(trimmedSelectedText)
        case .makeDirect:
            return makeDirect(trimmedSelectedText)
        case .fixGrammar:
            return PaceDictationPostProcessor.process(rawText: trimmedSelectedText)
        case .replace(let oldText, let newText):
            return replace(oldText: oldText, with: newText, in: trimmedSelectedText)
        case .deleteLastSentence:
            return deleteLastSentence(from: trimmedSelectedText)
        case .makeBullets:
            return makeBullets(from: trimmedSelectedText)
        }
    }

    static func parseCommand(_ rawCommand: String) -> PaceVoiceEditRequest? {
        let command = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
            .lowercased()

        switch command {
        case "make this shorter", "make that shorter", "make it shorter", "shorten this", "shorten that", "shorten it":
            return PaceVoiceEditRequest(operation: .shorten)
        case "make this more direct", "make that more direct", "make it more direct", "make this direct", "make that direct":
            return PaceVoiceEditRequest(operation: .makeDirect)
        case "fix grammar", "fix the grammar", "fix grammar only", "clean up grammar", "clean this up":
            return PaceVoiceEditRequest(operation: .fixGrammar)
        case "delete last sentence", "delete the last sentence", "remove last sentence", "remove the last sentence":
            return PaceVoiceEditRequest(operation: .deleteLastSentence)
        case "turn this into bullets", "turn that into bullets", "make this bullets", "make that bullets", "bullet this", "bullet that":
            return PaceVoiceEditRequest(operation: .makeBullets)
        default:
            return parseReplaceCommand(command)
        }
    }

    private static func parseReplaceCommand(_ command: String) -> PaceVoiceEditRequest? {
        let prefixes = [
            "replace ",
            "change "
        ]
        for prefix in prefixes {
            guard command.hasPrefix(prefix),
                  let separatorRange = command.range(of: " with ") else {
                continue
            }

            let oldText = String(command[command.index(command.startIndex, offsetBy: prefix.count)..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = String(command[separatorRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oldText.isEmpty, !newText.isEmpty else { return nil }
            return PaceVoiceEditRequest(operation: .replace(oldText: oldText, newText: newText))
        }
        return nil
    }

    private static func shorten(_ text: String) -> String {
        let sentences = sentenceFragments(from: text)
        if sentences.count > 1, let firstSentence = sentences.first {
            return firstSentence
        }

        let removablePhrases = [
            "I think ",
            "I believe ",
            "basically ",
            "really ",
            "very ",
            "actually ",
            "just ",
            "kind of ",
            "sort of "
        ]
        return removablePhrases.reduce(text) { partialText, phrase in
            partialText.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
        }
        .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeDirect(_ text: String) -> String {
        var directText = text
        let replacements: [(String, String)] = [
            ("I think we should ", "We should "),
            ("I believe we should ", "We should "),
            ("Maybe we can ", "We can "),
            ("Could you please ", "Please "),
            ("I was wondering if ", ""),
            ("kind of ", ""),
            ("sort of ", ""),
            ("just ", "")
        ]

        for (oldPhrase, newPhrase) in replacements {
            directText = directText.replacingOccurrences(
                of: oldPhrase,
                with: newPhrase,
                options: [.caseInsensitive]
            )
        }

        return directText
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(
        oldText: String,
        with newText: String,
        in selectedText: String
    ) -> String? {
        let updatedText = selectedText.replacingOccurrences(
            of: oldText,
            with: newText,
            options: [.caseInsensitive]
        )
        return updatedText == selectedText ? nil : updatedText
    }

    private static func deleteLastSentence(from text: String) -> String? {
        var sentences = sentenceFragments(from: text)
        guard sentences.count > 1 else { return nil }
        sentences.removeLast()
        return sentences.joined(separator: " ")
    }

    private static func makeBullets(from text: String) -> String {
        let fragments = sentenceFragments(from: text)
        let bulletItems = fragments.isEmpty ? [text] : fragments
        return bulletItems
            .map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
    }

    private static func sentenceFragments(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
