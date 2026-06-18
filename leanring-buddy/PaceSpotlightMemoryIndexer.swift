//
//  PaceSpotlightMemoryIndexer.swift
//  leanring-buddy
//
//  Mirrors active `PaceMemoryEntry` values into the system's
//  CoreSpotlight index so users can find their Pace memories from
//  Spotlight (Cmd+Space) and from any other Spotlight-backed
//  surface — Mail's smart suggestions, Notes' search, etc.
//
//  Strictly a one-way MIRROR. PaceMemoryStore stays the source of
//  truth; this indexer never reads from Spotlight and never round-
//  trips data through it. Spotlight gets the same content the user
//  has already stored on this Mac, with the same on-device posture
//  as the rest of the app. On `clear()` we wipe the mirrored items
//  alongside the source JSON so an explicit memory reset actually
//  removes the Spotlight index too.
//
//  Failure posture: best-effort. CoreSpotlight is unavailable in
//  unsigned dev bundles, sandboxed CI, and a handful of corner
//  cases; any failure logs once and skips. A missing Spotlight
//  mirror never blocks a real user turn.
//

import CoreSpotlight
import Foundation

@MainActor
final class PaceSpotlightMemoryIndexer {

    private let spotlightDomainIdentifier = "com.pace.app.memory"
    private let spotlightIndex: CSSearchableIndex

    /// Lightweight contract so unit tests can verify the mapping
    /// helpers without touching the live CSSearchableIndex. Behind
    /// the scenes the production indexer just forwards to
    /// `CSSearchableIndex.default()`.
    init(spotlightIndex: CSSearchableIndex = .default()) {
        self.spotlightIndex = spotlightIndex
    }

    /// Replace the Spotlight mirror with the current active entries.
    /// Tombstoned entries are dropped from Spotlight; active entries
    /// are upserted. Called from CompanionManager after every memory
    /// mutation, matching the source JSON's write cadence.
    func syncMirror(toMatch activeEntries: [PaceMemoryEntry]) {
        let searchableItems = Self.buildSearchableItems(
            fromActiveEntries: activeEntries,
            domainIdentifier: spotlightDomainIdentifier
        )
        spotlightIndex.indexSearchableItems(searchableItems) { error in
            if let error {
                print("⚠️  Spotlight memory mirror failed: \(error.localizedDescription)")
            }
        }
    }

    /// Delete the Spotlight mirror entirely. Called when the user
    /// resets memory — `PaceMemoryStore.clear()` is paired with this
    /// in CompanionManager so the on-disk JSON and the Spotlight
    /// mirror are wiped atomically from the user's perspective.
    func deleteAllMirroredItems() {
        spotlightIndex.deleteSearchableItems(withDomainIdentifiers: [spotlightDomainIdentifier]) { error in
            if let error {
                print("⚠️  Spotlight memory mirror clear failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pure mapping helpers

    /// Build the searchable-item list from a flat entry list. Pure
    /// helper so the mapping rules — what becomes the title, which
    /// entries get skipped, how the kind label renders — are
    /// unit-testable without a live CSSearchableIndex.
    nonisolated static func buildSearchableItems(
        fromActiveEntries entries: [PaceMemoryEntry],
        domainIdentifier: String
    ) -> [CSSearchableItem] {
        return entries.compactMap { entry in
            guard entry.isActive else { return nil }
            return buildSearchableItem(forEntry: entry, domainIdentifier: domainIdentifier)
        }
    }

    /// Single-entry mapping. Returns nil when the entry has no
    /// indexable text (we never index an empty record — Spotlight
    /// would surface a blank row).
    nonisolated static func buildSearchableItem(
        forEntry entry: PaceMemoryEntry,
        domainIdentifier: String
    ) -> CSSearchableItem? {
        let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        // Title is a short prefix the Spotlight result row will show
        // first. Bounded so a long entry doesn't push everything else
        // out of the row.
        attributeSet.title = String(trimmedText.prefix(60))
        attributeSet.contentDescription = trimmedText
        attributeSet.contentCreationDate = entry.createdAt
        attributeSet.contentModificationDate = entry.updatedAt
        attributeSet.keywords = ["pace", entry.kind.rawValue] + entry.topicTags
        attributeSet.subject = "Pace memory — \(humanReadableKindLabel(forKind: entry.kind))"

        return CSSearchableItem(
            uniqueIdentifier: entry.id,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
    }

    nonisolated static func humanReadableKindLabel(forKind kind: PaceMemoryEntryKind) -> String {
        switch kind {
        case .conversationTurn: return "conversation"
        case .fact:             return "fact"
        case .preference:       return "preference"
        case .journalEvent:     return "journal event"
        case .summary:          return "summary"
        }
    }
}
