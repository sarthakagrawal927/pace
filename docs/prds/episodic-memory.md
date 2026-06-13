---
Status: shipped (v0.3.12)
owner: future Pace-repo agent
priority: P1 — "she remembers me" — biggest emotional jump
---

# PRD — Episodic Memory (fact extraction from turns)

## Goal

When the user says something durable about themselves or their world
("my mom is in the hospital", "we're shipping v1 on Friday", "I prefer
working in low light"), Pace should silently extract that fact and
recall it on relevant future turns. Today, Pace remembers raw
conversation history within a session and across sessions via
`paceHistory` retrieval (BM25 keyword search) — but it does not
extract semantic facts. That's the missing piece.

## Why now

Pace's "remembers me" surface today is brittle:

- `paceHistory` keyword retrieval misses paraphrases ("how's mom?"
  won't recall a turn that said "my mother got sick").
- `PaceLocalMemoryStore` stores explicit set-by-the-user preferences
  (preferred browser etc.) — not facts inferred from conversation.

Episodic memory closes the gap.

## Scope (v1)

After every completed turn whose intent was `pureKnowledge`,
`screenDescribe`, or `chitchat`:

1. Post-turn, run a fast secondary FM call on `(userTranscript,
   assistantSpokenText, frontmostAppName)`.
2. The FM call returns a small typed `PaceEpisodicFact` array — each
   fact has `subject`, `predicate`, `value`, `confidence`,
   `expiresAt?`, `topicHashtags`.
3. Facts with `confidence ≥ 0.7` are persisted as retrieval documents
   under a new `episodicMemory` source.
4. On future turns, retrieval includes the source by default —
   relevant facts join the `LOCAL CONTEXT` block.

Out of scope for v1: fact merging / dedup (just timestamp + replace
when same `(subject, predicate)` re-asserted), proactive recall
("how is your mom doing?" without being asked), forgetting on user
request.

## Architecture

### New file: `PaceEpisodicFact.swift` (~80 lines)

```swift
struct PaceEpisodicFact: Codable, Equatable {
    let identifier: String
    let extractedAt: Date
    let subject: String          // "user", "user's mom", "v1 launch"
    let predicate: String        // "is in", "happens on", "prefers"
    let value: String            // "the hospital", "Friday", "low light"
    let confidence: Double       // 0..1, from the extractor model
    let expiresAt: Date?         // nil = durable; set for "today only"
    let topicHashtags: [String]  // #family, #work, #preference
    let sourceTurnId: String?    // link back to paceHistory for audit
}
```

### New file: `PaceEpisodicFactExtractor.swift` (~250 lines)

- Uses `AppleFoundationModelsPlannerClient`'s `@Generable` path with a
  new envelope `PaceEpisodicFactExtractionResponse`. Apple FM is
  preferred over LM Studio here — extraction is short, latency-
  sensitive, and ships built-in.
- Falls back to LM Studio if FM unavailable (mirrors planner factory
  pattern).
- Hard prompt rule: extract **only durable facts** (multi-day relevance).
  Reject ephemera ("I'm hungry").

### Modify: `PaceLocalRetrieval.swift`

- Add `case episodicMemory` to `PaceRetrievalSource`.
- New retriever method
  `recordEpisodicFacts(_:turnId:)`.
- Facts persist as `PaceRetrievalDocument` with id
  `episodic-<uuid>`, text body `"<subject> <predicate> <value>"`, and
  topic hashtags in metadata for cheap topical recall.

### Modify: `CompanionManager.swift`

- After every turn whose intent was non-action and non-watch, fire
  `extractor.extract(transcript, assistantText, frontmostApp)` in a
  detached background task. Result writes through the retriever.
- TTS / planner pipeline is NOT blocked — extraction is fire-and-
  forget for latency.

### Modify: `PaceFMTurnResponse.swift`

- Possibly extend with an optional `extractedFacts: [...]` field if
  we want the main turn to extract inline (avoiding a second model
  call). Decision deferred — second call is cleaner separation but
  costs ~150ms per turn.

## Privacy posture

- All extraction is on-device. Apple FM is local; LM Studio is local.
  Zero network traffic in the extraction path.
- Facts are inspectable: a new Settings tab "Memory" lists facts,
  with delete-individual + delete-all buttons.
- Sensitive topic hashtags (#health, #finance, #relationship) get a
  visual lock indicator and are excluded by default from
  `paceHistory` injection — user must explicitly opt them in. This
  is the only place Pace voluntarily reduces its recall.

## Acceptance criteria

- [ ] Fixture turn "my mom is in the hospital with pneumonia"
      produces a fact with subject=user's mom, predicate=is in,
      value=hospital, confidence≥0.7.
- [ ] Fixture turn "I'm hungry" produces zero durable facts.
- [ ] On a follow-up turn 3 days later asking "how is my mom doing?",
      retrieval surfaces the fact in LOCAL CONTEXT.
- [ ] Settings → Memory shows extracted facts with timestamps.
- [ ] Delete-fact removes it from retrieval immediately + tombstones
      so re-extraction doesn't resurrect it for 30 days.
- [ ] No facts extracted when intent was a tool action ("open
      Safari") — silent.

## Testing strategy

- `PaceEpisodicFactExtractorTests` — 15 fixture turns × expected
  facts. Includes negative cases (ephemera, action turns).
- `PaceEpisodicRetrievalIntegrationTests` — extract + retrieve loop
  with the in-memory retrieval store.

## Risks

- **False memories.** An FM hallucination becomes a persisted fact.
  Mitigation: confidence floor, Settings → Memory lets the user
  audit + delete, max 200 facts retained (LRU eviction).
- **Embarrassing recall.** Pace says "how is your mom?" out of
  context. Mitigation: episodic facts are *available* to the planner,
  not auto-spoken. Proactive surfacing is its own PRD ([proactive
  nudges](proactive-nudges.md)).
- **Latency cost.** Extraction runs detached — acceptable.
- **Sensitive-topic exclusion may surprise the user.** Surface in
  Settings: "Sensitive topics are remembered but never auto-recalled
  without your asking."

## Effort estimate

~400 lines + the @Generable schema + tests. 2 days of focused work.
Blocks on no other PRD; can ship before always-listening.

Where in code: `leanring-buddy/PaceEpisodicFactExtractor.swift` (Apple FM `@Generable`
extractor + LM Studio fallback), `leanring-buddy/PaceEpisodicMemory.swift`
(dedup, tombstones, retrieval persistence + Settings inspect/delete surface).
