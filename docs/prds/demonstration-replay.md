---
Status: shipped (v0.3.12)
owner: future Pace-repo agent
priority: P2 — high-value but largest surface
---

# PRD — Demonstration Replay ("show me, then do it")

## Goal

Let the user demonstrate a flow ("watch this") and have Pace record
the actions in a replayable form, then run the same flow on command
("do my morning standup setup"). Today Pace can EXECUTE flows the
planner emits — but it cannot record + replay flows the user shows it.

## Why now

This is one of the few capabilities that crosses the threshold from
"voice assistant" to "personal automation." Apple Shortcuts solves
~40% of this for app-supported flows; Pace's MCP layer covers
another ~30%. Demonstration captures the remaining "no API exists,
just clicks" cases.

## Scope (v1)

1. **Voice command "remember this flow as <name>"** starts a
   recording session.
2. Recorder captures: mouse-down events resolved to AX-tree elements
   (label + role + AX path), typed text runs (collapsed by keyboard
   focus), key shortcuts, app activations. Coordinates NOT stored —
   AX targets only.
3. **"stop recording"** ends the session. Flow saved to disk under
   Application Support.
4. **"do <name>"** voice command runs the saved flow through
   `PaceActionExecutor`.
5. Settings → Flows lists saved flows with edit/delete/rename.

Out of scope for v1: branching flows, parameterized flows, image-based
fallback when AX target missing, recording across multiple windows
simultaneously.

## Hard non-goals

- **No coordinate-based recording.** AX-only. Coordinates rot the
  moment the window moves.
- **No password capture.** Secure-input fields (`kAXSecureTextField`)
  are detected and the keystrokes inside them are recorded as
  `<password redacted>` markers that require the user to provide the
  value at replay time.
- **No screen recording.** Pace already has Screen Recording
  permission for VLM/OCR, but the recorder doesn't write pixels —
  only AX paths and key/text events.

## Architecture

### New file: `PaceFlowRecorder.swift` (~400 lines)

- Owns a `CGEventTap` in listen-only mode (same flavor as
  `GlobalPushToTalkShortcutMonitor`). Filter: `mouseDown`, `keyDown`,
  `flagsChanged`.
- On `mouseDown`: call `AXUIElementCopyElementAtPosition`, climb to
  pressable role, record `PaceRecordedStep.axPress(rolePath:)`.
- On `keyDown`: append to a typing buffer for the current focused AX
  text element. When focus changes, flush buffer as
  `PaceRecordedStep.typeText`. Detect shortcuts (cmd+, ctrl+, etc.)
  and emit `PaceRecordedStep.keyShortcut`.
- On `NSWorkspace.didActivateApplicationNotification`: emit
  `PaceRecordedStep.activateApp(bundleIdentifier:)`.
- Stops on voice command, explicit hotkey, or 60-sec idle.

### New file: `PaceFlowStore.swift` (~200 lines)

- Per-flow JSON file at `Application Support/Pace/flows/<slug>.json`.
- Schema:
  ```json
  {
    "name": "morning standup setup",
    "createdAt": "...",
    "steps": [
      {"kind": "activateApp", "bundleIdentifier": "..."},
      {"kind": "axPress", "rolePath": [...], "label": "Send"},
      {"kind": "typeText", "text": "...", "secure": false},
      {"kind": "keyShortcut", "key": "cmd+t"}
    ],
    "secureFieldDefaults": {"path/to/field": "<keychain item ref>"}
  }
  ```
- API: `save(_:)`, `load(named:)`, `delete(named:)`, `listAll()`.

### New file: `PaceFlowReplayer.swift` (~250 lines)

- Reads a `PaceFlowStore.Flow` and executes each step through
  `PaceActionExecutor` (extend with `executeRecordedStep(_:)` —
  thin shim around existing AX press / type / key paths).
- Between steps: small adaptive delay (start at 250 ms, slow down if
  AX target not yet present, give up after 5 sec).
- On missing AX target: speak "i can't find the <label> button at
  step <N>" and stop.

### Modify: `PaceToolRegistry.swift`

Add tools `record_flow` (alias: `record this`) and `run_flow` (alias:
`do that`, `run flow`). Both gated behind a new `EnableFlowReplay`
Info.plist flag, default true.

### Modify: `PaceActionExecutor.swift`

- Two new action cases: `recordFlowStart(name:)`,
  `runFlow(name:)`. Recorder/replayer hold weak references back to
  the executor.
- New `PaceFlowDefinition` parsing in the local-tool switch.

### Modify: `PaceSettingsWindow.swift`

- New "Flows" tab: list saved flows, rename, delete, "play once"
  test button.

## Voice grammar

- "remember this flow as <name>" / "remember this as <name>" /
  "save this as a flow called <name>"
- "stop recording" / "i'm done"
- "do <name>" / "run <name>" / "play back <name>"
- "delete the flow <name>" / "forget the flow <name>"

Routed through a new `PaceFlowCommandParser` (mirror
`PaceWatchModeCommandParser`).

## Acceptance criteria

- [ ] Record a 5-step flow in Mail (compose → To: field → subject →
      body → send). Replay recreates the draft (without sending — see
      Send restriction below).
- [ ] Replay fails gracefully when the target window state changes
      enough that AX paths break — spoken message names the step.
- [ ] Secure fields are redacted in the saved flow.
- [ ] Settings → Flows lists, renames, deletes. Persists across
      restart.
- [ ] Approval-gated: every `run_flow` requires user approval the
      first time per session for that flow (cached for the session).
      Future-runs config in Settings.

## Send restriction (v1)

The very last step of a recorded flow that contains a Send-like
button (`Send`, `Submit`, `Post`, `Reply`) is **not** auto-executed
on replay. Pace says "ready to send — say go ahead" and waits. This
prevents accidental email/message dispatch from a misremembered flow.

## Privacy posture

- Flows live only in `Application Support/Pace/flows/`.
- Secure-input redaction is enforced at recording time, not replay
  time — the password never enters the on-disk file.
- No flow data is ever sent off-device.
- Settings → Flows shows full recorded steps; user can audit before
  trusting.

## Testing strategy

- `PaceFlowStoreTests` — save/load roundtrip, deletion, listing.
- `PaceFlowRecorderTests` — feed synthetic CGEvent sequences (no real
  event tap), assert step list.
- `PaceFlowReplayerTests` — fake `PaceActionExecutor` records
  invocations; assert step sequence + adaptive delay behavior.
- Manual: record a real Mail compose, replay it. Document in PR.

## Risks

- **AX path brittleness.** Apps that rebuild their AX trees on
  state change (Electron apps especially) will break replays.
  Mitigation: V1 documents this. V2 explores label-only matching
  (climb the tree by label, ignore index siblings).
- **Send-button auto-trigger.** The Send-restriction is the
  mitigation, but it's keyword-based. False negatives possible.
- **Recording during a private moment** — the user accidentally
  records a password / sensitive email. Mitigation: redaction,
  Settings audit, delete-flow command.
- **Cross-app flows** with timing dependencies (waiting for a
  popup) — the adaptive delay covers most, but not all.

## Effort estimate

~1500 lines + multiple test files. 1 week of focused work. Largest
surface in the PRD set.

## Open questions

- Should "record this" be a top-level voice command or scoped to a
  Settings menu? Voice command is the Her-ish choice; menu is
  safer.
- Replay timing: real-time pacing (record the durations) or
  fastest-possible? V1 = fastest-possible with AX-waits. V2 might
  add "slow mode" for visual review.

Where in code: `leanring-buddy/PaceFlowRecorder.swift` (CGEventTap recorder),
`leanring-buddy/PaceFlowStore.swift` (per-flow JSON persistence),
`leanring-buddy/PaceFlowReplayer.swift` (replay engine with adaptive AX waits),
`leanring-buddy/PaceFlowReplay.swift` (voice-command parser + planner helper).
Settings → Flows tab lives in `leanring-buddy/PaceSettingsWindow.swift`.
