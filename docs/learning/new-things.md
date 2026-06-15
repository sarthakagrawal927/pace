# New things to learn — pace

Novel frameworks and algorithms powering an entirely on-device voice+action Mac assistant.

---

## Apple FoundationModels (Apple Intelligence SDK)
- What: In-process, on-device LLM API introduced in iOS/macOS 26 — `SystemLanguageModel`, `@Generable` typed outputs, no HTTP, no cloud.
- Why here: TBD
- Gotcha (from code): `SystemLanguageModel.default.availability` must be checked at every call site — FM is absent on non-Apple-Intelligence Macs. Three check points: `AppleFoundationModelsPlannerClient.swift:84` (warmUp guard), `PacePlannerTierStore.swift:174` (first-launch tier resolution), `BuddyPlannerClient.swift:354` (factory `makeFoundationModelsPlannerOrFallback`). Each has a `LocalPlannerClient` fallback; missing the check surfaces as a crash or silent no-op on non-eligible hardware.
- Source: https://developer.apple.com/documentation/foundationmodels

## MCP (Model Context Protocol)
- What: Spec for LLM-to-tool communication over stdio JSON-RPC, so AI apps share a common tool-call dialect instead of hand-rolling integrations.
- Why here: TBD
- Gotcha (from code): Config is loaded from `~/.config/pace/mcp-servers.json` at call time — missing server names are caught by `PaceToolPreflight` (`PaceToolPreflight.swift`) before approval, not at launch. Catalog installs use atomic temp-file + rename in `PaceMCPCatalogInstaller` to preserve every user-added entry on each install.
- Source: https://modelcontextprotocol.io/specification

## WhisperKit (on-device streaming ASR)
- What: Swift package (Argmax) wrapping OpenAI Whisper large-v3-turbo as CoreML for real-time, privacy-safe transcription on Apple Silicon; ~9x realtime on ANE.
- Why here: TBD
- Gotcha (from code): WhisperKit is **fully wired** as of the current codebase (`WhisperKitTranscriptionProvider.isRuntimeAvailable = true`, line 32; full streaming session in `WhisperKitTranscriptionProvider.swift:110-223`). The factory (`BuddyTranscriptionProvider.swift:67`) selects it when `TranscriptionProvider=whisperKit` and `isRuntimeAvailable` is true; the Apple Speech fallback only fires when the flag is false. Model must be pre-placed at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>/` — `download: false` means a missing model throws immediately rather than fetching silently.
- Source: https://github.com/argmaxinc/WhisperKit

## Kokoro TTS + mlx-audio sidecar
- What: Kokoro-82M is an 82M-parameter Apache-licensed TTS model (StyleTTS2 architecture); mlx-audio serves it as an OpenAI-compatible `/v1/audio/speech` loopback sidecar (port 8880, ~150 ms warm latency, 24 kHz output).
- Why here: TBD
- Gotcha (from code): Sidecar endpoint is guarded by `PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL` at `LocalServerTTSClient.swift:51` — non-loopback URLs fall back to `localhost:8880`. First synth after boot is 20-30 s while Kokoro's MLX weights load (`LocalServerTTSClient.swift:29-30`); the 60 s timeout accounts for this. Any synthesis failure falls through to `AVSpeechSynthesizer` per-utterance with a 30 s outage memo.
- Source: https://huggingface.co/hexgrad/Kokoro-82M

## Loopback-guard (TTS self-capture prevention)
- What: Design constraint that ensures audio output from Pace's own TTS sidecar is never re-captured as microphone input.
- Why here: TBD
- Gotcha (from code): The URL-level guard (`PaceLocalEndpointGuard`, `LocalServerTTSClient.swift:51`) ensures audio synthesis only ever calls a loopback address. The audio pipeline exclusion zone (preventing `AVAudioEngine` from capturing `AVSpeechSynthesizer` or sidecar output) is architecturally noted but not yet implemented — it is the remaining open trust surface for self-capture prevention.
- Source: internal architecture — no single external spec; closest is Apple's AVAudioSession documentation.

## ScreenCaptureKit
- What: Apple's modern (macOS 13.0+, with enhanced per-display filters on macOS 14.2+) screen-capture framework — replaces `CGWindowListCreateImage`, runs in-process, permission-gated.
- Why here: TBD
- Gotcha (from code): Pace requires macOS 14.2+ (`CompanionScreenCaptureUtility.swift`) for reliable multi-monitor display enumeration. Screen Recording permission must be granted; the app links `WindowPositionManager.swift` to surface the System Settings deep link when the permission is missing.
- Source: https://developer.apple.com/documentation/screencapturekit

## Accessibility API (AX / NSAccessibility)
- What: macOS accessibility tree API — lets apps read UI element roles/labels and synthesize actions (press, set-value) without CGEvent coordinate clicks.
- Why here: TBD
- Gotcha (from code): `PaceAXTargeter.swift` climbs from `AXUIElementCopyElementAtPosition` up to a pressable role before firing `kAXPressAction`; if no pressable ancestor is found it returns false and `PaceActionExecutor` falls back to CGEvent. AX `set-value` edits are journaled in a session-local mutation log and reversible via `Undo.last` — the mutation log is the trust surface because the AX API itself has no undo primitive.
- Source: https://developer.apple.com/documentation/appkit/nsaccessibility

## LM Studio (OpenAI-compatible local server)
- What: Desktop app that serves local LLMs/VLMs behind an OpenAI-compatible HTTP API on `localhost:1234`; exposes `/v1/chat/completions`, `/v1/embeddings`, `/v1/completions`.
- Why here: TBD
- Gotcha (from code): `PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL` (`PaceLocalEndpointGuard.swift:23`) validates every planner and VLM URL at construction time — a plist value pointing at a LAN or remote host silently falls back to `localhost:1234` with a printed warning. Two models can be loaded simultaneously via LM Studio Settings → max-loaded-models=2 (planner + VLM) to avoid thrashing.
- Source: https://lmstudio.ai/docs/api/openai-api

## BM25 (lexical retrieval ranking)
- What: Probabilistic term-frequency/inverse-document-frequency ranking algorithm (Okapi BM25) — fast, no embeddings needed, interpretable scores; standard baseline for sparse retrieval in RAG systems.
- Why here: TBD
- Gotcha (from code): `PaceLocalRetrieval.swift` uses a BM25-style in-memory scorer across all retrieval sources (history, notes, calendar, files, screen-watch, app-usage) before optional embedding re-ranking via `PaceEmbeddingReranker` (LM Studio `/v1/embeddings`). Vector/SQLite-vec retrieval is queued but not yet live — BM25 is the only ranking path in production.
- Source: https://en.wikipedia.org/wiki/Okapi_BM25

## @Generable typed outputs (constrained decoding via FoundationModels)
- What: Swift macro from the FoundationModels framework that generates a grammar-constrained decoder for a `struct` — the model can only produce tokens that form valid JSON matching the schema, so hallucinated field values become structurally impossible.
- Why here: TBD
- Gotcha (from code): `PaceFMTurnResponse` (`PaceFMTurnResponse.swift:40`) replaces freeform `[CLICK:x,y]` string tags with integer element IDs (`pointAtElementId`, `clickElementId`). The model picks from the on-screen element list or returns -1; it never writes raw coordinates, eliminating the coordinate hallucination failure mode of the string-tag protocol. Trade-off: `respond(to:generating:)` is non-streaming — the full `spokenText` arrives as one chunk, slightly increasing TTFSW vs the streaming string path.
- Source: https://developer.apple.com/documentation/foundationmodels

## Speculative planner race
- What: Running a fast "lite" planner (Apple FM, no VLM) in parallel with the full VLM-fed planner, letting whichever produces its first token first win the TTS stream.
- Why here: TBD
- Gotcha (from code): `PaceSpeculativePlannerRace.raceSpeculative` (`PaceSpeculativePlannerRace.swift:130`) always returns BOTH planners' complete text (`PaceSpeculativeRaceResult.fullPlannerResponseText`); action parsing in `CompanionManager` exclusively uses the full planner's text regardless of which path won audio (lines 187-194). Supersede window: 500 ms from lite's first token AND fewer than 60 spoken chars — past either threshold the lite winner stands to avoid mid-speech jarring cuts. Gate (`speculativeRaceShouldFire`, `CompanionManager.swift:441`) requires toggle ON + local VLM configured + Apple FM available + intent is `.screenAction` or `.screenDescription`.
- Source: `PaceSpeculativePlannerRace.swift`, `CompanionManager.swift`
