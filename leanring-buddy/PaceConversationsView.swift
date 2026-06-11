//
//  PaceConversationsView.swift
//  leanring-buddy
//
//  Past turns view. Reads paceHistory documents from the local
//  retrieval index — every voice turn was already persisted there for
//  RAG; this surface just renders them for the user. No new data path.
//

import Foundation
import SwiftUI

struct PaceConversationTurnRow: Identifiable, Equatable {
    let id: String
    let userText: String
    let paceText: String
    let recordedAt: Date?
}

struct PaceConversationsView: View {
    @State private var conversationTurns: [PaceConversationTurnRow] = []
    @State private var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh from the local retrieval index")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            TextField("Search past turns…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            if filteredTurns.isEmpty {
                VStack {
                    Spacer()
                    Text(conversationTurns.isEmpty
                         ? "No conversations yet. Use push-to-talk or pace://chat to start one."
                         : "No turns match '\(searchQuery)'.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredTurns) { turn in
                            turnCard(turn)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refresh)
    }

    private var filteredTurns: [PaceConversationTurnRow] {
        let trimmedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmedQuery.isEmpty else { return conversationTurns }
        return conversationTurns.filter { turn in
            turn.userText.lowercased().contains(trimmedQuery)
                || turn.paceText.lowercased().contains(trimmedQuery)
        }
    }

    private func turnCard(_ turn: PaceConversationTurnRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recordedAt = turn.recordedAt {
                Text(recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("You").bold().frame(width: 48, alignment: .leading)
                Text(turn.userText).textSelection(.enabled)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("Pace").bold().frame(width: 48, alignment: .leading)
                Text(turn.paceText).textSelection(.enabled)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func refresh() {
        conversationTurns = Self.loadTurnsFromRetrievalIndex()
    }

    /// Reads paceHistory docs straight off disk. Avoids adding a new
    /// dependency on PaceLocalRetriever for read-only display.
    private static func loadTurnsFromRetrievalIndex() -> [PaceConversationTurnRow] {
        let indexURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace/retrieval-index.json")
        guard let indexURL,
              let indexData = try? Data(contentsOf: indexURL),
              let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let rawDocuments = indexJSON["documents"] as? [[String: Any]] else {
            return []
        }

        let isoDateFormatter = ISO8601DateFormatter()
        isoDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoDateFormatterNoFractional = ISO8601DateFormatter()

        let turnRows: [PaceConversationTurnRow] = rawDocuments.compactMap { documentRaw in
            guard let source = documentRaw["source"] as? String, source == "paceHistory",
                  let id = documentRaw["id"] as? String,
                  let bodyText = documentRaw["text"] as? String else {
                return nil
            }
            let (userText, paceText) = splitUserAndPace(bodyText)
            let recordedAt: Date?
            if let modifiedAt = documentRaw["modifiedAt"] as? Double {
                recordedAt = Date(timeIntervalSinceReferenceDate: modifiedAt)
            } else if let modifiedAtString = documentRaw["modifiedAt"] as? String {
                recordedAt = isoDateFormatter.date(from: modifiedAtString)
                    ?? isoDateFormatterNoFractional.date(from: modifiedAtString)
            } else {
                recordedAt = nil
            }
            return PaceConversationTurnRow(
                id: id,
                userText: userText,
                paceText: paceText,
                recordedAt: recordedAt
            )
        }
        // Newest first.
        return turnRows.sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
    }

    /// Pace history docs are stored as "User: …\nPace: …". Pull each
    /// half out so the view can render them with proper attribution.
    private static func splitUserAndPace(_ documentText: String) -> (String, String) {
        let lowercased = documentText.lowercased()
        guard let userRange = lowercased.range(of: "user:") else {
            return (documentText, "")
        }
        let afterUser = documentText[userRange.upperBound...]
        if let paceMarkerRange = afterUser.range(of: "Pace:") {
            let userText = afterUser[..<paceMarkerRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paceText = afterUser[paceMarkerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (userText, paceText)
        }
        return (
            afterUser.trimmingCharacters(in: .whitespacesAndNewlines),
            ""
        )
    }
}
