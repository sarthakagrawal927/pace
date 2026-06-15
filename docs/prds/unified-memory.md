---
Status: wired — Phases 1–5. Recall is now UNIFIED-ONLY (semantic-or-BM25 over one index that's a superset of turns + facts + every connector source). The parallel lexical recall path is retired. `PaceLocalRetrieval` is retained as the connector INGESTION layer the resync reads from; deleting that store outright (rewriting every connector to emit memory entries directly) is the one remaining follow-up.
owner: future Pace-repo agent
priority: P0 — "she knows me" — the coherence layer the memory subsystems were missing
---

# PRD — Unified Memory (one index, one write pass, one recall pass, one UI)

## Goal

Make Pace feel like it has **one memory** — a single "what Pace knows about
me and our conversation" — instead of four subsystems the user has to reason
about separately. Today memory is functionally rich but architecturally
fragmented: four stores, four write paths, four injection paths, four (or zero)
UI surfaces. From the user's seat and the planner's, that reads as incoherent
and, worse, as "it doesn't remember."

This PRD does **not** add a fifth system. It unifies the existing four behind a
single interface:

1. **One index** — every memory is a typed, timestamped, embedded entry in one
   store.
2. **One write pass** — after each turn: append the turn, extract durable
   facts, refresh the rolling summary → all into that index.
3. **One recall pass** — before each turn: always include the recent verbatim
   window, then **semantically** rank everything else and assemble ONE context
   block for the planner.
4. **One UI** — a single Memory view that shows and edits everything Pace
   knows.

## Why now

The four memory PRDs all shipped independently and work in isolation:
[conversational-thread-memory.md](conversational-thread-memory.md) (working
memory), [episodic-memory.md](episodic-memory.md) (durable facts),
[local-rag-layer.md](local-rag-layer.md) (deep recall + connectors), and
`PaceLocalMemoryStore` (explicit preferences). But they never cohered: a turn
writes to thread memory AND episodic AND paceHistory separately; recall pulls
from each with its own ad-hoc injection; and recall is **lexical (BM25)**, so
"how's my mother?" never surfaces "my mom is in the hospital" — no word overlap.
The user explicitly rejected the fragmented framing and asked for one system.

## The one principled distinction (kept as an implementation detail)

There is exactly one reason a thin internal tier survives: **latency**. The last
few turns must sit in the prompt on *every* call for free — a retrieval miss on
"what did I just say" is fatal. Everything else is a search run only when
relevant. So the unified store has two read strategies behind one interface:

- **Always-include window** — the last K turn pairs, verbatim, zero retrieval.
  (This is exactly today's `PaceThreadMemory.verbatimWindow()`, now persisted.)
- **Ranked recall** — semantic top-N over the rest of the index.

The user never sees these as separate systems. One `assembleContext()` call
returns one block.

## Architecture

### One index: `PaceMemoryIndex`

A single on-device store of `PaceMemoryEntry` values:

```
PaceMemoryEntry {
  id: String
  kind: .conversationTurn | .fact | .preference | .journalEvent | .summary
  text: String                 // the embeddable / injectable surface form
  structured: [String:String]? // fact triple (subject/predicate/value), pref key, etc.
  source: PaceRetrievalSource  // reuse existing enum (paceHistory, episodicMemory, …)
  createdAt: Date
  updatedAt: Date
  embedding: [Float]?          // filled lazily; nil until embedded
  confidence: Double?          // facts only
  topicTags: [String]          // #health/#finance/#relationship for sensitive-topic gating
  tombstonedAt: Date?          // soft-delete; excluded from recall, retained 30d
}
```

Persisted as a single JSON+vectors file under
`~/Library/Application Support/Pace/memory-index.*` (atomic write, same pattern
as `PaceThreadMemoryStore`). The existing per-source stores become **producers**
that write into this index; their bespoke persistence is migrated in, not kept
in parallel.

### One write pass: `PaceMemoryWriter.record(turn:)`

Replaces the scattered writes in `recordConversationTurn`. After each turn, in
one place: append the conversation-turn entry; run the existing pattern + FM
fact extractors and upsert facts (dedup on `(subject,predicate)`, tombstones,
sensitive-topic tagging — see [episodic-memory.md](episodic-memory.md)); roll
the displaced verbatim turn into the summary entry. Embedding is computed
lazily off the hot path (detached), so the user-facing turn never waits on it.

### One recall pass: `PaceMemoryRetriever.assembleContext(forQuery:)`

Replaces `appendLocalRetrievalContext` + the separate `injectionPrefix()`. One
call returns one `LOCAL CONTEXT` block:

1. Always-include: recent verbatim window + current rolling summary.
2. Ranked recall over the SINGLE unified index — TWO ranking modes, one store:
   **semantic** (embed the query via LM Studio `/v1/embeddings`, cosine-rank)
   when embeddings are available, else **lexical/BM25 over the same entries**.
   The retriever picks the mode; callers never see two systems. Take top-N
   within a token budget.
3. Sensitive-topic gate: `#health/#finance/#relationship` excluded unless the
   user opted in (`injectSensitiveEpisodicTopics`, already specced).

This is REPLACEMENT, not augmentation. When the unified retriever returns a
block it IS the context for the turn — the legacy lexical `PaceLocalRetrieval`
injection path is removed, not concatenated. "Lexical" survives only as the
fallback *scorer inside this one retriever*, never as a parallel store.

### Connectors become producers (the storage replacement)

The piece that makes replacement safe: the connectors
(calendar/mail/notes/reminders/contacts/spotlight + screen-watch/app-usage
journals) stop owning their own `PaceLocalRetrieval` buckets and instead write
`PaceMemoryEntry` rows (kind `.journalEvent`/`.preference`/etc.) into the unified
index. Once every source feeds the one index, the index is a true superset and
the parallel lexical store can be deleted — recall over the single index covers
everything the old dual path did, by meaning when embeddings are loaded and by
keyword when they aren't.

### One UI: PaceMainWindow → Memory

Promote `PaceMemorySettingsTab` / `PaceMemoryRetrievalSummaryView` into a
first-class Memory view: searchable list of everything Pace knows (facts,
preferences, recent turns, journal highlights), per-entry delete, topic chips,
and "Reset all memory." Styling mirrors `PacePrivacyDashboardView`.

## Decisions (the two scope questions, settled)

- **Embeddings → existing LM Studio `/v1/embeddings`.** Already wired and
  loopback-guarded via `PaceEmbeddingReranker`; fully on-device; **no new model
  dependency** (this is the key unlock — semantic recall ships now, it was only
  ever blocked on a *bundled* model, which stays a future TinyGPT swap). Any
  embedding failure degrades gracefully to the current lexical BM25 ranking.
- **Vector index → brute-force cosine in Swift for v1.** A persisted
  `[Float]`-per-entry index + in-memory cosine is plenty for the thousands of
  entries a single user accrues, and adds **zero native dependencies**.
  `sqlite-vec` becomes a drop-in scale optimization behind the same
  `PaceMemoryIndex` interface if entry counts ever demand it.
- **Migration → build alongside, then REPLACE (not parallel-forever).** The
  unified store ships next to the existing subsystems and dual-writes during
  transition (Phases 2–4, done). The end state is replacement: connectors become
  producers into the one index, the unified retriever gains a lexical ranking
  mode so it no longer needs the separate store as a fallback, and the legacy
  `PaceLocalRetrieval` injection path is deleted. The additive semantic+lexical
  concat shipped in Phase 4 is explicitly the TRANSITIONAL shim, not the target.

## Relationship to existing PRDs

This PRD **subsumes** the shipped memory PRDs into one store. Thread memory
becomes the always-include window; episodic becomes `.fact` entries; RAG/
connectors become `.journalEvent`/`.preference` *producers* into the unified
index; preferences become `.preference` entries. Those PRDs' behavior contracts
(dedup, tombstones, idle reset, secret-path exclusion) are preserved as
invariants of the producers. It **replaces** the lexical-only recall in
[local-rag-layer.md](local-rag-layer.md): the `PaceLocalRetrieval` BM25 store is
retired and its keyword scoring is reborn as the fallback ranking mode *inside*
the single unified retriever.

## Build plan (phased, app stays green throughout)

- **Phase 1 — the store.** `PaceMemoryIndex` + `PaceMemoryEntry` + persistence
  (`PaceMemoryStore`, atomic JSON+vectors). Pure, unit-tested round-trip. No
  wiring yet. *(Additive; ships dark.)*
- **Phase 2 — the write pass.** `PaceMemoryWriter`; dual-write from
  `recordConversationTurn` (existing stores still authoritative). Lazy detached
  embedding. Verify entries accrue with embeddings.
- **Phase 3 — the recall pass.** `PaceMemoryRetriever.assembleContextBlock`;
  embed query + cosine rank; behind `useUnifiedMemoryRecall` flag. *(Done —
  shipped default-on with additive lexical fallback as the transition.)*
- **Phase 4 — the UI.** Memory tab: smart-recall toggle, recall-index status,
  cascade-consistent delete/reset. *(Done.)*
- **Phase 5 — REPLACE the parallel system (the real unification).** Three steps:
  (a) give `PaceMemoryRetriever` a lexical/BM25 ranking mode over the unified
  index so it no longer falls back to the *separate* store; (b) migrate each
  connector (calendar/mail/notes/reminders/contacts/spotlight + journals) to
  write `PaceMemoryEntry` producers into the unified index, preserving their
  permission + secret-path + dedup invariants; (c) delete the legacy
  `appendLocalRetrievalContext` lexical branch and the standalone
  `PaceLocalRetrieval` store once the index is a verified superset. Sequenced so
  the app stays green at each step and recall never regresses.

## Test gates / acceptance

- `PaceMemoryIndexTests`: entry CRUD, tombstone exclusion, JSON+vector
  round-trip, cosine ranking order on fixtures.
- Semantic recall fixture: "my mom is in the hospital" recorded → query "how's
  my mother doing?" ranks that entry into context (lexical BM25 does not).
- Dedup/tombstone/sensitive-topic behavior preserved from episodic PRD.
- `scripts/test-pace.sh` stays green; no new failures vs. baseline.
- Manual: tell Pace 3 facts across a session → quit → reopen → all 3 recalled in
  a later turn; delete one in the Memory UI → it stops being recalled.

## Out of scope

- Bundled on-device embedding model (stays a TinyGPT swap; we use LM Studio's).
- `sqlite-vec` native store (v1 is brute-force cosine; swap later if needed).
- Cross-device sync (Pace is single-Mac, on-device by design).
