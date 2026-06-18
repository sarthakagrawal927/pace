//
//  PaceConversationsView.swift
//  leanring-buddy
//
//  Chat surface for the Conversations tab of the main window. Renders
//  the live, ordered transcript backed by `PaceChatSession` — which in
//  turn reads/writes through the same `paceHistory` retrieval index
//  that voice turns already persist to, so voice and chat always share
//  one canonical conversation. Below the transcript is a sticky text
//  input: Enter dispatches through the same `submitChatTranscriptFrom…`
//  pipeline a `pace://chat` deeplink uses. The notch panel stays
//  voice-first; THIS surface is the text-fallback PRD deliverable.
//
//  The search field from the prior read-only list view is preserved as
//  an in-line filter so an existing user habit ("open Pace, search for
//  what we talked about last week") still works.
//

import Foundation
import SwiftUI

struct PaceConversationsView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var searchQuery: String = ""
    @State private var draftMessageText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chatHeader
            searchField
            transcriptScrollView
            footerHint
            chatInputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            companionManager.chatSession.loadHistory()
            isInputFocused = true
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Text("Conversations")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            muteToggleButton
            Button(action: { companionManager.chatSession.loadHistory() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh from the local retrieval index")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var muteToggleButton: some View {
        // Read the published flag through the chat session so any other
        // surface that flips it (currently none, but the property is
        // public on the session) stays in sync with this view.
        let isMuted = companionManager.chatSession.isChatTTSMuted
        return Button {
            companionManager.chatSession.isChatTTSMuted.toggle()
        } label: {
            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                .foregroundColor(isMuted ? .secondary : .primary)
        }
        .buttonStyle(.plain)
        .help(isMuted
              ? "Pace replies silently this session. Click to unmute."
              : "Pace speaks replies. Click to mute for this session.")
    }

    // MARK: - Search

    private var searchField: some View {
        TextField("Search past turns…", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 24)
            .padding(.top, 12)
    }

    // MARK: - Transcript

    private var transcriptScrollView: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if filteredMessages.isEmpty {
                        emptyStateText
                            .padding(.top, 60)
                    } else {
                        ForEach(filteredMessages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    streamingAssistantRowIfActive
                        .id(PaceConversationsView.streamingRowAnchorId)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: companionManager.chatSession.messages.count) {
                scrollToBottom(scrollViewProxy: scrollViewProxy)
            }
            .onChange(of: companionManager.streamingSentenceTTSPipeline.inFlightStreamedText) {
                scrollToBottom(scrollViewProxy: scrollViewProxy)
            }
            .onAppear {
                scrollToBottom(scrollViewProxy: scrollViewProxy, animated: false)
            }
        }
    }

    private static let streamingRowAnchorId = "streaming-assistant-row-anchor"

    private func scrollToBottom(scrollViewProxy: ScrollViewProxy, animated: Bool = true) {
        let targetId: String = {
            if companionManager.streamingSentenceTTSPipeline.inFlightStreamedText.isEmpty == false {
                return PaceConversationsView.streamingRowAnchorId
            }
            return companionManager.chatSession.messages.last?.id
                ?? PaceConversationsView.streamingRowAnchorId
        }()
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                scrollViewProxy.scrollTo(targetId, anchor: .bottom)
            }
        } else {
            scrollViewProxy.scrollTo(targetId, anchor: .bottom)
        }
    }

    private var emptyStateText: some View {
        VStack(spacing: 4) {
            Text("No conversations yet.")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            Text("Type below or press ctrl+option anywhere to talk.")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredMessages: [PaceChatMessage] {
        companionManager.chatSession.filteredMessages(matching: searchQuery)
    }

    private func messageRow(_ message: PaceChatMessage) -> some View {
        let isFromUser = message.role == .user
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(isFromUser ? "You" : "Pace")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text(message.body)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(isFromUser
                    ? Color(NSColor.controlBackgroundColor)
                    : Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .contextMenu {
            // Right-click any message to share or copy. NSSharing-
            // ServicePicker enumerates every install destination —
            // Messages, Mail, Notes, AirDrop, third-party share
            // extensions — so we don't have to build per-target
            // integrations. The picker is anchored to a hidden
            // tracker view we attach via NSViewRepresentable.
            ShareAndCopyContextMenuItems(messageBody: message.body)
        }
    }

    @ViewBuilder
    private var streamingAssistantRowIfActive: some View {
        let streamingText = companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
        if !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Pace")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("typing…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text(streamingText)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
        } else {
            // Empty spacer keeps the ScrollViewReader anchor present so
            // initial scroll-to-bottom never targets a missing id.
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - Footer + input

    private var footerHint: some View {
        Text("Tip: you can also press ctrl+option anywhere to talk.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 4)
    }

    private var chatInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Type a message — Enter to send, Shift+Enter for newline",
                text: $draftMessageText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            .focused($isInputFocused)
            .onSubmit(submitDraftMessage)
            .help("Pace replies inline and speaks aloud unless muted.")

            Button("Send", action: submitDraftMessage)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func submitDraftMessage() {
        let trimmedDraftMessage = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraftMessage.isEmpty else { return }
        companionManager.chatSession.submitUserMessage(trimmedDraftMessage)
        draftMessageText = ""
        isInputFocused = true
    }
}

// MARK: - Share + Copy context menu items

/// Right-click menu actions for a chat message. The Share entry
/// hands the message to NSSharingServicePicker; the Copy entry
/// stays in pasteboard land for users who'd rather paste it
/// themselves. The view embeds a hidden NSView via
/// NSViewRepresentable so NSSharingServicePicker has a real
/// AppKit anchor to position itself against.
private struct ShareAndCopyContextMenuItems: View {
    let messageBody: String

    var body: some View {
        Button("Copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(messageBody, forType: .string)
        }
        Button("Share…") {
            presentSystemSharePickerAnchoredToKeyWindow()
        }
    }

    /// Anchor the share picker to whichever NSView is currently
    /// receiving events in the key window. Using the key window's
    /// content view as the anchor is what every other right-click-
    /// initiated share picker on macOS does, and it produces the
    /// expected "share sheet floats near where I right-clicked"
    /// behaviour without us having to thread a per-row NSView
    /// reference through SwiftUI.
    private func presentSystemSharePickerAnchoredToKeyWindow() {
        guard let anchorView = NSApp.keyWindow?.contentView else { return }
        PaceMessageShareService.presentSharePicker(
            forText: messageBody,
            anchoredTo: anchorView
        )
    }
}
