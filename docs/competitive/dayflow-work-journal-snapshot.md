# Dayflow Work Journal Snapshot

Fetched: 2026-06-10
Source: https://github.com/JerryZLiu/Dayflow (README, dayflow.so)

## Product Positioning

Dayflow is a native macOS SwiftUI app that builds a **private, automatic work
journal** from screen activity. It records lightweight screen chunks, analyzes
them with a user-chosen AI provider, and turns the day into labeled activity
cards on a visual timeline. Marketing emphasizes "stop guessing where your time
went" and open-source MIT licensing.

## Core Workflow

1. Grant Screen & System Audio Recording permission.
2. Dayflow captures screen activity at low FPS (README: ~1 FPS, 15-second chunks).
3. Every ~15 minutes, recent footage is sent to the configured AI for analysis.
4. The app synthesizes timeline cards with concise summaries (not just app names).
5. Users browse the timeline, run daily standup / weekly review views, export
   Markdown, and chat with the journal in natural language.

## AI Provider Options

- **Local**: Ollama or LM Studio (analysis can stay on-device).
- **Cloud BYO key**: Gemini API.
- **CLI subscriptions**: ChatGPT (Codex CLI) or Claude (Claude Code CLI) for
  frontier narrative quality.

If a cloud or CLI provider is selected, activity data needed for analysis leaves
the Mac for that provider. Local model mode keeps analysis on-machine.

## Privacy And Storage

- Data lives under `~/Library/Application Support/Dayflow/` by default.
- Open source (MIT) — users can verify handling in code.
- Automatic cleanup / storage limits are configurable.
- URL scheme automation: `dayflow://start-recording`, `dayflow://stop-recording`
  for Shortcuts, Raycast, and hotkey launchers.

## Pace Relevance

Dayflow owns the **ambient screen memory + work journal** wedge. Pace owns
**voice-first real-time assistance + local tool execution**. Overlap:

| Capability | Dayflow | Pace today |
| --- | --- | --- |
| Screen capture | Continuous low-FPS journal | On-demand + watch-mode diff events |
| AI analysis | Batch timeline cards every ~15 min | Per-turn VLM + planner on PTT |
| Chat with history | Journal Q&A over timeline | Conversation history + local RAG |
| Local LM Studio | Supported provider | Default planner/VLM path |
| macOS automation | URL scheme start/stop recording | Tool/MCP execution, no `pace://` yet |
| Proactive loop | Passive journal | Watch mode + future proactive pings |

Pace should preserve differentiation: **zero cloud by architecture** (no Gemini
default, no cloud embeddings), **sub-second voice loop**, and **agent actions**
(click, type, Mail drafts, Calendar, MCP). Dayflow does not ship voice control or
macOS action execution.

Convergence path for Pace (not parity): persist watch-mode / screen-context
snapshots into retrieval, add timeline-style "what did I do today?" answers from
local history, and expose `pace://` deeplinks for Shortcuts parity with Dayflow
and Dottie.
