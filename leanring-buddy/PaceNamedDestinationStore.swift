//
//  PaceNamedDestinationStore.swift
//  leanring-buddy
//
//  User-taught web destinations: "remember this as the Cloudflare dashboard"
//  captures the current browser tab's URL under a name you choose; later
//  "open the Cloudflare dashboard" opens it on the deterministic fast path
//  (sub-200ms, no VLM, no planner). This is the user-defined generalization
//  of the hardcoded `knownWebsiteAliases` site map — Tier 1 (instant action)
//  powered by Tier 3 (personal memory).
//
//  Privacy: only the URL is stored, only on an explicit "remember this"
//  command. No passive browsing capture.
//

import Foundation

/// One user-taught destination. `displayName` is kept as the user said it
/// ("the Cloudflare dashboard") for natural spoken playback; recall matches
/// on a normalized key so phrasing differences don't matter.
struct PaceNamedDestination: Codable, Equatable {
    let displayName: String
    let url: String
    let createdAt: Date
}

/// What the user asked the destination memory to do.
enum PaceRememberSiteCommand: Equatable {
    /// "remember this as <name>" — name nil for "remember this [for me]"
    /// with no explicit name (the caller derives one from the page host).
    case remember(name: String?)
    /// "forget <name>".
    case forget(name: String)
}

@MainActor
final class PaceNamedDestinationStore {
    static let shared = PaceNamedDestinationStore()

    private var destinationsByKey: [String: PaceNamedDestination]

    init() {
        destinationsByKey = Self.loadFromDisk()
    }

    func save(displayName: String, url: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalize(trimmedName)
        guard !key.isEmpty else { return }
        destinationsByKey[key] = PaceNamedDestination(
            displayName: trimmedName,
            url: url,
            createdAt: Date()
        )
        persist()
    }

    /// Recall a destination from an "open <name>" style transcript. Returns
    /// nil unless the transcript names a destination the user actually saved,
    /// so non-matching opens fall straight through to the fast path.
    func recall(matching transcript: String) -> PaceNamedDestination? {
        guard let targetKey = Self.recallTargetKey(from: transcript) else { return nil }
        return destinationsByKey[targetKey]
    }

    @discardableResult
    func forget(displayName: String) -> Bool {
        guard destinationsByKey.removeValue(forKey: Self.normalize(displayName)) != nil else {
            return false
        }
        persist()
        return true
    }

    var all: [PaceNamedDestination] {
        destinationsByKey.values.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Normalization / matching

    /// Lowercase, drop a leading "the "/"my ", collapse whitespace, strip
    /// trailing punctuation. So "The Cloudflare Dashboard." and "cloudflare
    /// dashboard" map to the same key.
    static func normalize(_ name: String) -> String {
        var normalized = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        for leadingArticle in ["the ", "my "] {
            if normalized.hasPrefix(leadingArticle) {
                normalized.removeFirst(leadingArticle.count)
                break
            }
        }
        return normalized
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    /// Extracts the normalized destination key from an open-style transcript,
    /// or nil if the transcript isn't an open command. Mirrors the fast
    /// path's open prefixes plus a couple of natural recall phrasings.
    static func recallTargetKey(from transcript: String) -> String? {
        var normalizedTranscript = transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for wakePrefix in ["hey pace ", "pace ", "ok pace ", "okay pace "] {
            if normalizedTranscript.hasPrefix(wakePrefix) {
                normalizedTranscript.removeFirst(wakePrefix.count)
                break
            }
        }
        // Polite framing the planner-bound phrasing often carries.
        for politePrefix in ["can you ", "could you ", "please ", "would you "] {
            if normalizedTranscript.hasPrefix(politePrefix) {
                normalizedTranscript.removeFirst(politePrefix.count)
            }
        }
        let openPrefixes = ["open ", "go to ", "pull up ", "take me to ", "launch ", "visit "]
        for openPrefix in openPrefixes {
            guard normalizedTranscript.hasPrefix(openPrefix) else { continue }
            let remainder = String(normalizedTranscript.dropFirst(openPrefix.count))
            let key = normalize(remainder)
            return key.isEmpty ? nil : key
        }
        return nil
    }

    // MARK: - Persistence

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("named-destinations.json", isDirectory: false)
    }

    private func persist() {
        guard let fileURL = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(destinationsByKey) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk() -> [String: PaceNamedDestination] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: PaceNamedDestination].self, from: data)) ?? [:]
    }
}

/// Pure parser for the "remember this …" / "forget …" voice commands. Routed
/// before the planner in CompanionManager so teaching a destination never
/// burns a model turn.
enum PaceRememberSiteCommandParser {
    static func parse(transcript: String) -> PaceRememberSiteCommand? {
        var normalized = transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        for wakePrefix in ["hey pace ", "pace ", "ok pace ", "okay pace "] {
            if normalized.hasPrefix(wakePrefix) {
                normalized.removeFirst(wakePrefix.count)
                break
            }
        }

        // forget <name>
        for forgetPrefix in ["forget this site", "forget this page", "forget "] {
            guard normalized.hasPrefix(forgetPrefix) else { continue }
            let remainder = String(normalized.dropFirst(forgetPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            if forgetPrefix == "forget " {
                guard !remainder.isEmpty else { return nil }
                return .forget(name: remainder)
            }
            return remainder.isEmpty ? nil : .forget(name: remainder)
        }

        // remember this [page/site/tab] as <name>
        let asMarkers = [
            "remember this page as ", "remember this site as ",
            "remember this tab as ", "remember this as ", "remember as "
        ]
        for marker in asMarkers {
            guard normalized.hasPrefix(marker) else { continue }
            let name = String(normalized.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .remember(name: name)
        }

        // remember this [page/site/for me] — no explicit name
        let noNameForms: Set<String> = [
            "remember this", "remember this page", "remember this site",
            "remember this tab", "remember this for me", "remember this for later"
        ]
        if noNameForms.contains(normalized) {
            return .remember(name: nil)
        }

        return nil
    }
}
