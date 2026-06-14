# What Pace Can Do

Pace's abilities split into two layers: **tools** (discrete actions it executes)
and **capability classes** (whole behaviors that aren't single tools). The tools
are the canonical, drift-checked list; the classes are the surrounding system.

`docs/architecture.md` is the system map. This page is the user-facing "what can
I ask it" reference.

## Tools (the action catalog)

The 28 local tools live in `PaceToolRegistry.localTools` and are surfaced,
auto-generated, in **PaceMainWindow → Skills** (every tool has a name, an
example utterance, and a risk badge). Startup validation refuses to launch if
any tool lacks an example utterance, so the Skills tab can never go stale.

Grouped:

- **Screen control** — click, double-click, scroll, type text, press keys, snap window
- **Apps & web** — open app (`open_app`), open URL (`open_url`), open Messages, open/reveal in Finder
- **System** — volume, brightness, Music control, read clipboard, undo last edit
- **Productivity** — Calendar read/create, reminders, Apple Notes (create/append/search), Mail draft, Things to-do, run a Shortcut
- **Text editing** — dictate into the focused field, voice-edit selected text ("make this more concise")
- **Utility** — start a timer, download a file to ~/Downloads, record/run a saved flow, call an MCP tool

Multi-action commands ride in a single planner response (the v10 envelope's
`payload.calls`), not across multiple turns — see
[conversation-model.md](conversation-model.md) for why.

## Capability classes (beyond tools)

**Understanding the screen** — describe what's on screen, answer questions about
it, point the cursor at / click a named element. Backed by the local VLM +
OCR + AX tree (`PaceScreenContextService`).

**Knowledge & chitchat** — pure-knowledge questions ("what is HTTP?") route to a
fast text-only planner with no screen capture; chitchat gets a canned instant
reply. Routing is `PaceIntentClassifier`.

**Memory** — three distinct layers:
- *Durable preferences* — "remember my preferred browser" (`PaceLocalMemoryStore`)
- *Episodic memory* — lasting facts extracted from turns, surfaced across sessions
- *Conversational thread memory* — this-conversation coherence (see [conversation-model.md](conversation-model.md))

**Time / journal recall** — "what did I do today?" answers from the screen-watch
and app-usage journals (`PaceScreenWatchJournal`, `PaceAppUsageJournal`).

**Local retrieval (RAG)** — grounds answers in your own Calendar, Mail, Notes,
Contacts, Reminders, explicitly-chosen file folders, and past Pace turns
(`PaceLocalRetrieval`). Each source is permission-aware and individually
toggleable; nothing is crawled without an explicit root.

**Modes** — push-to-talk (the floor), always-listening / "hey pace" wake word,
barge-in (interrupt mid-speech by speaking), watch mode (observe the screen and
emit change events), in-window chat (text instead of voice).

**Proactive surfaces (all default OFF)** — posture watch, focus-fatigue nudges,
calendar pre-meeting nudges, watch-mode observation nudges, the weekday morning
brief. Every one flows through `PaceRestraintGate` (stays silent during a
call / when you're actively typing).

**External integrations (MCP)** — anything a configured Model Context Protocol
server exposes. Configured via `~/.config/pace/mcp-servers.json` or the one-tap
catalog in Settings → MCP (filesystem, fetch, github, applescript, slack, linear).

**Entry points** — voice (PTT/wake word), text (chat), and `pace://` deeplinks
(`listen`, `chat`, `watch`, `panel`) from Raycast / Shortcuts.

## What stays on-device

Everything above is local. The only off-device action is `download_file`, which
fetches a user-named http(s) URL into ~/Downloads on explicit command — and the
opt-in cloud-bridge / Direct-API planner tiers, which are consent-gated and
default-off. See `docs/architecture.md` for the privacy posture.

## How a command is routed (fastest → slowest)

1. **Fast path** (`PaceFastActionCommandParser`) — deterministic, no model, no
   screen: open app/URL/known site, media, volume, brightness, undo, window
   snap, common key shortcuts. Sub-200ms.
2. **Text-only planner** — pure-knowledge answers, no screen capture.
3. **Screen pipeline** — VLM + planner, for commands that genuinely need to see
   or act on the screen. The VLM is skipped for launch/navigate verbs that don't
   reference an on-screen element (see `PaceTagParsers.transcriptIsLikelyScreenReferential`).

The Settings → Debug tab shows, per turn, which lane handled it, the latency,
the raw planner output, the parsed tool calls, and the dispatch outcome.
