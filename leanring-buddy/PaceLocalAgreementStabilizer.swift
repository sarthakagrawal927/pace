//
//  PaceLocalAgreementStabilizer.swift
//  leanring-buddy
//
//  Provider-agnostic LocalAgreement-style partial transcript stabilizer.
//  WhisperKit can feed this with successive hypotheses once the real
//  streaming bridge lands; Apple Speech remains the production provider today.
//

import Foundation

struct PaceLocalAgreementStabilizer {
    private(set) var stablePrefix = ""
    private var previousHypothesis = ""

    mutating func reset() {
        stablePrefix = ""
        previousHypothesis = ""
    }

    mutating func acceptHypothesis(_ hypothesis: String) -> String {
        let normalizedHypothesis = Self.normalizedTranscript(hypothesis)
        defer {
            previousHypothesis = normalizedHypothesis
        }

        guard !normalizedHypothesis.isEmpty else {
            return stablePrefix
        }

        guard !previousHypothesis.isEmpty else {
            return stablePrefix
        }

        let agreedPrefix = Self.commonPrefixByWord(
            previousHypothesis,
            normalizedHypothesis
        )
        guard agreedPrefix.count > stablePrefix.count else {
            return stablePrefix
        }

        stablePrefix = agreedPrefix
        return stablePrefix
    }

    static func normalizedTranscript(_ transcript: String) -> String {
        transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func commonPrefixByWord(_ firstTranscript: String, _ secondTranscript: String) -> String {
        let firstWords = normalizedTranscript(firstTranscript).split(separator: " ")
        let secondWords = normalizedTranscript(secondTranscript).split(separator: " ")

        var agreedWords: [Substring] = []
        for (firstWord, secondWord) in zip(firstWords, secondWords) {
            guard firstWord == secondWord else { break }
            agreedWords.append(firstWord)
        }

        return agreedWords.joined(separator: " ")
    }
}
