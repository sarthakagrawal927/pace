---
Status: shipped (v0.3.11)
owner: delegated to Sonnet agent
priority: P1 — text fallback for voice; closes the "Del/Poke chat-first" gap
---

# PRD — Chat Interface (text alongside voice)

## Goal

Let the user type to Pace from inside the app, not just press
PTT. Adds a chat surface that runs through the same planner
pipeline as voice. Useful in quiet environments, for long-form
asks the user wants to compose, and as the on-Mac analogue to
Del/Poke's chat-first interaction.

## Scope (v1)

A scrollable conversation view + text input field, lives in the
**Conversations tab of the existing `PaceMainWindow`** (the
resizable 900x620 window — NOT the notch panel; the notch stays
voice-first). The same tab already shows past turns from
`paceHistory` retrieval — extend it into a live chat surface.

User types a message → press Enter → message dispatches through
the same `submitChatTranscriptFromDeepLink(_:)` path that the
`pace://chat?text=...` deeplink already uses. Reply renders
inline AND speaks aloud via TTS (with a per-conversation mute
toggle).

Out of scope for v1: image attachments, slash-command menus,
rich-text formatting, per-message edit/regenerate buttons,
multi-conversation tabs. Single conversation, append-only,
voice-equivalent semantics.

## Architecture

### Modify: `leanring-buddy/PaceConversationsView.swift`

Today this is a searchable read-only list of `paceHistory` docs.
Restructure into a chat surface:

- Top: scrollable conversation transcript — newest at the
  BOTTOM (chat convention). Each row shows role (user / pace),
  timestamp, body text. Existing search field stays but applies
  in-line filtering.
- Bottom: a sticky text input field, full-width, with a "Send"
  button. Enter submits; Shift+Enter inserts a newline.
- Header right: a small speaker icon toggling
  `isChatTTSMuted` (default false — Pace still speaks).
- Streaming: when a reply is in flight, render a partial row at
  the bottom with the streaming sentence as it accrues
  (`StreamingSentenceTTSPipeline` already exposes the streamed
  text — wire its publisher into the view).

Use `@ObservedObject companionManager` for state. Use
`ScrollViewReader` to auto-scroll to the bottom on new messages.

### New file: `leanring-buddy/PaceChatSession.swift` (~150 lines)

`@MainActor` class that backs the conversations tab with an
ordered list of messages for display. Wraps the existing
`paceHistory` retrieval as the persistence layer (no separate
storage — keeps everything aligned with what voice writes).

```swift
struct PaceChatMessage: Identifiable, Equatable {
    let id: String
    let role: PaceChatRole  // .user, .pace
    let body: String
    let createdAt: Date
}

enum PaceChatRole: String { case user, pace }

@MainActor
final class PaceChatSession: ObservableObject {
    @Published private(set) var messages: [PaceChatMessage] = []
    @Published private(set) var streamingPaceReply: String?
    @Published var isChatTTSMuted: Bool = false

    init(retriever: PaceRetriever, companionManager: CompanionManager)

    func loadHistory()  // pulls last N paceHistory docs, oldest-first
    func submitUserMessage(_ text: String) async
}
```

`submitUserMessage` calls `companionManager.submitChatTranscriptFromDeepLink(_:)`
(the existing function) under the hood. Mute toggle, when on,
calls `ttsClient.stopPlayback()` and sets a transient session
flag the manager checks before speaking.

### Modify: `leanring-buddy/CompanionManager.swift`

- New `@Published var chatSession: PaceChatSession` lazy property.
- New private `isChatModeMutedForCurrentTurn: Bool` flag — read at
  TTS dispatch; when true, the streaming pipeline drops audio
  but still streams text. Reset at turn start.
- When `submitChatTranscriptFromDeepLink` runs and the request
  came from `PaceChatSession`, set
  `isChatModeMutedForCurrentTurn = chatSession.isChatTTSMuted`.
- After a turn completes, append both user + assistant messages
  to `chatSession.messages` from the same `paceHistory` records
  the manager already writes.

### Modify: `leanring-buddy/PaceMainWindow.swift` / `PaceMainView.swift`

The Conversations tab now shows the live chat surface. No
sidebar changes needed — the tab label already says
"Conversations". Add a footer hint: "you can also press
ctrl+option anywhere to talk."

### Streaming wire-up

`StreamingSentenceTTSPipeline` already buffers planner output
as it arrives. Add a small publisher on it:

```swift
@Published private(set) var inFlightStreamedText: String = ""
```

The pipeline accumulates each chunk it receives into this
property and clears it on `markIntentCommitted()` /
sentence-completion. `PaceChatSession` observes this and feeds
it to `streamingPaceReply` for the UI to render.

If touching the streaming pipeline introduces concurrency
warnings, the alternative is: `CompanionManager` writes streamed
chunks directly to `chatSession.streamingPaceReply` from the
existing chunk-handler closure. Pick whichever is cleaner in
the existing code.

## Acceptance criteria

- [ ] All existing tests still pass.
- [ ] New `PaceChatSessionTests` cover: loadHistory roundtrips
      from a fake retriever, submitUserMessage appends a user
      row and triggers the manager call, mute toggle persists
      within the session.
- [ ] Manual: open PaceMainWindow → Conversations → type
      "what's the time" → Enter → user message renders, assistant
      reply streams in below, TTS plays (or doesn't if muted).
- [ ] Manual: in a separate session, ask Pace via voice → that
      turn appears in the chat history when the window is
      opened next (verifies the shared `paceHistory` backing).
- [ ] Mute toggle persists for the session but resets to default
      on app restart (not a persistent preference — chat-level
      ephemera).

## Implementation order

1. `PaceChatSession.swift` + tests against a fake retriever.
2. `CompanionManager` wiring (lazy property, mute flag,
   submitChatTranscript hook).
3. `PaceConversationsView` restructure (transcript + input).
4. Streaming wire-up (whichever path is cleaner).
5. Footer hint text.
6. AGENTS.md: Key Files row for `PaceChatSession.swift`;
   update the description of `PaceConversationsView.swift`.
7. Tests green via `bash scripts/test-pace.sh`. Commit.
   **Don't release.**

## What NOT to do

- Don't add a new persistence layer for chat — reuse
  `paceHistory` retrieval. Single source of truth.
- Don't add chat to the notch panel — it stays voice-first.
- Don't break the existing search field in
  `PaceConversationsView`; restructure around it.
- Don't introduce slash commands, image upload, or rich text in
  v1.

Where in code: `leanring-buddy/PaceChatSession.swift` (session model + mute flag),
`leanring-buddy/PaceConversationsView.swift` (chat surface with sticky input),
`leanring-buddy/StreamingSentenceTTSPipeline.swift` (`inFlightStreamedText`
publisher), `submitChatTranscriptFromChatSession` in CompanionManager.
