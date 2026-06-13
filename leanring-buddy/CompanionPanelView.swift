//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Bumped after each starter-prompt tap or dismiss so the card
    /// re-reads `PaceStarterPromptStore` and shows the updated state
    /// (checkmark, dismissed, auto-dismissed-after-4-tries). The store
    /// is UserDefaults-backed so SwiftUI doesn't see writes otherwise.
    @State private var starterPromptStateRevision: Int = 0

    /// In-panel chat input draft text. Bound to the TextField shown
    /// when the `cmd+shift+P` shortcut fires. Cleared on submit and
    /// when the input dismisses (so a re-open starts blank).
    @State private var notchChatDraftText: String = ""

    /// Wires the TextField to the companion manager's notch-chat
    /// focus flag so the global shortcut can move focus into the
    /// field even when the panel is already on screen.
    @FocusState private var isNotchChatInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                starterPromptCardSection
                    .padding(.horizontal, 16)

                morningBriefCardSection
                    .padding(.horizontal, 16)

                notchChatInputSection
                    .padding(.horizontal, 16)

                PaceTurnHUDView(companionManager: companionManager)
                    .padding(.horizontal, 16)

                replayLastSpokenReplySection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                PaceModelStatusView(companionManager: companionManager)
                    .padding(.horizontal, 16)

                PaceQuickTogglesView(companionManager: companionManager)
                    .padding(.horizontal, 16)

                PaceToolPermissionsView(companionManager: companionManager)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)

                PaceActionResultsView(companionManager: companionManager)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)

                PaceMemoryRetrievalSummaryView(companionManager: companionManager)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                PaceCorePermissionsView(companionManager: companionManager)
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Pace toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showPaceCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Pace")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                PaceMainWindowManager.shared.show(companionManager: companionManager)
                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
            }) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Open Pace window — conversations, usage, permissions")
            .pointerCursor()

            Button(action: {
                PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Open settings")
            .pointerCursor()

            Button(action: {
                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Starter prompt card (first-run "Try these")

    /// First-run "Try these" card. Pinned to the top of the panel for
    /// the first 24h after the user first opens the panel with the card
    /// visible, then auto-hides. Reads PaceStarterPromptStore for the
    /// tried-set and the visibility decision; writes back through the
    /// same store when the user taps a row or hides the card.
    @ViewBuilder
    private var starterPromptCardSection: some View {
        // `starterPromptStateRevision` is referenced so SwiftUI re-runs
        // this body after a tap or dismiss writes to UserDefaults. The
        // explicit `_ = starterPromptStateRevision` would also work, but
        // putting the read inside the visibility check is what actually
        // drives the dependency tracking.
        let _ = starterPromptStateRevision
        if PaceStarterPromptStore.isVisible() {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Try these")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer(minLength: 0)

                    Button(action: dismissStarterPromptCard) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle().fill(Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Hide for now")
                }

                VStack(spacing: 4) {
                    ForEach(PaceStarterPromptCatalog.all) { starterPrompt in
                        starterPromptRow(starterPrompt: starterPrompt)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .padding(.bottom, 8)
            .onAppear {
                PaceStarterPromptStore.markFirstSeenIfNeeded()
            }
        }
    }

    private func starterPromptRow(starterPrompt: PaceStarterPrompt) -> some View {
        let hasTried = PaceStarterPromptStore.hasTried(slug: starterPrompt.slug)
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: hasTried ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hasTried ? DS.Colors.success : DS.Colors.textTertiary)
                .frame(width: 14)

            Text(starterPrompt.displayText)
                .font(.system(size: 11))
                .foregroundColor(hasTried ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: {
                submitStarterPrompt(starterPrompt: starterPrompt)
            }) {
                Text("ask")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Ask Pace this — same path as voice or chat.")
        }
        .padding(.vertical, 2)
    }

    private func submitStarterPrompt(starterPrompt: PaceStarterPrompt) {
        // The store is updated BEFORE submission so the checkmark
        // appears immediately. Even if the planner call fails, the
        // user clearly tried this prompt.
        PaceStarterPromptStore.markTried(slug: starterPrompt.slug)
        starterPromptStateRevision += 1
        companionManager.submitChatTranscriptFromDeepLink(starterPrompt.displayText)
    }

    private func dismissStarterPromptCard() {
        PaceStarterPromptStore.markDismissed()
        starterPromptStateRevision += 1
    }

    // MARK: - Morning brief card

    /// Calm full-width card pinned to the top of the panel whenever the
    /// morning-brief scheduler has a queued brief waiting for the user.
    /// Renders nothing when there is no pending card so the panel stays
    /// quiet on a normal day.
    @ViewBuilder
    private var morningBriefCardSection: some View {
        if let pendingMorningBriefCard = companionManager.morningTriageScheduler.pendingMorningBriefCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Morning brief")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer(minLength: 0)

                    Button(action: {
                        companionManager.playPendingMorningBrief()
                    }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle().fill(Color.white.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Speak the brief now")

                    Button(action: {
                        companionManager.morningTriageScheduler.dismissPendingCard()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle().fill(Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Dismiss")
                }

                Text(pendingMorningBriefCard)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .padding(.bottom, 8)
        }
    }

    // MARK: - Permissions Copy

    // Reply-replay button shown for 30 seconds after every assistant
    // turn finishes speaking. See PRD docs/prds/trust-and-failures.md.
    // Driven entirely by the manager's `lastSpokenReplyAt` timestamp;
    // a per-second TimelineView keeps the visibility window honest
    // without subscribing to a dedicated clock.
    @ViewBuilder
    private var replayLastSpokenReplySection: some View {
        if let lastSpokenReplyAt = companionManager.lastSpokenReplyAt,
           companionManager.lastSpokenReplyText?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            TimelineView(.periodic(from: lastSpokenReplyAt, by: 1)) { context in
                let elapsedSeconds = context.date.timeIntervalSince(lastSpokenReplyAt)
                let replayWindowSeconds: TimeInterval = 30
                if elapsedSeconds < replayWindowSeconds {
                    Button(action: {
                        companionManager.replayLastSpokenReply()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                            Text("Replay last reply")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else {
                    EmptyView()
                }
            }
        } else {
            EmptyView()
        }
    }

    /// Compact chat input that pops up inside the notch panel when the
    /// global `cmd+shift+P` shortcut fires. Enter submits through the
    /// same `submitChatTranscriptFromDeepLink(_:)` hook as voice and
    /// the main window chat; Esc dismisses. After submission the
    /// existing `turnHUDSection` below takes over for the streaming
    /// reply — the notch is intentionally too small to host a full
    /// chat scrollback.
    @ViewBuilder
    private var notchChatInputSection: some View {
        if companionManager.isNotchChatInputFocused {
            HStack(spacing: 6) {
                TextField(
                    "Ask Pace — Enter to send, Esc to cancel",
                    text: $notchChatDraftText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isNotchChatInputFocused)
                .onSubmit(submitNotchChatDraftText)
                .onExitCommand { dismissNotchChatInput() }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )

                Button(action: submitNotchChatDraftText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(notchChatDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? DS.Colors.textTertiary
                                         : DS.Colors.textPrimary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .keyboardShortcut(.return, modifiers: [])
                .disabled(notchChatDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send to Pace")
            }
            .onAppear {
                isNotchChatInputFocused = true
            }
            // Mirror the manager-published flag into the local
            // FocusState so the global shortcut can re-focus an
            // already-visible field (FocusState only changes when its
            // boolean transitions, so we coalesce both directions).
            .onChange(of: companionManager.isNotchChatInputFocused) { newValue in
                isNotchChatInputFocused = newValue
            }
        }
    }

    private func submitNotchChatDraftText() {
        let trimmedDraftText = notchChatDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraftText.isEmpty else { return }
        companionManager.submitChatTranscriptFromDeepLink(trimmedDraftText)
        notchChatDraftText = ""
        companionManager.dismissNotchChatInputAfterSubmit()
        isNotchChatInputFocused = false
    }

    private func dismissNotchChatInput() {
        notchChatDraftText = ""
        companionManager.dismissNotchChatInputAfterSubmit()
        isNotchChatInputFocused = false
    }

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant the core items below to keep using Pace.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("This is Pace.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A fully on-device voice agent that watches your screen and helps as you work.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Pace only captures the screen when you press the hotkey or turn on Watch Mode. Local app control asks for macOS permission the first time you use each tool.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button
    //
    // Pace bypasses the upstream first-run flow (no email gate, no
    // welcome video). `hasCompletedOnboarding` is hard-coded true on
    // the manager, so this view body never renders — the cursor and
    // walking avatar appear as soon as all permissions are granted.
    // Kept as a `private var` placeholder to keep the rest of the
    // panel body's conditional structure intact without touching the
    // call site.
    @ViewBuilder
    private var startButton: some View {
        EmptyView()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Pace")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .processing, .responding:
            return DS.Colors.accent
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
