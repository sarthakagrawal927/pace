//
//  PaceRecipeCommandParser.swift
//  leanring-buddy
//
//  Pure parser for "install/uninstall/list the <name> recipe" voice
//  commands. Returns a `PaceRecipeCommand` that `CompanionManager`
//  routes BEFORE the planner — so installing a recipe doesn't burn a
//  planner round-trip.
//
//  Matches the parsing shape of `PaceFlowCommandParser` and
//  `PaceLocalMemoryCommandParser`: prefix-based, lowercase-normalized,
//  fail-closed on empty payloads. The matched display name is
//  returned verbatim so the manager can do a case-insensitive lookup
//  against the bundled library.
//

import Foundation

enum PaceRecipeCommand: Equatable {
    case install(displayName: String)
    case uninstall(displayName: String)
    case list
}

enum PaceRecipeCommandParser {
    /// Parse a transcript into a recipe command if one matches.
    /// Returns nil for anything that doesn't look like an explicit
    /// install/uninstall/list request, so the rest of the
    /// `CompanionManager` intake (intent classifier, planner, …) stays
    /// untouched for normal turns.
    static func parse(_ transcript: String) -> PaceRecipeCommand? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = trimmedTranscript.lowercased()
        guard !normalizedTranscript.isEmpty else { return nil }

        if listCommandPhrases.contains(normalizedTranscript) {
            return .list
        }

        if let installDisplayName = matchInstallPhrase(in: trimmedTranscript) {
            return .install(displayName: installDisplayName)
        }

        if let uninstallDisplayName = matchUninstallPhrase(in: trimmedTranscript) {
            return .uninstall(displayName: uninstallDisplayName)
        }

        return nil
    }

    // MARK: - Phrase matching helpers

    /// Recognized "list" phrases. Kept narrow so a casual "what
    /// recipes" mid-sentence doesn't accidentally trigger the list
    /// response — must match the whole transcript.
    private static let listCommandPhrases: Set<String> = [
        "list recipes",
        "list the recipes",
        "what recipes do you have",
        "what recipes are there",
        "show me the recipes",
        "show recipes",
    ]

    private static func matchInstallPhrase(in trimmedTranscript: String) -> String? {
        return extractDisplayName(
            in: trimmedTranscript,
            prefixes: [
                "install the ",
                "install ",
                "add the ",
                "add ",
            ],
            suffixes: [
                " recipe",
                " flow",
            ]
        )
    }

    private static func matchUninstallPhrase(in trimmedTranscript: String) -> String? {
        return extractDisplayName(
            in: trimmedTranscript,
            prefixes: [
                "remove the ",
                "remove ",
                "uninstall the ",
                "uninstall ",
            ],
            suffixes: [
                " recipe",
                " flow",
            ]
        )
    }

    /// Strip the first matching prefix then the first matching suffix.
    /// A suffix MUST match — that's how we tell "install the morning
    /// standup recipe" apart from "install the latest update" (the
    /// latter has no `recipe`/`flow` suffix, so it doesn't match).
    private static func extractDisplayName(
        in trimmedTranscript: String,
        prefixes: [String],
        suffixes: [String]
    ) -> String? {
        let lowercaseTranscript = trimmedTranscript.lowercased()

        for prefix in prefixes {
            guard lowercaseTranscript.hasPrefix(prefix) else { continue }
            let middleAndSuffixSubstring = trimmedTranscript.dropFirst(prefix.count)
            let lowercaseMiddleAndSuffix = middleAndSuffixSubstring.lowercased()

            for suffix in suffixes {
                guard lowercaseMiddleAndSuffix.hasSuffix(suffix) else { continue }
                let displayNameSubstring = middleAndSuffixSubstring.dropLast(suffix.count)
                let trimmedDisplayName = displayNameSubstring
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
                if !trimmedDisplayName.isEmpty {
                    return trimmedDisplayName
                }
            }
        }

        return nil
    }
}
