---
Status: shipped (v0.3.12)
owner: future Pace-repo agent
priority: P2 — natural conversation polish
---

# PRD — Barge-In (interrupt Pace mid-sentence by speaking)

## Goal

The user should be able to interrupt Pace while it's speaking — by
just talking. Pace stops, listens, and responds to the new utterance.
Today the user has to wait for TTS to finish or press PTT to abort.

## Why now

Once [always-listening](always-listening-mode.md) ships, conversational
turn-taking matters more. Without barge-in, a 4-sentence reply feels
rude — the user can't dispatch it midway.

## Scope (v1)

When TTS is playing AND always-listening is on:

1. A lightweight VAD (voice activity detector) runs on the existing
   audio tap.
2. When sustained user speech (≥600 ms above threshold) is detected,
   Pace stops TTS immediately and opens a listening window — same
   path as wake-word.
3. The interrupted utterance is logged as `interrupted-mid-speech`
   in `paceHistory` retrieval so the planner knows the user heard
   only part of the answer.

Out of scope for v1: speaker identification (anyone in the room can
barge in), partial-utterance retention ("you said X but I want to
know Y" without re-stating context).

## Architecture

### New file: `PaceBargeInVAD.swift` (~200 lines)

- WebRTC VAD or Apple's `AVAudioEngine`-tap RMS + spectral
  thresholding.
- Subscribes to the same audio tap as the wake-word spotter and PTT
  recorder. Idle when TTS isn't playing.
- Emits a Combine signal on sustained-speech detection.

### Modify: `LocalServerTTSClient.swift`, `LocalTTSClient.swift`

- Both already have `stopPlayback()`. The barge-in handler calls it
  immediately on VAD trigger.
- Add a `wasInterrupted: Bool` flag on the playing utterance for
  audit logging.

### Modify: `CompanionManager.swift`

- Subscribe to `PaceBargeInVAD.didDetectInterruptiveSpeech` only when
  `voiceState == .responding`.
- On detection: `ttsClient.stopPlayback()` →
  `pushToTalkManager.openListeningWindow(durationInSeconds: 6)`.

### Modify: `StreamingSentenceTTSPipeline.swift`

- Drain queue immediately on stopPlayback. Don't speak buffered
  sentences after barge-in.

## Restraint integration

Even with barge-in fully wired, the [restraint
policy](restraint-policy.md) gate decides whether the new utterance
deserves a response — silence is still an option.

## Acceptance criteria

- [ ] User speaks during TTS → TTS halts within 200 ms of speech onset.
- [ ] Barge-in only fires when always-listening is on (off-mode TTS
      plays to completion).
- [ ] False positives from background noise: ≤1 per hour against a
      30-min cafe-noise fixture.
- [ ] PTT press during TTS still works (separate code path; tested
      not regressed).
- [ ] Interrupted utterance logs as `interrupted` in audit.

## Testing strategy

- `PaceBargeInVADTests` — feed fixture audio buffers (speech vs
  babble vs music), assert detection.
- Integration: drive a fake TTS playback timer + a fake speech
  arrival, assert `stopPlayback()` called.

## Risks

- **Pace's own voice triggering its own VAD.** The audio tap is on
  the input device (mic); TTS plays through output. Echo cancellation
  on internal Mac speakers should isolate them — but external
  speakers may bleed. Mitigation: configurable threshold + a
  conservative default.
- **Music playback triggering barge-in.** VAD must reject music; use
  a speech-vs-music classifier (cheap MFCC + simple threshold) or
  reject when audio comes from system output (route check).
- **Interrupting mid-stream-tool-execution.** TTS stop is fine —
  but if an action is queued to fire after TTS finishes (e.g.
  Mail.draft body streaming), barge-in must coordinate. Solve by:
  any in-flight action plan keeps running; only TTS stops.

## Effort estimate

~300 lines + tests. 1-2 days. Depends on always-listening landing
first.

Where in code: `leanring-buddy/PaceBargeInVAD.swift` (VAD gate);
audio-level publisher wiring lives in
`leanring-buddy/PacePushToTalkManager.swift` (`audioLevelPublisher`),
which the VAD subscribes to when TTS is playing.
