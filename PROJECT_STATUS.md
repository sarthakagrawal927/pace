# Project Status

Last updated: 2026-06-20. Latest test count: **1075/1075 passing** (`bash scripts/test-pace.sh`).

## Current Scope

Pace is a local-only macOS menu-bar voice agent. It listens through on-device
speech recognition, reads the current screen through a local VLM + Apple
Vision OCR + the Accessibility tree, plans through a local model (in-process
MLX by default; LM Studio remains a power-user option), speaks through TTS,
and executes approved macOS actions through Accessibility, EventKit,
AppleScript-style app integrations, App Intents, and an MCP bridge. External
launchers reach it through `pace://` deeplinks **and** Siri/Shortcuts/
Spotlight via `AppIntent`.

The marketing surface lives at [`website/`](./website/) — Astro 5 + Tailwind
v4 + Lightning CSS, deployed to Cloudflare Pages.

## Done

### Her-arc + voice loop (v0.3.12 baseline)

- Restraint policy, episodic memory, always-listening wake word on ANE,
  proactive nudges (focus-fatigue, calendar pre-meeting, watch-mode
  observation), barge-in VAD, demonstration replay — all opt-in defaults
  gated by the restraint gate.
- Trust surfaces: undo banner, reply replay, `PaceFailureNarrator`,
  privacy dashboard.
- In-window chat surface (`cmd+shift+P` notch chat input).
- Planner tier picker (Local / CLI bridge / Direct API / Apple FM) with
  Keychain-backed API keys.
- Recipe library: five bundled flows (morning standup, weekly review,
  email zero, focus mode on, end-of-day shutdown).
- MCP substrate: integration tests against the in-repo stdio fixture,
  one-tap catalog (six servers), atomic merge into user config.
- `pace://` deeplinks (listen / chat / watch / panel).
- Watch-mode + app-usage journals.
- Posture watch (opt-in camera every 10s; frames never stored).

### On-device stack — fully shipped this cycle

- **Phase A — Apple NaturalLanguage embedder fallback.** Closes the "LM
  Studio not running" hole. `PaceChainedTextEmbeddingClient` chains the
  primary (LM Studio or bundled MLX) with the always-available Apple NL.
- **Phase B — In-process MLX planner.** `PaceMLXPlannerClient` via
  mlx-swift-examples (`MLXLLM` + `MLXLMCommon`). Default shipping model:
  **`mlx-community/Qwen3-4B-Instruct-2507-bf16`**. Plan-then-execute
  scaffold (`CompanionSystemPrompt.wrapWithPlanThenExecuteScaffoldForBundledMLX`)
  is auto-applied to every system prompt the bundled MLX path sees.
- **Phase C — In-process MLXVLM.** `PaceMLXScreenAnalysisClient` runs
  Qwen3-VL-4B-Instruct-4bit directly via mlx-swift-examples. Drops the
  LM Studio `max-loaded-models=2` brittleness.
- **Phase D — Qwen3 TTS via WhisperKit TTSKit.** `PaceQwen3TTSClient`
  drops the Kokoro Python sidecar dependency. WhisperKit shipped a
  finished TTSKit product — no StyleTTS2 port required.
- **WhisperKit auto-default.** Factory selects WhisperKit-Large when the
  model is on disk; falls back to Apple Speech otherwise.
- **Settings → Models tab.** Four toggles (planner / embedder / VLM / TTS),
  per-model identifier text fields, "Download now" prefetch with real
  NSProgress %, quality-caveat block.
- **Info.plist manifest for model identifiers.**
  `BundledMLXPlannerModelIdentifier`, `BundledMLXEmbedderModelIdentifier`,
  `BundledMLXVLMModelIdentifier`. Future Sparkle releases push pace-tuned
  models via the manifest alone — no source changes.
- **Eval-gate harness.** `PaceMLXPlannerEvalHarnessTests` + the
  `shippingDefaults` pin in `PaceBundledModelsSettingsTests` are the
  deliberate forcing function: bumping the shipping model fails the test
  until you've explicitly run the eval gate.

### macOS feature steals shipped this cycle

- **App Intents** (`PaceAppIntents.swift`): `PaceConversationIntent`,
  `PaceStartListeningIntent`, `PaceShowPanelIntent`,
  `PaceSetWatchModeIntent`, `PaceTranscribeAudioFileIntent`. Siri /
  Shortcuts / Spotlight surfaces all light up.
- **NSDataDetector** typed entities prepended to the screen-context block.
- **CoreSpotlight memory mirror** (`PaceSpotlightMemoryIndexer`).
- **`INFocusStatusCenter`** wired into `PaceRestraintGate`.
- **NSSharingService** right-click on chat messages.
- **`Translation.LanguageAvailability`** probe.
- **Thermal-state advisor** (`PaceThermalStateAdvisor`) gating the
  speculative race; per-surface gates ready for watch / proactives /
  prewarm.
- **IDE focus detector** (`PaceIDEContextDetector`) — Xcode / VS Code /
  Cursor / Sublime / JetBrains / Zed / Nova / TextMate.
- **Memory write-time enrichment** (`PaceMemoryEntryEnricher`) — NLTagger
  named entities + NSDataDetector typed contacts into
  `PaceMemoryEntry.structured`.
- **Long-form audio transcription** (`PaceAudioFileTranscriber` +
  `PaceTranscribeAudioFileIntent`).
- **`PaceLazyEmbeddingScheduler`** extracted from CompanionManager.

### PRD closure sweep (v0.3.14)

- **Click ambiguity fixtures** — `evals/click-ambiguity-fixtures/` +
  `PaceClickAmbiguityFixtureTests` (CI gate for HUD disambiguation rule).
- **v10 generic field streaming** — `PaceStreamingPlannerFieldDetector`
  streams dictate/edit/`AX.setValue` text during planner output (alongside
  existing Mail.draft streaming).
- **Executor smoke runner** — `scripts/smoke-executor-surface.sh` chains
  dry-run unit tests, v10 schema fixtures, runtime hooks, and
  `scripts/smoke-real-apps.sh` (Notes/Safari/Mail mailto).
- **Remote model manifest** — optional `RemoteModelManifestURL` +
  `PaceRemoteModelManifest` (24h cache, overrides bundled defaults when set).
- **v10 eval gate** — `scripts/eval-v10-gate.sh` (unit + schema + FM sweep).
- **Landing pre-launch (repo)** — OG PNG, commerce config with mailto fallback,
  honest early-access social proof (no fictional names).
- **Pace-tuned model scaffold** — `docs/plans/pace-tuned-model-v1.md`,
  `scripts/train-pace-tuned-model.sh`, `evals/pace-tuned-export/`.

### Landing site (new this cycle)

- `website/` — Astro 5 + Tailwind v4 + Lightning CSS, single page, 52 KB
  built HTML with inline CSS. Sections: Hero (CSS-only animated demo
  above the fold) → OnDevice → Features (six) → Comparison (Pace vs
  Wispr Flow / Raycast / MacWhisper / Siri) → Pricing (Try free / Pace
  $29 / Studio $5/mo) → SocialProof (gated until real quotes exist) →
  FAQ → Footer (signed founder paragraph + "0 bytes today" punchline).
- Walks the [`fleet/LANDING_STANDARD.md`](../LANDING_STANDARD.md) audit
  checklist. Open items called out in [`website/README.md`](./website/README.md).

## Planned Next

1. **First pace-tuned model.** Dataset export → LoRA train → eval gate. Scaffold:
   `docs/plans/pace-tuned-model-v1.md`, `scripts/train-pace-tuned-model.sh`,
   `evals/pace-tuned-export/`. Blocked on opt-in turn collection, not code.
2. **Stripe checkout URL.** Set `PUBLIC_PACE_CHECKOUT_URL` at Cloudflare Pages
   build when live (mailto fallback ships today).
3. **Permissioned public testimonials.** Replace private-beta theme cards in
   `SocialProof.astro` when 3+ real quotes exist.
4. **Voice Mail latency demo.** Manual `<700ms` check with Mail prewarm
   (see `scripts/smoke-executor-surface.sh` checklist).

## Pricing posture

- **Try** — Free, Apple Intelligence only, acquisition funnel.
- **Pace** — $29 one-time, full bundled MLX + Composio + research
  escalation + future pace-tuned model upgrades free.
- **Studio** — $5/mo for the optional Composio-routing and founder-
  direct support; ongoing-cost tier only.

Price rises to **$49** for new buyers when the first pace-tuned model
ships; current buyers grandfather in.

## Model supply

The hard model-supply work for this cycle is **done**. Every role has a
bundled in-process option (MLX 4B planner, MLXVLM, MLXEmbedders + Apple
NL fallback, WhisperKit Large, TTSKit Qwen3) plus the existing LM Studio
HTTP path as the power-user upgrade. No external dependency required for
a fresh install to be useful end-to-end.

Trained pace-specialist models are a **product investment** (Sparkle
delivery, eval gate, distribution under `pace-ai/*` on HuggingFace) —
the implementation runway is clear; the gate is data collection +
fine-tune scheduling, not engineering surface.

## Build notes

- Run `xcodebuild` only via `scripts/test-pace.sh` (isolated DerivedData
  protects TCC grants).
- Website: `cd website && npm install && npm run dev`.
