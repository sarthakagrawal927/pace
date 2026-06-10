# Project Status

Last updated: 2026-06-10

## Current Scope

Pace is a local-only macOS menu-bar voice agent. It listens through on-device
speech recognition, can read the current screen through local OCR/VLM support,
answers through a local planner, speaks with Apple TTS, and can execute approved
macOS actions through local tools, Accessibility, EventKit, AppleScript-style
app integrations, and an MCP bridge. External launchers reach it through
`pace://` deeplinks, and two passive journals give it Dayflow-style time recall.

The project may need fleet registry alignment if it is intended to be tracked
under a different product slug such as `space`; no current `foundry.projects.json`
entry was found for `clickyLocal`, `Pace`, or `space`.

## Done

- Menu-bar/notch companion surface, settings window, cursor overlay, and
  push-to-talk flow are implemented.
- Local planner, local VLM screen analysis, Apple Vision OCR, Apple Speech STT,
  and Apple TTS are the documented runtime path; cloud LLM/STT/TTS paths are out.
- Agent mode supports approved local tool execution, AX-first clicking, grouped
  tool calls, plan-act-observe loops, watch mode, action result history, and
  local preference memory.
- First-pass Apple app integrations exist for Calendar, Reminders, Notes,
  Finder, Mail drafts, Things, Shortcuts, Messages, browser opening, volume,
  brightness, and media controls, plus `download_file` for user-commanded
  http(s) downloads into ~/Downloads (approval-gated; the product's only
  network action).
- MCP substrate is implemented and **validated end-to-end**: integration tests
  spawn the in-repo stdio fixture server (`scripts/mcp-fixture-server.py`) and
  prove the full initialize → tools/call → observation round trip;
  `mcp-servers.example.json` curates OSS connector starting points.
- `pace://` deeplinks (listen, chat, watch on/off, panel) give Raycast and
  Shortcuts first-class entry points; chat/listen turns run the normal
  intent/approval pipeline.
- **Time understanding journals**: watch-mode events persist into a screen
  watch journal, and a permission-free NSWorkspace tracker maintains an app
  usage journal — both retrieval sources answer "what did I do today?" /
  "how did I spend my time?" locally. The screen journal only covers periods
  watch mode is on; the usage journal records app-switch metadata only. Both
  are per-source disable/clear-able in Settings and keep 7 days.
- Full unit suite green: 315 tests including MCP integration, deeplink parser,
  journal, and download-tool coverage (run via `scripts/test-pace.sh`).

## Product Convergence (Assistant + Dayflow)

Pace now reads as both a **local voice assistant** (menu-bar agent, PTT,
streaming TTS, tool/MCP loop — like Dottie/OpenFelix) and a **screen-aware
memory surface** (watch journal + app-usage journal answering timeline-style
recall — like Dayflow), with `pace://` deeplinks for Shortcuts/Raycast parity.
Built-in competitive research covers Dayflow and the voice-assistant category
alongside Project Minimi.

## Planned Next

1. Resolve fleet registry identity: either add this repo as `clickyLocal` /
   `pace` / `space`, or document why it remains outside the fleet registry.
2. Install one live OSS MCP server (e.g. filesystem or Altic) on this machine
   and exercise it through a real voice turn; the bridge itself is already
   test-proven against the fixture.
3. One manual runtime session in the built app: deeplink URLs, journal Q&A,
   download approval flow, panel rows for the two new journal sources, plus
   the long-queued manual gates (v9 latency demo, click ambiguity evals,
   Reduce Motion checks).
4. Keep `CompanionManager.swift` decomposition scoped to the documented next
   splits: agent loop body and screen-context service.

## Deferred / Parked (blocked on local-model work)

- Real WhisperKit streaming ASR runtime (scaffold + LocalAgreement already
  wired; falls back to Apple Speech).
- In-process CoreML/MLX VLM runtime (falls back to LM Studio HTTP).
- Trained dictation/voice-edit specialists (rule-backed scaffolds wired).
- Vector retrieval (embedding model + SQLite-vec); BM25 lexical ships today.
- Planner LoRA path (v8+) parked on the TinyGPT side — runtime default is the
  eval-validated qwen3-30b-a3b MoE via LM Studio.
- Cloud LLM, cloud STT, and cloud TTS remain out of scope.
- Running `xcodebuild` from terminal is avoided except via
  `scripts/test-pace.sh`, which isolates DerivedData to protect TCC grants.
