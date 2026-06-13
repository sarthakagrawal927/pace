# Pace PRDs

This directory holds the per-pillar product requirements for Pace. `docs/architecture.md`
is the canonical system map; these PRDs turn each pillar into implementation
scope, test gates, and acceptance criteria.

## Current Set

| PRD | Status | Purpose |
|---|---|---|
| `restraint-policy.md` | shipped (v0.3.12) | Pure speak/stay-quiet/queue gate that every proactive source flows through. Active-call detection + user-input timing wired. |
| `proactive-nudges.md` | shipped (v0.3.12) | Focus-fatigue / calendar pre-meeting / watch-mode observation nudges, all default-off, gated by restraint. |
| `barge-in-tts-interrupt.md` | shipped (v0.3.12) | User can interrupt Pace mid-TTS by speaking; VAD subscribes to the existing audio tap. |
| `episodic-memory.md` | shipped (v0.3.12) | Apple FM (with LM Studio fallback) extracts durable facts from completed turns, dedups, tombstones, and surfaces them through retrieval. |
| `always-listening-mode.md` | shipped (v0.3.12) | Apple Speech on-device wake-word spotter on ANE; PTT preserved as the safety floor. |
| `demonstration-replay.md` | shipped (v0.3.12) | Voice-driven record-and-replay AX flows into auditable local JSON, plus Settings → Flows surface. |
| `chat-interface.md` | shipped (v0.3.11) | In-window chat tab + sticky text input in PaceMainWindow → Conversations; voice + chat share `paceHistory`. |
| `cloud-bridge-toggle.md` | shipped (v0.3.11) | Consent-gated planner routing through the sibling Claude Code / Codex / Gemini CLI bridge; 24-hour soak before always-bridge. |
| `conversational-thread-memory.md` | shipped (v0.3.11) | Last K turns verbatim + rolling FM summary of older turns; injected as `<conversation_so_far>` each planner call. |
| `first-run-experience.md` | shipped (v0.3.11) | Clean-install tier defaults to Apple FM when available; notch starter prompts; PaceMainWindow Skills tab. |
| `inclusivity-surface.md` | shipped (v0.3.11) | `cmd+shift+P` notch chat input, one-tap MCP server catalog, Privacy dashboard reading the local audit log. |
| `morning-triage.md` | shipped (v0.3.11) | Weekday morning brief composed deterministically from Calendar/Mail/Reminders/usage/watch sources; restraint-gated. |
| `planner-tier-picker.md` | shipped (v0.3.11) | Settings → Planner picker (Local / CLI bridge / Direct API BYO / Apple FM); Keychain-backed API keys + amber-tinted capsule for non-Local turns. |
| `recipe-library.md` | shipped (v0.3.11) | Five bundled installable `PaceFlow` recipes under `Resources/recipes/`, install/uninstall via voice or Settings. |
| `trust-and-failures.md` | shipped (v0.3.11) | Visible undo banner after every reversible action, 30 s spoken-reply replay, plain-language `PaceFailureNarrator`. |
| `pace-v9-body-streaming-wiring.md` | partial (model-blocked) | Streaming `Mail.draft` detection/writes, `mailto:` first-draft setup, AX-first body writer, and launch-time Mail prewarm are wired; manual latency demo remains queued. |
| `pace-planner-v10-parameterized-actions.md` | partial (actionable) | Typed v10 envelope parsing, registry/artifact validation, deterministic schema fixture evals, local planner-output envelope/action rejection, legacy compatibility, and `Mail.draft` streaming are wired; grammar-constrained model-output gate and runtime-default model switch remain queued. |
| `pace-executor-surface.md` | partial (actionable) | Local dispatcher surface, v1 action mappings, destructive-only approval, `Shortcut.run` installed-name checks, Mail streaming with AX-first body writing, and AX mutation/undo scaffolds are wired; real-app/performance smokes remain queued. |
| `click-executor-improvements.md` | partial (actionable) | Improve click accuracy with midpoint targeting, foreground/window-aware top-K tiebreaks, recency hints, verification, and all-fail observations; manual ambiguity evals remain queued. |
| `hud-intent-disambiguator.md` | partial (actionable) | HUD route/progress state, panel option-click clarification resolution, local-only unsupported routing, and Reduce Motion cursor-overlay fallback are wired; visual target ambiguity and runtime smoke remain queued. |
| `whisperkit-streaming-asr.md` | partial (model-blocked) | Selectable WhisperKit provider scaffold with Apple Speech fallback, ASR status, contextual phrases, and runtime-wired LocalAgreement partial stabilization are wired; real WhisperKit streaming runtime remains queued. |
| `local-rag-layer.md` | partial (model-blocked) | JSON-backed BM25-style lexical retrieval over preferences/Pace history, built-in competitive research (Minimi, Dayflow, voice-assistant category), screen-watch + app-usage journals for time recall, Settings-selected explicit-root Spotlight files, and permission-aware Calendar/Reminders/Contacts/Notes/Mail data; vector store + bundled embedding model remain queued. |
| `local-vlm-runtime-port.md` | partial (model-blocked) | Screen-analysis provider abstraction and in-process placeholder are wired; real CoreML/MLX runtime remains queued. |
| `dictation-postproc-and-voice-edit.md` | partial (model-blocked) | Rule-backed dictation cleanup plus deterministic selected-text voice-edit scaffold; trained specialists remain queued. |
| `pace-planner-v8-deployment.md` | superseded | Runtime planner moved to off-the-shelf qwen3-30b-a3b (eval-validated); the v8 LoRA path is parked on the TinyGPT side. |
| `her-arc-roadmap.md` | planning | Meta roadmap that ordered the restraint/memory/listening/nudge/barge-in/replay PRDs and defines the arc's overall acceptance criteria. **Arc is now fully shipped.** |

## Ordering

The original "Her arc" ordering — restraint → memory → listening → nudges →
barge-in → replay — has all shipped as of v0.3.12. The remaining backlog
splits cleanly:

- **Actionable code work** (no model dependency): click executor manual ambiguity
  evals, HUD visual-target disambiguation, executor real-app smoke flow, v10
  grammar-constrained gate + runtime-default switch.
- **Model-blocked**: WhisperKit streaming runtime, in-process VLM runtime,
  trained dictation/voice-edit specialists, vector retrieval with bundled
  embedding model, v9 latency demo.

Do not treat a PRD as permission to broaden scope. Each implementation pass
should pick one PRD, satisfy its smallest useful acceptance slice, and run the
smallest relevant checks first.
