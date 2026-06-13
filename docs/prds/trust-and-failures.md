---
Status: shipped (v0.3.11)
owner: future Pace-repo agent
priority: P0 — turns Pace from "feels scary" to "feels reliable"
---

# PRD — Trust & Failures (visible undo + reply replay + plain-language failure surface)

## Goal

A user has to trust Pace to actually use it daily. Today three failure modes erode that trust:

1. Pace performs a wrong action → user has no fast undo and panics.
2. Pace finishes speaking → user missed it → no replay.
3. Pace fails silently (LM Studio offline, permission missing, click missed) → user thinks Pace is broken without knowing why.

This PRD ships three coupled UX surfaces that fix all three. None of them is architecturally novel — every backing capability exists. The work is wiring + visibility.

## Three changes, one PRD

### Change 1 — Visible undo banner after every reversible action

When `PaceActionExecutor` posts a reversible action (`AX.setValue`, `Mail.draft`, `Notes.create/append`, `Reminders.add`, `Calendar.createEvent`, `Things.create`, anything in `PaceActionMutation`'s log), a floating **"undo that"** button appears next to the cursor for 5 seconds. Tapping it invokes the existing `Undo.last` action.

Implementation: `PaceActionMutation` log already exists. Add a published flag `mostRecentReversibleActionAt: Date?` on `CompanionManager`. The cursor overlay observes it; when set within the last 5 seconds, render a small button anchored just below the cursor's resting position. The button label says "undo: <action summary>" (e.g. "undo: Created note 'Idea'"). Tapping it submits an `Undo.last` action through the executor.

Irreversible actions (click, type, scroll, open_app, open_url) do NOT get the banner — undo doesn't exist for them. Only the mutation-logged set.

### Change 2 — Spoken-reply replay button (30 sec)

After every assistant turn finishes speaking, the notch panel shows a **"replay"** button for 30 seconds. Tapping it speaks the most recent assistant turn through TTS again — verbatim.

Implementation: `CompanionManager.conversationHistory` already holds the last turns. Add a published `lastSpokenReplyText: String?` + `lastSpokenReplyAt: Date?`. Notch panel renders a small button when the timestamp is within 30 seconds. Tapping calls `ttsClient.speakText(lastSpokenReplyText)`.

For the spoken-reply text, use the SAME text that went through TTS (with `<think>` blocks stripped, action tags stripped — i.e. the post-processed string). Don't re-stream the planner.

Auto-hides at 30 sec OR when the next turn begins.

### Change 3 — Plain-language failure narration

Today's failure modes are silent or cryptic. Concretely fix the worst offenders:

- **Planner offline** (LM Studio unreachable when tier is `.local`, or Apple FM unavailable when tier is `.appleFoundationModels`, or bridge/Direct API errors) → Pace SPEAKS: "I can't reach the local planner right now — open Settings and switch to a different tier?" instead of silence. Today the planner factory throws; the manager logs but doesn't speak.
- **Missing permission for a requested action** — already partly handled by `PaceToolPreflight`, but the preflight result is currently shown only in the approval popup. If actions auto-execute (no approval needed) and a tool needs permission Pace doesn't have, Pace SPEAKS: "I'd need Reminders access for that — want me to open Settings?" then waits.
- **Click missed** — `PaceActionExecutor` already has all-fail click observations. When the click candidates exhaust without success, Pace SPEAKS: "I couldn't find a save button on this screen — want to point it out?" Today this surfaces as a console log only.
- **Sidecar TTS offline** — Pace already falls back to Apple TTS silently after a 30-second memo. Mention it on the first fallback turn: "Switched to the system voice — the Kokoro sidecar isn't reachable. Run `scripts/start-tts-server.sh` to get it back."

Each failure case maps to a new helper on `CompanionManager`: `speakPlainLanguageFailure(_ kind: PaceFailureKind, context: String?)`. The kind is an enum with the documented failure shapes. The helper:

1. Constructs a deterministic spoken string (no LLM call — templated like the morning brief builder).
2. Speaks through `ttsClient.speakText`.
3. Writes a `paceHistory` record for retrieval ("Pace told the user about a planner outage at 14:30").
4. Optionally surfaces a tappable Settings deep-link in the notch panel when relevant.

The full kinds list for v1: `plannerOffline`, `missingPermission(permission:)`, `clickMissed(targetLabel:)`, `sidecarTTSOffline`, `mcpServerNotConfigured(name:)`, `cloudBridgeUpstreamError(provider:)`.

## Scope (out for v1)

- A "diagnostic mode" that runs `diag-pace.py` on demand. Tempting but out of scope — Settings already exposes status surfaces; we don't need a one-click diagnostic until we have remote support.
- Undo across many steps. v1 undo is single-step (the existing `Undo.last`). Multi-step is its own PRD.
- Replay across sessions ("what did Pace say to me an hour ago?") — `paceHistory` retrieval already covers that via the chat surface and voice ("what did you tell me earlier"). Replay is for the immediate-just-spoke case.

## Architecture

### Modify: `leanring-buddy/CompanionManager.swift`

- Add `@Published var mostRecentReversibleActionAt: Date?` and `@Published var mostRecentReversibleActionSummary: String?`. Set them in the post-action handler when the parsed action is in the reversible set (the same set already documented in `PaceActionApproval.canRelyOnVisualOrObservationFeedback`).
- Add `@Published var lastSpokenReplyText: String?` and `@Published var lastSpokenReplyAt: Date?`. Set them at the same site where post-TTS bookkeeping currently runs.
- Add `func replayLastSpokenReply() async`.
- Add `enum PaceFailureKind` + `func speakPlainLanguageFailure(_:context:)`.
- Wire `speakPlainLanguageFailure` at the call sites for each kind:
  - Planner factory error in the agent loop (today silently retries).
  - `PaceToolPreflight` blocking issues when actions auto-execute.
  - `PaceClickAllFailObservation` site in the executor.
  - LocalServerTTS sidecar outage memo first-fire (today silent fall-through).

### Modify: `leanring-buddy/OverlayWindow.swift` (or wherever the cursor overlay renders)

- Subscribe to `companionManager.mostRecentReversibleActionAt`. When within 5 seconds, render a `PaceUndoBanner` view anchored below the cursor.
- The banner renders the summary + an "undo" button. Tapping submits an `Undo.last` action via the executor.
- Fade out at 5 seconds with the standard `DS.Animation` easings; respect Reduce Motion.

### Modify: `leanring-buddy/CompanionPanelView.swift`

- Below the turn HUD, render a replay button when `companionManager.lastSpokenReplyAt` is within 30 seconds. Tapping calls `companionManager.replayLastSpokenReply()`.

### Modify: `leanring-buddy/PaceToolPreflight.swift`

- Today `evaluate` returns issues but doesn't tell the manager which auto-execute path got blocked. Add a small helper `firstBlockingIssueKind(in:) -> PaceToolPreflightBlockingKind?` so the manager can map preflight blocks onto `PaceFailureKind` cases.

### New file: `leanring-buddy/PaceFailureNarrator.swift` (~150 lines)

Pure module: takes a `PaceFailureKind` and returns the deterministic spoken string + optional Settings deep-link target. Mirror the shape of `PaceMorningBriefBuilder` — pure, table-driven, testable.

### Modify: `AGENTS.md`

- Add Key Files row for `PaceFailureNarrator.swift`.
- Update the action layer / approval architecture section to mention the visible undo banner and the failure narration surface.

## Acceptance criteria

- [ ] All existing tests pass + new tests cover: failure narrator strings for every kind, undo banner visibility window, replay availability window, reversible-vs-irreversible action set.
- [ ] After running a `Mail.draft`, the undo banner appears next to the cursor for 5 seconds. Tapping it invokes `Undo.last`.
- [ ] After running a `click` (irreversible), no undo banner appears.
- [ ] After every spoken reply, the notch panel shows the replay button for 30 seconds. Tapping it speaks the same text again.
- [ ] When the local planner is offline AND the user PTTs, Pace speaks the plain-language failure (no silent retry).
- [ ] When a click-candidate set exhausts without a successful match, Pace speaks the click-missed message.
- [ ] When TTS sidecar falls back to Apple voice for the first time, Pace mentions it on the next turn.
- [ ] `bash scripts/test-pace.sh` ends green (modulo the pre-existing cloud-bridge consent flake).

## Testing strategy

- `PaceFailureNarratorTests` — table-driven; every kind produces a non-empty spoken string + the right deep-link.
- `CompanionManagerTrustTests` — focused tests over the manager with stubbed executor + TTS:
  - reversible action sets the undo banner flag; irreversible doesn't.
  - spoken reply sets the replay flag for 30 seconds.
  - planner offline event fires the failure narrator path.
- Manual smoke: trigger a click that has no candidates, confirm narration.

## Risks

- **The undo banner steals focus visually mid-action.** Mitigation: it lives in the existing cursor overlay (non-activating panel), styled muted to avoid the cursor's primary visual.
- **The replay button keeps showing while the user is mid-next-turn.** Auto-hide on next turn start.
- **Failure narrator becomes noisy.** Mitigation: only the documented kinds. Don't expand the kinds list casually.
- **Two failures in 30 seconds → both speak.** Acceptable for v1 — failures should be loud.

## Implementation order

1. `PaceFailureNarrator.swift` + tests (pure, smallest blast radius).
2. `PaceFailureKind` + `speakPlainLanguageFailure` on `CompanionManager`.
3. Wire `speakPlainLanguageFailure` at the four call sites (planner offline, preflight block, click all-fail, sidecar fallback).
4. Reversible-action tracking + `PaceUndoBanner` view in the cursor overlay.
5. Replay button in the notch panel.
6. AGENTS.md update.
7. `bash scripts/test-pace.sh` green. Commit. Do NOT release.

## What NOT to do

- Don't add an LLM call to compose failure text — strictly templated.
- Don't replay through a different voice or different volume — same as the original turn.
- Don't make the undo banner appear for non-mutation actions; the user shouldn't see undo offered for an unrecoverable click.
- Don't speak failures during a Zoom/active-call (the restraint policy already gates this — make sure failure narration also flows through the gate).

Where in code: `leanring-buddy/PaceFailureNarrator.swift` (typed `PaceFailureKind` →
spoken text + suggestion), `PaceUndoBanner` view inline in
`leanring-buddy/OverlayWindow.swift` (driven by `mostRecentReversibleActionAt`),
reply-replay button in `leanring-buddy/CompanionPanelView.swift`.
Failure speech routes through `PaceRestraintGate.decide(...)`.
