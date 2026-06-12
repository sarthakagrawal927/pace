//
//  PaceChatSession.swift
//  leanring-buddy
//
//  Backing store for the in-window chat surface in the Conversations tab.
//  This file owns the ordered list of messages the SwiftUI view renders;
//  the SOURCE OF TRUTH for persistence is still the existing `paceHistory`
//  retrieval index that voice turns already write to via
//  `PaceLocalRetriever.recordPaceHistory`. The chat session reads from
//  that same index at load time and listens for new turns through
//  `appendTurn(userTranscript:assistantResponse:)`, which `CompanionManager`
//  calls from the single `recordConversationTurn` chokepoint — so voice
//  and chat are always rendering the same conversation.
//
//  Mute is intentionally a per-session ephemeral `@Published` flag: it
//  is NOT persisted (no UserDefaults, no chat-level prefs file). On app
//  restart it returns to the default (false → Pace still speaks). The
//  flag is read once per turn by `CompanionManager` when chat-mode
//  submission begins, so toggling it mid-turn affects the NEXT turn but
//  not the one currently streaming — matches voice-turn semantics.
//

import Combine
import Foundation
import SwiftUI

enum PaceChatRole: String, Codable, Equatable {
    case user
    case pace
}

struct PaceChatMessage: Identifiable, Equatable {
    let id: String
    let role: PaceChatRole
    let body: String
    let createdAt: Date
}

/// Read surface the chat session uses to rehydrate prior turns from
/// `paceHistory`. Kept as a tiny protocol so unit tests can inject a
/// fixture list of turns without standing up the full retrieval index.
/// The single conformer in product code is `PaceLocalChatHistoryReader`,
/// which reads the same `retrieval-index.json` the legacy
/// `PaceConversationsView` static reader used to read.
protocol PaceChatHistorySource: AnyObject {
    /// Returns past Pace turns oldest-first so the chat transcript can
    /// be appended in natural order (newest at the bottom).
    func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn]
}

/// Raw turn pair extracted from `paceHistory` storage. Mirrors the
/// "User: …\nPace: …" body shape `recordPaceHistory` writes; the
/// session expands each pair into two `PaceChatMessage` rows.
struct PaceChatHistoryTurn: Equatable {
    let id: String
    let userText: String
    let paceText: String
    let recordedAt: Date?
}

/// Thin abstraction over the chat-mode submission path on
/// `CompanionManager`. Exists so `PaceChatSession` can be unit-tested
/// without instantiating a real `CompanionManager` (which owns the
/// dictation engine, the LM Studio client, and a dozen other heavy
/// dependencies). Production wiring passes a closure that forwards
/// into `submitChatTranscriptFromChatSession(_:)`.
protocol PaceChatTranscriptSubmitting: AnyObject {
    func submitChatTranscript(_ transcript: String)
}

@MainActor
final class PaceChatSession: ObservableObject {
    @Published private(set) var messages: [PaceChatMessage] = []
    @Published private(set) var hasLoadedHistory: Bool = false

    /// Mute toggle for THIS session only. Reset to `false` on every app
    /// launch (a fresh `CompanionManager` builds a fresh session) so
    /// nothing persists across restarts. The PRD explicitly calls this
    /// out: "Mute is a per-session ephemeral flag — do NOT persist it
    /// across restart."
    @Published var isChatTTSMuted: Bool = false

    private let historySource: PaceChatHistorySource
    /// Strongly held. The adapter that conforms to this protocol in
    /// production code holds `CompanionManager` weakly, so a strong
    /// reference here cannot create a retain cycle. Tests can pass a
    /// fixture submitter that's safe to keep alive for the lifetime of
    /// the session under test.
    private let transcriptSubmitter: any PaceChatTranscriptSubmitting

    init(
        historySource: PaceChatHistorySource,
        transcriptSubmitter: any PaceChatTranscriptSubmitting
    ) {
        self.historySource = historySource
        self.transcriptSubmitter = transcriptSubmitter
    }

    /// Pulls past `paceHistory` turns and seeds `messages` with them.
    /// Idempotent: re-loading replaces the rendered transcript wholesale
    /// from the persistence layer, so newly-arrived voice turns show up
    /// when the user re-opens the window. Safe to call from `.onAppear`.
    func loadHistory() {
        let pastTurns = historySource.loadPastTurnsOldestFirst()
        var rehydratedMessages: [PaceChatMessage] = []
        rehydratedMessages.reserveCapacity(pastTurns.count * 2)
        for pastTurn in pastTurns {
            let baseTimestamp = pastTurn.recordedAt ?? Date.distantPast
            if !pastTurn.userText.isEmpty {
                rehydratedMessages.append(
                    PaceChatMessage(
                        id: "\(pastTurn.id):user",
                        role: .user,
                        body: pastTurn.userText,
                        createdAt: baseTimestamp
                    )
                )
            }
            if !pastTurn.paceText.isEmpty {
                rehydratedMessages.append(
                    PaceChatMessage(
                        id: "\(pastTurn.id):pace",
                        role: .pace,
                        // Offset the assistant timestamp by 1ms so
                        // ordering by `createdAt` is stable when the
                        // recorded turn timestamp is the same for both
                        // halves (always true — they're written
                        // together).
                        body: pastTurn.paceText,
                        createdAt: baseTimestamp.addingTimeInterval(0.001)
                    )
                )
            }
        }
        messages = rehydratedMessages
        hasLoadedHistory = true
    }

    /// Called by the chat view when the user hits Enter. Trims the
    /// input, appends the user message locally so the row renders
    /// immediately (the planner pipeline can take seconds to start
    /// streaming), then forwards to `CompanionManager` through the
    /// submitter. The matching assistant message is appended later by
    /// `appendCompletedTurn` from `recordConversationTurn` — that's
    /// where we get the final cleaned spoken text.
    func submitUserMessage(_ rawTranscript: String) {
        let trimmedTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        let now = Date()
        let pendingMessageId = "chat-pending-\(Int(now.timeIntervalSince1970 * 1000))-\(abs(trimmedTranscript.hashValue))"
        messages.append(
            PaceChatMessage(
                id: pendingMessageId,
                role: .user,
                body: trimmedTranscript,
                createdAt: now
            )
        )
        transcriptSubmitter.submitChatTranscript(trimmedTranscript)
    }

    /// `CompanionManager.recordConversationTurn` calls this after every
    /// turn — voice OR chat — so the chat surface stays aligned with
    /// the canonical `paceHistory` write. Dedupes against the optimistic
    /// user row that `submitUserMessage` appended.
    func appendCompletedTurn(
        userTranscript: String,
        assistantResponse: String,
        recordedAt: Date = Date()
    ) {
        let trimmedUserTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistantResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableTurnIdPrefix = "chat-\(Int(recordedAt.timeIntervalSince1970))-\(abs(trimmedUserTranscript.hashValue))"

        let mostRecentMessage = messages.last
        let alreadyHasMatchingUserRow = mostRecentMessage?.role == .user
            && mostRecentMessage?.body == trimmedUserTranscript
        if !trimmedUserTranscript.isEmpty && !alreadyHasMatchingUserRow {
            messages.append(
                PaceChatMessage(
                    id: "\(stableTurnIdPrefix):user",
                    role: .user,
                    body: trimmedUserTranscript,
                    createdAt: recordedAt
                )
            )
        }

        if !trimmedAssistantResponse.isEmpty {
            messages.append(
                PaceChatMessage(
                    id: "\(stableTurnIdPrefix):pace",
                    role: .pace,
                    body: trimmedAssistantResponse,
                    createdAt: recordedAt.addingTimeInterval(0.001)
                )
            )
        }
    }

    /// Pure test surface: returns whichever subset of `messages` matches
    /// the search query (case-insensitive substring against role-agnostic
    /// body text). Lives here rather than in the view so the search
    /// behavior is unit-testable and consistent if more surfaces start
    /// rendering the chat transcript.
    func filteredMessages(matching searchQuery: String) -> [PaceChatMessage] {
        let trimmedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmedQuery.isEmpty else { return messages }
        return messages.filter { message in
            message.body.lowercased().contains(trimmedQuery)
        }
    }
}

/// Production conformer of `PaceChatHistorySource`. Reads the same
/// `retrieval-index.json` file that the static reader inside
/// `PaceConversationsView` used to read directly — but exposes it as
/// an injectable protocol so the new chat code stays unit-testable.
@MainActor
final class PaceLocalChatHistoryReader: PaceChatHistorySource {

    func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
        guard let indexURL = retrievalIndexFileURL(),
              let indexData = try? Data(contentsOf: indexURL),
              let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let rawDocuments = indexJSON["documents"] as? [[String: Any]] else {
            return []
        }

        let isoDateFormatterWithFractionalSeconds = ISO8601DateFormatter()
        isoDateFormatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoDateFormatterPlain = ISO8601DateFormatter()

        let pastTurns: [PaceChatHistoryTurn] = rawDocuments.compactMap { documentRaw in
            guard let source = documentRaw["source"] as? String, source == "paceHistory",
                  let id = documentRaw["id"] as? String,
                  let bodyText = documentRaw["text"] as? String else {
                return nil
            }
            let (userText, paceText) = Self.splitUserAndPace(bodyText)
            let recordedAt: Date?
            if let modifiedAt = documentRaw["modifiedAt"] as? Double {
                recordedAt = Date(timeIntervalSinceReferenceDate: modifiedAt)
            } else if let modifiedAtString = documentRaw["modifiedAt"] as? String {
                recordedAt = isoDateFormatterWithFractionalSeconds.date(from: modifiedAtString)
                    ?? isoDateFormatterPlain.date(from: modifiedAtString)
            } else {
                recordedAt = nil
            }
            return PaceChatHistoryTurn(
                id: id,
                userText: userText,
                paceText: paceText,
                recordedAt: recordedAt
            )
        }
        // Oldest-first so the chat transcript renders top-down with the
        // newest message at the bottom — standard chat ordering.
        return pastTurns.sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
    }

    private func retrievalIndexFileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace/retrieval-index.json")
    }

    /// Pace history docs are stored as "User: …\nPace: …". Same logic
    /// the legacy static reader used; moved here so the production
    /// conformer and tests share one parser.
    static func splitUserAndPace(_ documentText: String) -> (userText: String, paceText: String) {
        let lowercasedDocument = documentText.lowercased()
        guard let userMarkerRange = lowercasedDocument.range(of: "user:") else {
            return (documentText, "")
        }
        let afterUserMarker = documentText[userMarkerRange.upperBound...]
        if let paceMarkerRange = afterUserMarker.range(of: "Pace:") {
            let userText = afterUserMarker[..<paceMarkerRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paceText = afterUserMarker[paceMarkerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (userText, paceText)
        }
        return (
            afterUserMarker.trimmingCharacters(in: .whitespacesAndNewlines),
            ""
        )
    }
}
