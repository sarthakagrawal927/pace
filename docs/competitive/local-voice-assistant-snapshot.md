# Local Voice Assistant Category Snapshot

Fetched: 2026-06-10
Sources: dottie.ai, OpenFelix README, Pace `docs/landing/v1-draft.md`, user
`assistant` repo ideas (2026-04)

## Category Definition

"Private voice assistant for Mac" products combine menu-bar presence, push-to-talk
or wake-word input, speech-to-text, a planner/agent loop, optional screen vision,
text-to-speech, and macOS tool execution. Representative apps:

- **Dottie** — menu-bar coworker; Fn push-to-talk dictation at cursor; "Hey Dottie"
  wake word; MLX Kokoro TTS; agent mode with large tool surface; `dottie://` URL
  schemes for Shortcuts (`record`, `chat?text=`, `type?text=`).
- **OpenFelix** — open-source Swift menu-bar agent; Option+Space voice/text;
  local MLX models plus optional cloud models; screen vision, cron, proactive
  Telegram/Discord alerts.
- **Wispr Flow** — cloud round-trip dictation; privacy is policy-based, not
  architectural.

Pace sits in this category but commits to **fully on-device** speech, vision,
reasoning, and TTS with LM Studio loopback planners and Apple Speech STT.

## Common UX Patterns

- Menu-bar or notch capsule (no dock icon).
- Hold-to-talk global shortcut with audio-reactive UI.
- Streaming TTS so the assistant speaks before the full response completes.
- Settings for permissions (mic, speech, accessibility, screen recording).
- Scriptable automation via custom URL schemes.

## User Assistant Repo Ideas (product north star)

The user's `sarthakagrawal927/assistant` prototype (Vite chat UI + FastAPI
DeepSeek tool loop) captured early product ideas that extend beyond chat:

- **Privacy-first memory** — the assistant only knows what the user chooses to
  expose; visualize captured vs locked context.
- **Proactive assistants** — agents that can ping the user when something matters
  (OpenFelix's proactive alerts are the closest shipped analogue).
- **Multi-expert routing** — complex queries delegate to specialist assistants
  (Pace's intent classifier + tool registry are a local-first slice of this).

The web prototype is not integrated (frontend stub, in-memory todos backend) and
uses cloud DeepSeek — not the Pace runtime path.

## Pace Relevance

Pace already matches the voice-assistant shell: PTT, streaming TTS, planner
tool loop, screen context, MCP bridge, approval gates, and menu-bar panel.

Gaps vs category leaders:

| Pattern | Dottie / OpenFelix | Pace today |
| --- | --- | --- |
| `dottie://` / scriptable URLs | Yes | Not yet |
| Wake word | Dottie | Not yet |
| Dictation-at-cursor only mode | Dottie PTT-to-type | Agent-first pipeline |
| Proactive outbound alerts | OpenFelix cron/alerts | Watch mode only |
| Cloud model option | Optional upgrade path | Intentionally removed |

Pace differentiation to keep: **no cloud LLM/STT/TTS path**, **AX-first local
actions**, **eval-gated planner**, and **loopback-only model endpoints** guarded
by `PaceLocalEndpointGuard`.

Convergence path: add `pace://` deeplinks, optional dictation-only fast path, and
proactive notifications tied to watch-mode or retrieval triggers — without
re-opening cloud model transport.
