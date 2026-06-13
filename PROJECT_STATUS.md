# Project Status

Last updated: 2026-06-13 (v0.3.12 shipped to GitHub, commit 897d4c6).

## Current Scope

Pace is a local-only macOS menu-bar voice agent. It listens through on-device
speech recognition, can read the current screen through local OCR/VLM support,
answers through a local planner, speaks with Apple TTS or the Kokoro sidecar,
and can execute approved macOS actions through local tools, Accessibility,
EventKit, AppleScript-style app integrations, and an MCP bridge. External
launchers reach it through `pace://` deeplinks, and two passive journals give
it Dayflow-style time recall.

The project may need fleet registry alignment if it is intended to be tracked
under a different product slug such as `space`; no current `foundry.projects.json`
entry was found for `clickyLocal`, `Pace`, or `space`.

## Done

- **Her-arc complete (v0.3.12).** Restraint policy, episodic memory, always-
  listening (Apple Speech wake-word on ANE), proactive nudges (focus-fatigue,
  calendar pre-meeting, watch-mode observation), barge-in VAD, and
  demonstration replay all ship behind opt-in defaults gated by the restraint
  gate.
- **Quality of life round (v0.3.11).** In-window chat surface, planner tier
  picker with Keychain-backed API keys, cloud-bridge consent, conversational
  thread memory, Apple-FM-first first-run experience, morning triage,
  recipe library (5 bundled flows), trust surfaces (undo banner + reply
  replay + `PaceFailureNarrator`), and the inclusivity surface
  (`cmd+shift+P` notch chat, one-tap MCP catalog, privacy dashboard).
- Menu-bar/notch companion surface, settings window, cursor overlay, and
  push-to-talk flow are implemented.
- Local planner (qwen3-30b-a3b via LM Studio by default), local VLM screen
  analysis, Apple Vision OCR, Apple Speech STT, Kokoro TTS sidecar (Apple
  AVSpeechSynthesizer fallback) are the documented runtime path.
- Agent mode supports approved local tool execution, AX-first clicking, grouped
  tool calls, plan-act-observe loops, watch mode, action result history, and
  local preference memory.
- First-pass Apple app integrations exist for Calendar, Reminders, Notes,
  Finder, Mail drafts, Things, Shortcuts, Messages, browser opening, volume,
  brightness, and media controls, plus `download_file` for user-commanded
  http(s) downloads into ~/Downloads (approval-gated; the product's only
  network action).
- MCP substrate is implemented and validated end-to-end: integration tests
  spawn the in-repo stdio fixture server (`scripts/mcp-fixture-server.py`)
  and prove the full initialize → tools/call → observation round trip;
  Settings → MCP ships a bundled six-server one-tap catalog
  (`PaceMCPServerCatalog`).
- `pace://` deeplinks (listen, chat, watch on/off, panel) give Raycast and
  Shortcuts first-class entry points; chat/listen turns run the normal
  intent/approval pipeline.
- **Time understanding journals**: watch-mode events persist into a screen
  watch journal, and a permission-free NSWorkspace tracker maintains an app
  usage journal — both retrieval sources answer "what did I do today?" /
  "how did I spend my time?" locally.
- **Posture watch (opt-in)**: one camera frame every ten seconds through
  Vision face detection, median-calibrated baseline, hysteresis + cooldown,
  gentle spoken nudges for slouching/leaning. Off by default; frames are
  analyzed on-device and never stored.
- Embedding re-ranker over lexical retrieval (LM Studio `/v1/embeddings`,
  best-effort with lexical fallback) — the first slice of the vector-RAG
  track.
- Full unit suite green: 717 tests including MCP integration, deeplink
  parser, journal, posture, reranker, episodic memory, recipe library,
  morning triage, restraint, proactive nudges, flow replay, and download-tool
  coverage (run via `scripts/test-pace.sh`).

## Product Convergence (Assistant + Dayflow + Her-arc)

Pace now reads as both a **local voice assistant** (menu-bar agent, PTT,
always-listening wake-word, streaming TTS, tool/MCP loop — like Dottie/
OpenFelix), a **screen-aware memory surface** (watch journal + app-usage
journal answering timeline-style recall — like Dayflow), and an
**ambient-companion** (proactive nudges + episodic recall + demonstration
replay), with `pace://` deeplinks for Shortcuts/Raycast parity.

## Planned Next

1. **Click executor manual ambiguity evals → unit tests.** Convert the
   queued manual eval set into a fixture-driven test suite so regressions
   in the top-K scorer/recency-hint logic surface in CI. See
   `docs/prds/click-executor-improvements.md`.
2. **Visual target ambiguity HUD path.** Wire the executor top-K
   candidate output into a panel option-list clarification (mirrors the
   shipped edit/destructive clarifications). See
   `docs/prds/hud-intent-disambiguator.md`.
3. **Executor real-app AX/performance smoke flow.** Mail / Safari /
   Notes / Slack / VSCode / Cursor smokes via
   `scripts/smoke-runtime-hooks.sh`. See `docs/prds/pace-executor-surface.md`.
4. **v10 grammar-constrained model-output gate + runtime-default
   switch** once eval-planners.py picks the v10 winner. See
   `docs/prds/pace-planner-v10-parameterized-actions.md`.
5. **Network observability tool access**: expose Sniffnet
   (github.com/GyulyVGC/sniffnet) to the agent loop — most likely as an
   MCP server or CLI-backed tool.
6. **Fleet registry identity**: either add this repo as `clickyLocal` /
   `pace` / `space`, or document why it remains outside the fleet
   registry.
7. Keep `CompanionManager.swift` decomposition scoped to the documented
   next splits: agent loop body and screen-context service.

## Deferred / Parked (blocked on local-model work)

- Real WhisperKit streaming ASR runtime (scaffold + LocalAgreement already
  wired; falls back to Apple Speech).
- In-process CoreML/MLX VLM runtime (falls back to LM Studio HTTP).
- Trained dictation/voice-edit specialists (rule-backed scaffolds wired).
- Vector retrieval (bundled embedding model + SQLite-vec); BM25 lexical +
  best-effort embedding re-ranker ship today.
- Planner LoRA path (v8+) parked on the TinyGPT side — runtime default is the
  eval-validated qwen3-30b-a3b MoE via LM Studio.
- v9 manual latency demo (Pace-side wiring complete).
- Cloud LLM (default-off CLI bridge + opt-in Direct-API BYO are the
  user-owned trapdoors; no implicit cloud egress).
- Running `xcodebuild` from terminal is avoided except via
  `scripts/test-pace.sh`, which isolates DerivedData to protect TCC grants.
