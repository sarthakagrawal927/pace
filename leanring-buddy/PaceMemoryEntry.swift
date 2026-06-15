//
//  PaceMemoryEntry.swift
//  leanring-buddy
//
//  The single typed, timestamped, embeddable unit of the unified memory
//  index (see docs/prds/unified-memory.md, Phase 1). Every memory Pace
//  holds — a conversation turn, a durable fact, a stored preference, a
//  journal highlight, or a rolling summary — is one of these.
//
//  Pure value type. No I/O, no app wiring. Ships dark.
//

import Foundation

enum PaceMemoryEntryKind: String, Codable, Equatable, CaseIterable {
    case conversationTurn
    case fact
    case preference
    case journalEvent
    case summary
}

struct PaceMemoryEntry: Codable, Equatable, Identifiable {
    let id: String
    var kind: PaceMemoryEntryKind
    var text: String
    var structured: [String: String]?
    var source: PaceRetrievalSource
    var createdAt: Date
    var updatedAt: Date
    var embedding: [Float]?
    var confidence: Double?
    var topicTags: [String]
    var tombstonedAt: Date?

    var isActive: Bool {
        tombstonedAt == nil
    }
}
