---
Status: shipped (v0.3.12)
owner: future Pace-repo agent
priority: P0 — headline UX shift for the "Her" arc
---

# PRD — Always-Listening Mode (toggleable)

## Goal

Let Pace listen ambiently so the user doesn't have to hold ctrl+option to start
every turn. Ship a toggle (Settings + voice command) so the user owns when Pace
is "on" vs "off." When always-listening is on, Pace decides per moment whether
to act on what it heard. PTT remains the default and the safety floor — never
removed.

## Why now

PTT works but breaks the "ambient companion" feel. The single biggest gap
between Pace and the Her-style north star is the keypress. Once this lands,
all the other proactive features (nudges, episodic memory recall, watch-mode
narration) have a natural way to surface — Pace can simply talk.

## Scope (v1)

Three layers, in order of preference:

1. **Wake-word — "Hey Pace" / "Pace"** — primary trigger. Always-on
   low-power keyword spotter. When the keyword fires, open a 6-second
   listening window with a visible indicator (notch overlay pulse), then
   run the normal transcribe → intent → planner pipeline.

2. **Continuous transcription gated by intent classifier** — secondary.
   When the user opts in (a deeper toggle, off by default), Pace
   transcribes continuously through Apple Speech (still on-device), runs
   each finalized utterance through `PaceFMIntentClassifier`. Only
   `screenAction` / `phoneLargeModel` / `screenDescribe` / `pureKnowledge`
   intents reach the planner. Chitchat / ambient noise is silently
   dropped.

3. **PTT preserved.** Always works. When always-listening is on, PTT
   still exists as the "I want full attention" gesture — bypasses the
   restraint policy.

Out of scope for v1: speaker identification, multi-user, room-context
acoustic analysis, multi-device handoff.

## Architecture

### New file: `PaceWakeWordSpotter.swift` (~250 lines)

- Wraps an on-device keyword detector. Two candidate runtimes:
  - **Apple Speech in always-on mode** — `SFSpeechRecognizer` with a 5-sec
    rolling buffer + a tight regex on the partial. Free, zero new
    dependencies, mediocre accuracy.
  - **openWakeWord (Python)** ported to CoreML via Swift bridge — better
    accuracy, ~10 MB model bundle. Preferred.
- Lifecycle managed alongside `PacePushToTalkManager` — both consume the
  same `AVAudioEngine` tap.
- Emits a Combine publisher `wakeWordDetected: PassthroughSubject<Void, Never>`.

### Modify: `PacePushToTalkManager.swift`

- Add `func openListeningWindow(durationInSeconds:)` — non-PTT path
  that mimics a key-down/key-up after `durationInSeconds`. Existing
  state machine handles the rest.

### Modify: `CompanionManager.swift`

- Subscribe to `wakeWordDetected` → call
  `pushToTalkManager.openListeningWindow(durationInSeconds: 6)`.
- New `@Published var isAlwaysListeningEnabled: Bool` — persisted in
  `PaceUserPreferencesStore`.
- Wire on/off voice commands ("pace listen always", "pace stop
  listening always") through a small parser (mirror
  `PaceWatchModeCommandParser`).
- Plumb the toggle into `PaceWakeWordSpotter` so it stops the audio
  tap when disabled — battery cost matters.

### Modify: `PaceMenuBarOverlay.swift`

- Subtle pulse animation when the wake-word spotter is armed (passive
  state). Distinct from PTT-active state.

### Modify: `PaceSettingsWindow.swift`

- New "Listening" section: always-listening toggle, wake-word phrase
  picker (Pace / Hey Pace), passive-pulse opt-out.

### New file: `Resources/wake-words/<phrase>.onnx` (or `.mlmodel`)

- If using openWakeWord: bundled CoreML/ONNX model. Two phrases shipped:
  "pace" and "hey pace". Both trained with low-false-positive bias.

## Privacy + battery posture

- Wake-word spotter consumes ~1-3% CPU continuously. Pace must surface
  this honestly in Settings ("Always-listening uses ~2% battery").
- Continuous-transcription mode (layer 2) is **off by default** — only
  on when user explicitly opts in, double-confirmed dialog.
- Audio buffer ring is 5 sec max. Never written to disk, never sent
  off-device (no exceptions). The audit log records turn-ids only, not
  audio.
- Wake-word activations are journaled into `paceHistory` retrieval the
  same way PTT activations are — so the user can review.

## Restraint integration

When always-listening is on, the [restraint-policy](restraint-policy.md)
gate decides whether to respond, stay quiet, or queue.

## Acceptance criteria

- [ ] "Hey Pace" trigger within 1.5s of speech onset (warm), with
      ≤2 false positives per hour of typical speech (measured against a
      30-min ambient-conversation fixture).
- [ ] Toggle on/off via Settings AND voice — both routes verified.
- [ ] Battery: continuous ≥3-hour battery test shows ≤5% degradation vs
      idle baseline.
- [ ] PTT unaffected. PTT bypasses restraint policy.
- [ ] Wake-word audio buffer never persisted (verified by code-review +
      test that grep-checks the audit log for audio bytes).
- [ ] Settings toggle persists across restart.

## Testing strategy

- `PaceWakeWordSpotterTests` — feed fixture audio (with/without the
  phrase), assert spotter fires only on positive samples.
- `PaceAlwaysListeningTogglePersistenceTests` — flip toggle, restart
  CompanionManager, assert state restored.
- Integration: simulate wake-word fire → assert
  `pushToTalkManager.openListeningWindow` called.

## Risks

- **False positives spoken to the user as a re-prompt** — restraint
  policy MUST block "did you say something?" auto-replies on weak
  triggers. Without that policy, this feature becomes spam.
- **Wake-word battery cost on Intel Macs** — Apple-Silicon-only as a
  v1 constraint; Intel users keep PTT.
- **Model licensing** — openWakeWord is Apache-2.0, safe. Apple Speech
  always-on mode may hit undocumented duration caps.

## Open questions

- Should "Hey Pace" require a voice-print match (speaker ID) before
  v2? Decision blocked on whether multi-user households are a target.
- Auto-disable when on a Zoom/Meet call (frontmost is video-conf app)?
  Likely yes — but should it stay disabled or just stay quiet?

## Effort estimate

~400 lines + a model bundle. 2-3 days of focused work assuming
openWakeWord port and audio-tap multiplexing both go cleanly.

Where in code: `leanring-buddy/PaceAppleSpeechWakeWordSpotter.swift` is the active
spotter (Apple Speech on-device, ANE). `leanring-buddy/PaceWakeWordSpotter.swift`
is the protocol/factory surface. Wake-word firing routes through the existing
`PacePushToTalkManager.openListeningWindow(durationInSeconds:)` path. The
openWakeWord CoreML bundle is parked — Apple Speech satisfies v1.
