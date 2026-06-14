//
//  PacePanelChatView.swift
//  leanring-buddy
//
//  The premium notch/corner panel surface: a clean conversation view, like a
//  focused command bar. A compact header (status + gear → Settings + close),
//  the live transcript (your words typed or spoken, Pace's streamed reply,
//  tool use inline), and a sticky input. Everything else — planner/voice/ASR
//  status, toggles, permissions, activity, memory — lives behind the gear in
//  PaceSettingsWindow.
//
//  Replaces the prior `CompanionPanelView` dashboard as the panel's content.
//  `CompanionPanelView` is kept in the tree (not deleted) so it's a one-line
//  revert if needed.
//
//  Backed entirely by existing state: `PaceChatSession` (shared voice+chat
//  transcript), `inFlightStreamedText` (live streamed reply), and the same
//  submit pipeline the chat tab uses. Live speech-to-text and inline tool
//  chips layer in on top of this surface.
//

import SwiftUI

struct PacePanelChatView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var draftMessageText: String = ""
    @FocusState private var isInputFocused: Bool

    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)
            transcript
            Divider().background(DS.Colors.borderSubtle)
            inputRow
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(DS.Colors.background)
        .onAppear {
            companionManager.chatSession.loadHistory()
            isInputFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.6), radius: 4)
            Text("Pace")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            iconButton(systemName: "gearshape", help: "Settings — planner, voice, permissions, activity") {
                PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            }
            iconButton(systemName: "xmark", help: "Close") {
                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func iconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if threadItems.isEmpty
                        && inFlightStreamedText.isEmpty
                        && liveSpeechDraft.isEmpty {
                        emptyState.padding(.top, 48)
                    } else {
                        ForEach(threadItems) { item in
                            switch item {
                            case .message(let message):
                                messageRow(message).id(item.id)
                            case .tool(let actionRecord):
                                toolChipRow(actionRecord).id(item.id)
                            }
                        }
                    }
                    liveUserBubbleRow
                    streamingReplyRow.id(Self.streamingAnchorID)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: companionManager.chatSession.messages.count) {
                scrollToBottom(scrollProxy)
            }
            .onChange(of: inFlightStreamedText) {
                scrollToBottom(scrollProxy)
            }
            .onChange(of: liveSpeechDraft) {
                scrollToBottom(scrollProxy)
            }
            .onChange(of: companionManager.recentActionResults.count) {
                scrollToBottom(scrollProxy)
            }
            .onAppear { scrollToBottom(scrollProxy, animated: false) }
        }
    }

    private static let streamingAnchorID = "panel-streaming-anchor"

    private func scrollToBottom(_ scrollProxy: ScrollViewProxy, animated: Bool = true) {
        // The streaming anchor row is always present at the very bottom
        // (Color.clear when idle), so it's a stable scroll target across
        // messages, tool chips, the live bubble, and the streamed reply.
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { scrollProxy.scrollTo(Self.streamingAnchorID, anchor: .bottom) }
        } else {
            scrollProxy.scrollTo(Self.streamingAnchorID, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Hold ⌃⌥ to talk")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("…or type below.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// A single item in the conversation timeline — either a chat message or
    /// a tool-use event — so tool use renders inline, in order, in the same
    /// thread (not a separate dashboard).
    private enum ThreadItem: Identifiable {
        case message(PaceChatMessage)
        case tool(PaceActionRunRecord)

        var id: String {
            switch self {
            case .message(let message): return "msg-\(message.id)"
            case .tool(let actionRecord): return "tool-\(actionRecord.id)"
            }
        }

        var sortDate: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .tool(let actionRecord): return actionRecord.createdAt
            }
        }
    }

    /// Chat messages + recent tool-use outcomes, merged by time. Only
    /// completed/failed actions become chips (skip the transient "planned"
    /// record so each tool use shows once, as its result).
    private var threadItems: [ThreadItem] {
        let messageItems = companionManager.chatSession.messages.map(ThreadItem.message)
        let toolItems = companionManager.recentActionResults
            .filter { $0.status == .completed || $0.status == .failed }
            .map(ThreadItem.tool)
        return (messageItems + toolItems).sorted { $0.sortDate < $1.sortDate }
    }

    /// An inline tool-use chip — a subtle centered capsule that reads as a
    /// system event in the conversation ("opened Hacker News").
    private func toolChipRow(_ actionRecord: PaceActionRunRecord) -> some View {
        let didFail = actionRecord.status == .failed
        let chipText = actionRecord.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? actionRecord.title
            : actionRecord.detail
        return HStack(spacing: 6) {
            Image(systemName: didFail ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(.system(size: 9, weight: .semibold))
            Text(chipText)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundColor(didFail ? DS.Colors.warning : DS.Colors.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(Color.white.opacity(0.05))
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func messageRow(_ message: PaceChatMessage) -> some View {
        let isFromUser = message.role == .user
        return HStack {
            if isFromUser { Spacer(minLength: 32) }
            Text(message.body)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFromUser ? DS.Colors.accent.opacity(0.22) : Color.white.opacity(0.05))
                )
                .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
            if !isFromUser { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private var streamingReplyRow: some View {
        if !inFlightStreamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text(inFlightStreamedText)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 32)
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var inFlightStreamedText: String {
        companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
    }

    /// The user's words as they speak — a right-aligned in-progress bubble
    /// that fills in live during listening, then is replaced by the committed
    /// message when the turn lands. Slightly more saturated than a committed
    /// user bubble to read as "in progress".
    @ViewBuilder
    private var liveUserBubbleRow: some View {
        if !liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Spacer(minLength: 32)
                Text(liveSpeechDraft)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Colors.accent.opacity(0.30))
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var liveSpeechDraft: String {
        companionManager.liveSpeechDraft
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Message Pace…", text: $draftMessageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit(submitDraft)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                        )
                )

            Button(action: submitDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(isDraftEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isDraftEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var isDraftEmpty: Bool {
        draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitDraft() {
        let trimmed = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionManager.chatSession.submitUserMessage(trimmed)
        draftMessageText = ""
        isInputFocused = true
    }

    // MARK: - Status

    private var statusDotColor: Color {
        switch companionManager.voiceState {
        case .listening: return DS.Colors.accent
        case .processing: return DS.Colors.warning
        case .responding: return DS.Colors.accent
        case .idle: return Color.green
        }
    }

    private var statusText: String {
        switch companionManager.voiceState {
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        case .idle: return "Ready"
        }
    }
}
