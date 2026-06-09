# WhisperKit streaming ASR

Status: partial (2026-06-09). The selectable provider scaffold, Apple Speech
fallback path, contextual phrase handoff, visible ASR status, and a tested
provider-agnostic LocalAgreement stabilizer are wired. The push-to-talk
pipeline now feeds provider partial hypotheses through LocalAgreement and
publishes stable partials before final transcript submission. The real
WhisperKit streaming runtime bridge remains queued.

## Goal

Provide low-latency, local-only speech recognition with:

- Streaming partial transcripts.
- LocalAgreement-style stabilization.
- Contextual vocabulary biasing from the current app, repo, contacts, and
  recent Pace commands.
- Code-mode and product-name accuracy better than Apple Speech.
- First stable partial in 100 ms or less on supported Macs.

## Current State

Pace uses `SFSpeechRecognizer` through `AppleSpeechTranscriptionProvider` with
`requiresOnDeviceRecognition=true`. It is instant to install and keeps data
local, but it is weak on code symbols, app-specific vocabulary, and controlled
partial stability.

`BuddyTranscriptionProvider` already gives Pace a provider seam. This PRD uses
that seam; it does not rewrite the push-to-talk pipeline.

Implementation note, 2026-06-09: `TranscriptionProvider` in Info.plist selects
`appleSpeech` by default. `whisperKit` is accepted by the factory and falls
back to Apple Speech with an explicit provider label until the streaming
runtime is available. The panel/settings now show the active ASR provider and
model readiness. `WhisperKitTranscriptionProvider` exists as the sibling type,
but intentionally fails fast if directly used before the runtime bridge lands.
`PaceLocalAgreementStabilizer` now provides a pure tested stabilizer for
successive partial hypotheses. `PacePushToTalkManager` feeds provider partial
hypotheses through it and updates visible draft text with the stable prefix
before final transcript submission. The real WhisperKit bridge can reuse the
same path once partial hypotheses are available.

## Scope

In scope:

- Add `WhisperKitTranscriptionProvider` as a sibling to
  `AppleSpeechTranscriptionProvider`.
- Stream partial transcripts into the existing push-to-talk state machine.
- Bias initial prompts with local key terms.
- Keep Apple Speech fallback if WhisperKit model load fails.
- Add visible status for active ASR provider and model readiness.

Out of scope:

- Cloud STT.
- Multilingual support.
- Full custom ASR training.
- Replacing TTS or planner components.
- Dictation post-processing model work, covered by
  `dictation-postproc-and-voice-edit.md`.

## User Experience

The user holds the same push-to-talk shortcut. Pace begins listening immediately
even if WhisperKit is still warming. Once a stable partial is available, the
planner fast path can begin speculative work. If WhisperKit is unavailable,
Pace silently falls back to Apple Speech and shows the fallback in settings.

No user should need to manually start a model server.

## Architecture

`BuddyTranscriptionProvider` remains the public abstraction.

```swift
protocol BuddyTranscriptionProvider {
    func prepare() async throws
    func startStreaming(contextualPhrases: [String]) async throws
    func acceptAudioBuffer(...)
    func finish() async throws -> String
}
```

`WhisperKitTranscriptionProvider` owns:

- Model load and warmup.
- Audio format conversion from the existing mic pipeline.
- Partial transcript callbacks.
- Stable segment tracking.
- Final transcript cleanup.

Apple Speech remains:

- Fallback when WhisperKit cannot load.
- Fallback for unsupported hardware or model corruption.
- A debug comparison path during rollout.

## Contextual Biasing

Build a small prompt vocabulary per turn:

- Frontmost app name and menu titles.
- Active repo file names when the frontmost app is Cursor, Xcode, Terminal, or
  another coding tool.
- Contacts names for compose actions.
- Recent Pace local-memory preferences.
- Common command names from `PaceToolRegistry`.

Cap the prompt to keep prefill cheap. Prefer exact rare tokens over generic
words.

## Latency Targets

| Milestone | Target |
|---|---|
| Provider prepare after app launch | Background; no blocking first UI. |
| First partial after speech starts | <= 100 ms on supported hardware. |
| Stable phrase after user pauses | <= 150 ms. |
| Final transcript after push-to-talk release | <= 150 ms. |
| Fallback activation | <= 50 ms after WhisperKit failure detected. |

## Safety And Privacy

- Audio never leaves the Mac.
- No telemetry payload includes audio or transcript text.
- Debug logs may include timing and provider name only.
- Model files are local app assets or user-approved local downloads.

## Tests

Unit tests:

- Provider factory chooses WhisperKit when enabled and available.
- Provider factory falls back to Apple Speech on load failure.
- Contextual phrase builder includes app/repo/contact terms and respects caps.
- Partial stabilization emits monotonic stable prefixes. Implemented as a pure
  provider-agnostic utility and wired into `PacePushToTalkManager` for current
  provider partials; real WhisperKit runtime integration remains queued.

Manual tests:

- General command: "click save".
- Code command: "open PaceActionExecutor".
- Email command: "draft mail to Priya about the eval matrix".
- Noisy correction: "actually make that shorter".

## Done When

- WhisperKit can be selected through configuration without removing Apple
  Speech.
- Push-to-talk works with streaming partials and final transcripts. Partial:
  current provider partials are stabilized and surfaced before final transcript
  submission; the real WhisperKit provider bridge remains queued. Apple Speech
  remains the active production provider.
- Contextual biasing demonstrably improves at least five repo/product terms.
- Existing parser, intent, and action tests still pass.
- No cloud STT dependency exists in code or setup docs.

## References

- `leanring-buddy/BuddyTranscriptionProvider.swift`
- `leanring-buddy/AppleSpeechTranscriptionProvider.swift`
- `leanring-buddy/PacePushToTalkManager.swift`
- `leanring-buddy/PaceLocalAgreementStabilizer.swift`
- `docs/architecture.md`
