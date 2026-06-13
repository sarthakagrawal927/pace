//
//  PaceDictationPostProcessor.swift
//  leanring-buddy
//
//  Small local cleanup pass for dictated text. This is the rule-backed
//  scaffold from the dictation PRD; a trained post-processor can replace it
//  once it beats these deterministic cases.
//

import Foundation

nonisolated enum PaceDictationPostProcessor {
    static func process(rawText: String, mode: String? = nil) -> String {
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawText.isEmpty else { return "" }

        let punctuationProcessedText = applySpokenPunctuation(to: trimmedRawText)
        let normalizedMode = mode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedMode == "code" || looksLikeSpokenCode(punctuationProcessedText) {
            return applyCodePhraseCleanup(to: punctuationProcessedText)
        }

        return applyProseCleanup(to: punctuationProcessedText)
    }

    private static func applySpokenPunctuation(to text: String) -> String {
        let replacements: [(String, String)] = [
            (" open parenthesis ", "("),
            (" open paren ", "("),
            (" close parenthesis ", ")"),
            (" close paren ", ")"),
            (" comma ", ", "),
            (" period ", ". "),
            (" full stop ", ". "),
            (" question mark ", "? "),
            (" exclamation mark ", "! "),
            (" colon ", ": "),
            (" semicolon ", "; "),
            (" slash ", "/"),
            (" backslash ", "\\"),
            (" underscore ", "_"),
            (" dash ", "-")
        ]

        var cleanedText = " \(text) "
        for (spokenToken, replacement) in replacements {
            cleanedText = cleanedText.replacingOccurrences(
                of: spokenToken,
                with: replacement,
                options: [.caseInsensitive]
            )
        }

        return cleanedText
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:?!\)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([\(\[/\\]) +"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyProseCleanup(to text: String) -> String {
        var cleanedText = text
            .replacingOccurrences(of: #"\blets\b"#, with: "let's", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\bim\b"#, with: "I'm", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\bi\b"#, with: "I", options: [.regularExpression])

        if let firstCharacter = cleanedText.first, firstCharacter.isLowercase {
            cleanedText.replaceSubrange(
                cleanedText.startIndex...cleanedText.startIndex,
                with: String(firstCharacter).uppercased()
            )
        }

        return cleanedText
    }

    private static func looksLikeSpokenCode(_ text: String) -> Bool {
        let normalizedText = text.lowercased()
        return normalizedText.contains("(")
            || normalizedText.contains("_")
            || normalizedText.contains(" camel case ")
            || normalizedText.contains(" snake case ")
    }

    private static func applyCodePhraseCleanup(to text: String) -> String {
        let functionCallPattern = #"^([a-zA-Z ]+)\(([^()]*)\)$"#
        guard let regex = try? NSRegularExpression(pattern: functionCallPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let functionNameRange = Range(match.range(at: 1), in: text),
              let argumentsRange = Range(match.range(at: 2), in: text) else {
            return text
        }

        let functionName = lowerCamelCase(String(text[functionNameRange]))
        let arguments = String(text[argumentsRange])
            .split(separator: " ")
            .map(String.init)
            .joined(separator: ", ")

        return "\(functionName)(\(arguments))"
    }

    private static func lowerCamelCase(_ phrase: String) -> String {
        let words = phrase
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
        guard let firstWord = words.first else { return "" }
        return words.dropFirst().reduce(firstWord) { partialResult, word in
            partialResult + word.prefix(1).uppercased() + word.dropFirst()
        }
    }
}
