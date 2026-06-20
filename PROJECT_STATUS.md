# pace — PROJECT STATUS

Last updated: 2026-06-20

## Why/What

**Thesis:** macOS menu-bar voice agent that answers in under ~500 ms time-to-first-spoken-word (TTFSW), fully on-device — no cloud LLM, no API keys, no Worker telemetry. Hold hotkey → speak → Pace reads the screen (optional), plans locally, streams TTS, and optionally executes approved macOS actions.

**In scope:** Menu-bar/notch UI, push-to-talk, on-device ASR/TTS/VLM/planner, action executor (AX-first clicks), trust surfaces, episodic + thread memory, watch mode, journals, proactive nudges (opt-in), MCP substrate, recipe library, `pace://` deeplinks, App Intents (Siri/Shortcuts), bundled MLX model supply, marketing site (`website/`), eval gates, pace-tuned model export scaffold.

**Out / parked:** Persistent KV planner backend (blocked on TinyGPT oMLX), grammar-constrained v10 as runtime default (eval-gated), cloud bridge as default tier, hosted monitoring, CI-automated live-app AX smokes.

## Dependencies

### External

- **Platform:** macOS 14.2+, Apple Silicon recommended, Xcode 16+, ~12–25 GB RAM with models loaded.
- **On-device models:** MLX Qwen3-4B planner, Qwen3-VL-4B VLM, WhisperKit Large ASR, TTSKit Qwen3 TTS, Apple Speech default.
- **Optional cloud:** Direct API BYO-key (Keychain); CLI bridge; Apple Foundation Models tier.
- **Legacy path:** LM Studio optional OpenAI-compatible localhost — `./scripts/setup-local.sh`.
- **Landing deploy:** Cloudflare Pages project `pace`.
- **Release:** GitHub Releases + Sparkle updates with bundled model manifest.
- **License:** MIT — `github.com/sarthakagrawal927/pace/releases/latest`.

### Internal fleet

- **Landing standard:** walk `fleet/LANDING_STANDARD.md` before major marketing changes.
- **TinyGPT oMLX:** blocks persistent KV planner backend and grammar-constrained v10 runtime default.

### Stack & commands

| Surface | Stack | Commands |
| --- | --- | --- |
| macOS app | Swift/SwiftUI, Xcode `leanring-buddy.xcodeproj` | Open in Xcode → Cmd+R (**do not** `xcodebuild` — invalidates TCC) |
| Tests | XCTest via isolated DerivedData | `bash scripts/test-pace.sh` — **1079/1079 passing** |
| Local models | MLX, WhisperKit, TTSKit, Apple Speech | Settings → Models; Sparkle manifest in Info.plist |
| Landing | Astro 5 + Tailwind v4 + Lightning CSS | `cd website && npm install && npm run dev` (:4321) |
| Deploy landing | Cloudflare Pages project `pace` | `npm run build && npm run deploy` |
| Eval / smoke | Shell harnesses | `bash scripts/eval-v10-gate.sh`, `scripts/smoke-executor-surface.sh`, `scripts/benchmark_ttfsw.sh` |
| Pace-tuned export | Local JSONL → repo | `bash scripts/export-pace-tuned-turns.sh` |

**Docs:** `AGENTS.md` (canonical agent instructions), `SETUP_LOCAL.md`, `docs/key-files.md`, `docs/info-plist-switches.md`, `docs/brand/`.

**Pricing posture (landing):** Try (free) / Pace ($29 one-time) / Studio ($5/mo Composio routing). Checkout via `PUBLIC_PACE_CHECKOUT_URL` (mailto fallback until set).

```
Menu bar capsule (PaceMenuBarOverlay) → floating panel + optional cursor overlay
  ├─ Voice: AVAudioEngine push-to-talk, global CGEvent tap (ctrl+option)
  ├─ ASR: Apple SFSpeechRecognizer default; WhisperKit optional scaffold
  ├─ Screen: ScreenCaptureKit multi-monitor; optional local VLM (LM Studio / MLX)
  ├─ Planner: BuddyPlannerClient — tier picker (Local MLX / Apple FM / CLI bridge / Direct API)
  ├─ TTS: LocalServerTTSClient (Kokoro sidecar) → AVSpeechSynthesizer fallback
  ├─ Actions: PaceActionExecutor — AX press → CGEvent; approval policy; undo banner
  ├─ Memory: PaceThreadMemory (K=4 verbatim + rolling summary, persisted JSON)
  │          PaceEpisodicMemory, screen-watch + app-usage journals (7-day retention)
  ├─ MCP: PaceMCPClient stdio servers from ~/.pace/mcp-servers.json + bundled catalog
  └─ Trust: PaceUndoBanner, reply replay, PaceFailureNarrator, PacePrivacyDashboard
```

**Privacy moat:** "0 bytes sent off this Mac" badge unless off-device tier active (amber capsule tint). Loopback guard on local HTTP endpoints.

**Plan-act-observe:** Up to `AgentMaxSteps` (default 8) with re-screenshot between steps; planner emits `[DONE]` when finished.

## Timeline

- **v0.3.12–0.3.14 cycle:** Her-arc voice loop, trust surfaces, on-device model supply, macOS integrations, executor/planner v10, MCP/recipes, landing shipped.
- **2026-06-20:** Restraint policy, episodic memory, wake word, proactive nudges, barge-in VAD, demonstration replay, trust-and-failures, recipe library, planner tier picker, cloud-bridge toggle, chat interface, conversational thread memory, first-run experience, morning triage, inclusivity surface, always-listening mode, unified memory, local RAG layer (substrate), local VLM runtime port, WhisperKit streaming scaffold, HUD intent disambiguator, dictation postproc, v8/v9/v10 planner iterations, click executor improvements, set-of-mark click recovery, executor surface, Her-arc roadmap meta — all landed.
- **Active plan:** `docs/plans/pace-tuned-model-v1.md` — export wired; LoRA pending data.
- **Test suite:** 1079/1079 XCTest cases via `scripts/test-pace.sh`.

## Products

| Product | Surface | Role |
| --- | --- | --- |
| Pace macOS app | Menu-bar/notch capsule + floating panel | On-device voice agent with optional screen actions |
| Marketing site | `website/` on Cloudflare Pages | Try/Pace/Studio pricing, on-device pitch, FAQ |
| Pace-tuned model scaffold | Settings export + eval scripts | Local turn collection → LoRA training pipeline |
| MCP + recipes | Settings → MCP, bundled flows | stdio tool bridge + voice-installable recipe library |

## Features (shipped)

### Voice loop & core UX (v0.3.12–13, Her-arc)

- Push-to-talk with glassmorphic notch animation; Codex-style cursor with gradient arrow.
- Streaming sentence TTS for sub-500 ms perceived latency; TTFSW logged per turn (`scripts/benchmark_ttfsw.sh`).
- In-window chat (`cmd+shift+P`) in menu-bar panel.
- Intent classifier routes chitchat / pure-knowledge / screen-action paths.
- VLM-skip heuristic for non-screen-referential transcripts; override `AlwaysRunLocalVLMRegardlessOfTranscript`.
- Speculative planner race (first step): Apple FM lite vs full VLM path; action parsing always from full planner text.

### Trust & failures

- 5-second floating undo banner for reversible mutations; `Undo.last` via executor.
- 30-second reply replay after TTS (same post-processed string, no re-plan).
- `PaceFailureNarrator` — deterministic plain-language failures (planner offline, permission, click missed, TTS sidecar, MCP).
- `PaceRestraintGate` — silence during active calls; proactive cooldown.
- Privacy dashboard reads local `PaceAPIAuditLog` JSONL only.

### Restraint policy & proactive (opt-in, default OFF)

- Wake word (ANE), proactive nudges, barge-in VAD, demonstration replay — gated by restraint.
- Posture watch (frames never stored), focus-fatigue nudges, calendar pre-meeting nudges.
- Morning brief (`PaceMorningTriageScheduler`) parked on panel when restraint says quiet.
- Watch mode: `PaceScreenWatchModeController` + voice commands via `PaceWatchModeCommandParser`.

### Memory & recall

- Two-tier thread memory: last 4 turns verbatim + rolling Apple FM summary; persists `~/Library/Application Support/Pace/thread-memory.json`.
- Episodic memory for durable facts (separate from thread summary).
- Screen-watch journal + app-usage journal (7 days, NSWorkspace — no extra permission).
- CoreSpotlight memory mirror; memory write-time enrichment.

### On-device model supply

- In-process MLX planner (Qwen3-4B), MLXVLM, chained embedder (MLX + Apple NL fallback).
- Qwen3 TTS via TTSKit; WhisperKit auto-default ASR path scaffolded.
- Settings → Models tab: download prefetch, Info.plist model manifest for Sparkle delivery.
- Eval-gate harness pins shipping model identifiers (`PaceBundledModelsSettingsTests.shippingDefaults`).

### macOS integrations

- App Intents — Siri / Shortcuts / Spotlight entry points.
- `pace://` deeplinks: `listen`, `chat?text=`, `watch?enabled=`, `panel` — reject-on-ambiguity parser.
- NSDataDetector entities; IDE focus detector; thermal-state advisor.
- Focus Status in restraint gate; long-form audio transcription.
- Contacts resolution for Mail compose; EventKit calendar/reminders; Finder/Notes/Mail/Things/Shortcuts/Messages integrations.

### Executor & planner (v0.3.14)

- **Click executor:** top-K parser/scorer, focused-window scoring, AX verify/retry, recency hints, unit fixtures.
- **Set-of-mark click recovery:** Phase A miss-case (`PaceSetOfMarkClickRecovery`).
- **Planner v10 + executor surface:** typed envelope, registry validation, streaming fields, smoke runners.
- **Click ambiguity fixtures**, v10 generic field streaming, executor smoke runner, remote model manifest, v10 eval gate.
- Grammar-constrained model gate remains TinyGPT/eval gated — not runtime default.
- Tool registry (`PaceToolRegistry`) validates at startup; grouped parallel `<tool_calls>` JSON + legacy action tags.

### MCP & recipes

- MCP stdio bridge with fixture server integration tests; example config for filesystem/fetch/github/applescript.
- Bundled catalog (filesystem, fetch, github, applescript, slack, linear) — atomic install into `mcp-servers.json`.
- Recipe library: 5 bundled flows (morning-standup, weekly-review, email-zero, focus-mode, end-of-day); voice install/uninstall.

### Planner tier picker & optional cloud paths

- Settings → Planner: Local (default) / Apple Foundation Models / CLI bridge / Direct API BYO-key (Keychain).
- Direct API keys never in UserDefaults/logs; off-device turn amber indicator.
- Cloud bridge consent + 24-hour soak gate; fails loud unless explicit fallback toggle.

### Landing & product scaffold

- Astro landing deployed to Cloudflare Pages (`pace` project).
- Sections: Nav, Hero (CSS demo), OnDevice, Features, Comparison, Pricing, FAQ, Footer ("0 bytes" counter).
- OG PNG at `website/public/og-image.png`; regenerate via `scripts/generate-og-image.sh`.
- Social proof section gated (`showSocialProofSection = false`) until 3+ permissioned quotes.
- Commerce config: `src/config/commerce.ts` — mailto checkout fallback.

### Pace-tuned model scaffold

- Settings opt-in exporter → `~/Library/Application Support/Pace/pace-tuned-turns.jsonl` (redacted).
- `scripts/export-pace-tuned-turns.sh` → `evals/pace-tuned-export/`.
- `scripts/train-pace-tuned-model.sh` + eval gate docs in `docs/plans/pace-tuned-model-v1.md`.
- Holdout fixtures: `evals/fm-fixtures-holdout/` never used for training.

### Eval & quality

- FM fixture sets: v1, v2, holdout, OOS, destructive, ambig — under `evals/fm-fixtures*/`.
- VLM fixtures: `evals/fm-vlm-fixtures-v1/` for vision-grounded planner cases.
- `scripts/eval-planners.py` — empirical planner comparison (Qwen3-30B-A3B baseline).
- `scripts/eval-v10-gate.sh` — grammar-constrained gate for shipping decisions (`PACE_RUN_MLX_EVAL=1` for MLX path).
- `scripts/benchmark_ttfsw.sh` — aggregates TTFSW/TTFT from app logs for publishable latency tables.
- Live-app executor smokes: `scripts/smoke-executor-surface.sh` (manual-only, not CI).
- Coverage spans: action tag parser, click ambiguity fixtures, set-of-mark recovery, MLX planner eval harness, MCP catalog/installer, restraint gate, annotation overlay, remote model manifest, streaming field detector, privacy dashboard classification, IDE focus detector, thermal advisor, Spotlight indexer, CompanionManager extension modules.

### Settings & configuration surfaces

- **PaceSettingsWindow** (gear from notch panel): MCP servers, permissions, voice, preferences, memory, action history, planner tier, models download, flows/recipes, privacy dashboard.
- **Info.plist switches** documented in `docs/info-plist-switches.md` — `EnableActions`, `UseLocalVLMForScreenContext`, `TranscriptionProvider`, `TTSProvider`, planner/VLM URLs, smoke hooks (`PACE_ENABLE_SMOKE_HOOKS=1`).
- **First-run default:** fresh installs with no planner tier UserDefaults prefer Apple Foundation Models when Apple Intelligence available; existing users unchanged.

### Action & tool surface (agent mode)

- Grouped parallel `<tool_calls>` JSON with sequential outer array; legacy tags still parsed.
- Local tools: click/double-click, type, key chords, scroll, open app/URL, music/volume/brightness, calendar/reminders, mail compose, Notes/Things/Shortcuts/Messages, clipboard read, window snap, `download_file` (http(s) → ~/Downloads, approval-gated), `run_flow` / `record_flow`, MCP passthrough.
- AX-first targeting (`PaceAXTargeter`) with CGEvent fallback; session mutation log + undo for set-value edits.
- Approval policy: risky/non-undoable actions prompt when `Approve Risky Actions` on; routine local actions execute without popup.

### Website (`website/`)

- Astro 5 static export; Cloudflare Pages project **`pace`**.
- Components: Nav, Hero (CSS-only animated demo), OnDevice pitch, Features (six capabilities), Comparison vs Wispr/Raycast/MacWhisper/Siri, Pricing (Try/Pace/Studio), gated SocialProof, FAQ (eight questions), Footer with "0 bytes" counter + founder signature.
- Commerce: `src/config/commerce.ts` — mailto fallback; `PUBLIC_PACE_CHECKOUT_URL` / `PUBLIC_STUDIO_CHECKOUT_URL` at deploy.
- OG: `public/og-image.png` via `scripts/generate-og-image.sh`; audit against `fleet/LANDING_STANDARD.md`.

## Todo / Planned / Deferred / Blocked

### Planned

1. **First pace-tuned model** — collect turns via Settings export, LoRA train + eval gate per `docs/plans/pace-tuned-model-v1.md`.
2. **Stripe checkout URL** — set `PUBLIC_PACE_CHECKOUT_URL` (and optional `PUBLIC_STUDIO_CHECKOUT_URL`) in Pages build env.
3. **Permissioned public testimonials** — replace private-beta theme cards when 3+ real quotes exist.
4. **Voice Mail latency demo** — manual `<700 ms` check with Mail prewarm.
5. **WhisperKit streaming bridge** — complete scaffold when `TranscriptionProvider=whisperKit` selected.

### Deferred

- **Persistent KV planner backend** — blocked on TinyGPT oMLX qualification; in-process MLX is default.
- **Grammar-constrained v10 runtime default** — TinyGPT/eval gated; shipping planner remains current MLX/Qwen stack.
- **Real-app AX smokes in CI** — manual-only; TCC makes automated live-app tests fragile.
- **Cloud bridge / Direct API as default** — contradicts on-device moat; opt-in tiers only.
- **Hosted telemetry or accounts** — local-only analytics hooks; no cloud SDK.

### Blocked

- Live-app click ambiguity smokes not CI-automated.
- Social proof section gated until real user quotes.
- README still references LM Studio as primary setup path; bundled MLX + Settings → Models is the shipping path for downloads.
- Known non-blocking Xcode warnings (Swift 6 concurrency, deprecated onChange) — intentionally not fixed per AGENTS.md.
- Pace-tuned LoRA run blocked on sufficient exported turn volume.
- **TCC:** Never run terminal `xcodebuild` for routine dev — re-requests screen recording, accessibility, mic permissions.
- **Benchmark publish:** Use measured TTFSW from `benchmark_ttfsw.sh` — do not claim latency without local numbers.
