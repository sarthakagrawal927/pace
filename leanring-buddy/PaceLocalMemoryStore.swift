//
//  PaceLocalMemoryStore.swift
//  leanring-buddy
//
//  Tiny local memory for durable user preferences. This is intentionally
//  simple UserDefaults-backed state, not conversation memory and not cloud
//  sync. It stores preferences that should affect future tool execution.
//

import Foundation

enum PaceLocalMemoryKey: String, Equatable {
    case preferredBrowser
    case preferredNotesApp
    case defaultReminderList
    /// Music playlist name the user wants Pace to start during a
    /// "focus mode on" recipe. Optional in v1; the focus-mode recipe
    /// declares it via `requiredPreferences` so install refuses until
    /// the user sets a value.
    case preferredFocusPlaylist
}

enum PaceLocalMemoryStore {
    static func string(for key: PaceLocalMemoryKey) -> String? {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey(for: key))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue?.isEmpty == false ? rawValue : nil
    }

    static func setString(_ value: String?, for key: PaceLocalMemoryKey) {
        let userDefaultsKey = userDefaultsKey(for: key)
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            return
        }
        UserDefaults.standard.set(trimmedValue, forKey: userDefaultsKey)
    }

    static var summaryText: String {
        let storedPairs = [
            ("Browser", string(for: .preferredBrowser)),
            ("Notes", string(for: .preferredNotesApp)),
            ("Reminders", string(for: .defaultReminderList)),
        ].compactMap { label, value in
            value.map { "\(label): \($0)" }
        }

        return storedPairs.isEmpty ? "No saved preferences" : storedPairs.joined(separator: " · ")
    }

    private static func userDefaultsKey(for key: PaceLocalMemoryKey) -> String {
        "pace.localMemory.\(key.rawValue)"
    }
}

enum PaceLocalMemoryCommand: Equatable {
    case set(PaceLocalMemoryKey, String)
    case forget(PaceLocalMemoryKey)
}

enum PaceLocalMemoryCommandParser {
    static func parse(_ transcript: String) -> PaceLocalMemoryCommand? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercaseTranscript = trimmedTranscript.lowercased()

        if lowercaseTranscript.contains("forget preferred browser")
            || lowercaseTranscript.contains("forget my preferred browser") {
            return .forget(.preferredBrowser)
        }

        if let preferredBrowser = valueAfterAnyPrefix(
            in: trimmedTranscript,
            prefixes: [
                "remember my preferred browser is ",
                "remember preferred browser is ",
                "my preferred browser is ",
            ],
            suffixes: [" as my browser", " as preferred browser"]
        ) {
            return .set(.preferredBrowser, preferredBrowser)
        }

        if let preferredNotesApp = valueAfterAnyPrefix(
            in: trimmedTranscript,
            prefixes: [
                "remember my notes app is ",
                "remember preferred notes app is ",
                "my notes app is ",
            ],
            suffixes: []
        ) {
            return .set(.preferredNotesApp, preferredNotesApp)
        }

        return nil
    }

    private static func valueAfterAnyPrefix(
        in transcript: String,
        prefixes: [String],
        suffixes: [String]
    ) -> String? {
        let lowercaseTranscript = transcript.lowercased()
        for prefix in prefixes {
            guard let prefixRange = lowercaseTranscript.range(of: prefix) else {
                continue
            }

            let rawValueStartIndex = prefixRange.upperBound
            let rawValue = String(transcript[rawValueStartIndex...])
            let trimmedValue = removeAnySuffix(rawValue, suffixes: suffixes)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        return nil
    }

    private static func removeAnySuffix(_ rawValue: String, suffixes: [String]) -> String {
        let lowercaseRawValue = rawValue.lowercased()
        for suffix in suffixes {
            guard let suffixRange = lowercaseRawValue.range(of: suffix) else {
                continue
            }
            return String(rawValue[..<suffixRange.lowerBound])
        }
        return rawValue
    }
}
