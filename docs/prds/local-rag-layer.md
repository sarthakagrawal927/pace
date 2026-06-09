# Local RAG layer

Status: partial (2026-06-09). Protocols, in-memory BM25-style lexical retrieval,
secret-path exclusions, explicit file connector, local preference/history
documents, explicit-root Spotlight file discovery, Settings file-root picker,
permission-aware Calendar, Reminders, Contacts, Notes, and Mail indexing,
Project Minimi competitive-research seed data, JSON-backed local persistence,
planner prompt injection, and panel/settings status are wired. Retrieval prompt
injection is route-aware so generic Q&A, screen-only reads, and follow-up agent
steps do not carry unrelated local context. SQLite/vector retrieval remains
queued.

## Goal

Let Pace answer and act using local user context without cloud calls:

- Mail messages.
- Notes.
- Files and folders.
- Calendar events.
- Reminders.
- Contacts.
- Recent Pace sessions and user preferences.
- Built-in competitive research snapshots.

The retrieval layer must stay local, fast, permission-aware, and small enough
to run continuously on a Mac.

Implementation note, 2026-06-09: `PaceLocalRetrieval` now defines the local
retrieval contract (`PaceRetrievalStore`, `PaceRetriever`,
`PaceRetrievalDocument`, `PaceRetrievalMatch`) and ships an in-memory BM25-style
lexical store. It indexes local preferences and recent Pace turns, formats compact
`LOCAL CONTEXT` blocks, and injects matches into text-only and full planner
prompts. Retrieval queries log timing and counts to the local metrics logger
without query text, excerpts, titles, or paths. A file connector exists for
explicit root URLs only and refuses sensitive paths before reading. `PaceSpotlightRetrievalConnector`
uses NSMetadataQuery to discover allowed text files only inside explicit roots
configured through `PaceLocalRetrievalFileRootPaths` UserDefaults or
`LocalRetrievalFileRootPaths` Info.plist; with no roots configured it records a
skipped File status rather than crawling the Mac. Settings now lets users add,
remove, and clear explicit retrieval folders; changing roots rebuilds the
Spotlight connector, clears stale file documents, and refreshes the File source
without an app restart. No broad background file crawl runs by default. The default store persists indexed
documents locally as JSON under Application Support so lexical context survives
app relaunches; SQLite remains the future vector-ready store. `PaceCalendarRetrievalConnector` indexes
nearby Calendar events through EventKit only after full Calendar access is
already granted; it never prompts from the retrieval path and reports denied or
write-only access as skipped source status. `PaceRemindersRetrievalConnector`
does the same for open reminders and recently completed reminders through
EventKit's reminder store. The panel/settings surfaces show retrieval source
counts and settings can reset the in-memory index. `PaceContactsRetrievalConnector`
indexes contact names, organizations, titles, nicknames, and email addresses
only after Contacts access is already granted. `PaceNotesRetrievalConnector`
maps Apple Notes into compact read-only retrieval documents through AppleScript
on user-triggered source refresh/reset, reporting Automation denial as skipped
status instead of failing retrieval. `PaceMailRetrievalConnector` does the same
for recent Apple Mail inbox messages. `PaceCompetitiveResearchSeeds` adds a
local Project Minimi snapshot covering its Claude/MCP ambient-memory wedge,
local vector-DB claims, Gemini embedding note, and Pace differentiation. The
BM25-style ranker prefers rare query terms and focused chunks over repeated
generic words, so the lexical fallback is materially closer to the future vector
path while the embedding model, SQLite store, and vector search remain queued.
Settings exposes source-level enable/disable and clear controls. Disabled sources
stay indexed locally until cleared, but are filtered from retrieval results and
Apple data refreshes do not read disabled sources.

## Why This Exists

Pace can see the screen and run local actions, but many useful requests refer
to context that is not on the current screen:

- "What did Priya say about the launch?"
- "Remind me about the thing from that email."
- "Open the deck I was editing yesterday."
- "Draft a reply saying yes to the latest note from John."

The planner should receive only the small retrieved facts needed for the turn,
not broad dumps of private local data.

## Scope

In scope:

- Local indexing pipeline.
- Permission-gated connectors for Apple/local data.
- Embedding-based semantic retrieval.
- Lightweight lexical fallback.
- Result snippets with source metadata.
- Planner prompt injection for top-K relevant facts.

Out of scope:

- Cloud search.
- Sync across devices.
- Full email client or file manager UI.
- Training an embedding model in Pace.
- Indexing secrets, env files, SSH keys, cloud credentials, kube configs, or
  production configs.

## Data Sources

| Source | Access Path | Notes |
|---|---|---|
| Mail | Mail data store or AppleScript/Spotlight fallback | Prefer read-only metadata and excerpts. |
| Notes | AppleScript or MCP-backed local server | Read-only first; write actions stay in executor. |
| Files | Spotlight / NSMetadataQuery | Implemented for explicit configured roots; respects ignored paths and secret exclusions. |
| Calendar | EventKit | First-pass indexed when full Calendar access is already granted; no retrieval-time prompt. |
| Reminders | EventKit | First-pass indexed when full Reminders access is already granted; no retrieval-time prompt. |
| Contacts | Contacts framework | First-pass indexed when Contacts access is already granted; no retrieval-time prompt. |
| Pace history | local app store | Store only user-approved local summaries. |
| Competitive research | built-in local seed documents | First seed covers Project Minimi from the 2026-06-09 site snapshot. |

## Index Design

Target architecture uses a local SQLite store:

- `documents`: stable id, source, title, path/url, timestamps, permission scope.
- `chunks`: document id, text excerpt, token count, source offsets.
- `embeddings`: chunk id, model id, vector.
- `access_log`: last indexed, last retrieved, error status.

Current implementation ships a JSON-backed BM25-style lexical store first. Use
SQLite-vec or an equivalent local extension once vector search is available,
keeping the vector interface behind a protocol.

## Embedding Model

Default candidates:

- `mxbai-embed-large` for quality.
- BGE-small class model for memory-constrained machines.

TinyGPT qualifies the model; Pace bundles or locates the local artifact and
runs it in-process. No embedding HTTP server in production.

## Retrieval Contract

Planner context should receive compact evidence:

```text
LOCAL CONTEXT
1. Mail from Priya, 2026-06-08, subject "Launch notes": "..."
2. Calendar event, today 3 PM: "Design review with Priya"
```

Each item includes:

- Source type.
- Title or subject.
- Date.
- Short excerpt.
- Stable local reference for follow-up action.

Do not include full documents unless the user explicitly asks to read one.

## Permission And Exclusion Rules

- Never index secrets, env files, SSH keys, cloud credentials, kube configs, or
  production configs.
- Respect app permissions. No silent permission prompts in the middle of a
  turn unless the user requested the source.
- Allow source-level disable switches. Implemented.
- Provide reset-index and source-specific clear controls in settings.
- Keep excerpts local and avoid analytics.

## Latency Targets

| Operation | Target |
|---|---|
| Query embedding | <= 80 ms warm. |
| Top-K retrieval | <= 80 ms for normal local corpus. |
| Prompt context assembly | <= 20 ms. |
| Background incremental index | Opportunistic; never blocks PTT. |

## Implementation Slice

1. Define `PaceRetrievalStore` and `PaceRetriever` protocols. Implemented.
2. Implement a file/Spotlight connector first. Implemented for the lexical
   slice: explicit file-root connector, explicit-root Spotlight/NSMetadataQuery
   discovery, and Settings root-picker controls are wired.
3. Add lexical retrieval and a no-vector fallback. Implemented with BM25-style
   query-time ranking.
4. Add vector retrieval once the local embedding runtime is qualified.
5. Inject top-K context only for `answer`, `action`, and `edit` turns that need
   off-screen context. Implemented for the lexical layer: prompt injection now
   requires an explicit off-screen/local reference, skips generic Q&A and
   screen-only reads, and runs only on the first planner step.
6. Add permission-aware Apple data connectors. Partial: Calendar, Reminders,
   Contacts, and user-triggered Notes/Mail indexing are implemented.

## Tests

Unit tests:

- Secret path exclusion.
- Chunking stability.
- Permission-denied source is skipped with a clear status.
- Lexical retrieval returns expected snippets.
- Prompt context caps at configured item and token limits.

Current coverage: `PaceLocalRetrievalTests` covers secret path exclusion,
stable chunking, lexical snippet retrieval, BM25-style rare-term ranking,
prompt context caps, query-latency
bookkeeping, JSON persistence/reset behavior, source-disable filtering, route-aware
context-injection policy, source-specific persisted clearing, and explicit file
connector sensitive-path skipping, file-root preference normalization/merge
behavior, and injected Spotlight candidate filtering inside explicit safe roots.
It also covers Calendar snapshot-to-document formatting and write-only Calendar
permission skipping, plus Reminders
snapshot-to-document formatting and write-only Reminders permission skipping.
Contacts formatting and denied permission skipping are also covered. Notes and
Mail snapshot formatting plus AppleScript-output parsing are covered without
running AppleScript in tests. Built-in competitive-research seed retrieval is
covered for Project Minimi, including source-disable filtering.

Manual tests:

- "Open the deck I edited yesterday."
- "What did Priya say about launch?"
- "Remind me from the latest email about taxes."
- "Search my notes for roadmap."

## Done When

- A local index can be built and reset without cloud calls. Partial:
  JSON-backed lexical persistence supports reset/upsert and repopulates
  Calendar/Reminders/Contacts if already authorized and can refresh Notes/Mail
  and explicit-root Spotlight files on a user-triggered reset/source enable;
  SQLite/vector reset is queued.
- At least one source is useful end-to-end in planner context. Partial:
  preferences, recent Pace history, authorized Calendar events,
  Reminders/Contacts, refreshed Notes/Mail, and the built-in Project Minimi
  competitive snapshot are injected when matched.
- Secret exclusions are covered by tests. Implemented for the lexical/file
  connector slice.
- Retrieval latency is measured and logged locally. Implemented for lexical
  retrieval via `PaceTelemetryLog` with timing/counts only.
- Settings exposes source status and reset controls. Implemented for the
  in-memory lexical index, including source enable/disable, clear controls, and
  explicit file-root picker controls.

## References

- `docs/architecture.md`
- `leanring-buddy/PaceLocalMemoryStore.swift`
- `leanring-buddy/PaceSpotlightRetrievalConnector.swift`
- `leanring-buddy/PaceCalendarRetrievalConnector.swift`
- `leanring-buddy/PaceRemindersRetrievalConnector.swift`
- `leanring-buddy/PaceContactsRetrievalConnector.swift`
- `leanring-buddy/PaceNotesRetrievalConnector.swift`
- `leanring-buddy/PaceMailRetrievalConnector.swift`
- `leanring-buddy/PaceCompetitiveResearchSeeds.swift`
- `leanring-buddy/PaceToolRegistry.swift`
- `leanring-buddy/PaceSettingsWindow.swift`
