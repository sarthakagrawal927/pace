---
Status: shipped (v0.3.11)
owner: future Pace-repo agent
priority: P1 — conversational quality bedrock
---

# PRD — Conversational Thread Memory (rolling summary + verbatim window)

## Goal

Make Pace feel like one continuous conversation across a 30-minute
back-and-forth without the planner losing earlier turns. Today the
planner only sees the last N raw turns. Anything older silently falls
off and the user experiences Pace "forgetting" what they said five
minutes ago — even though the information lived in the same session.

This PRD specifies a **two-tier in-context memory** that ships on
every planner call:

1. A **verbatim window** of the last K turns (K=4 default) inlined as
   conventional `messages` history.
2. A **rolling summary** — a compact paragraph that summarizes
   everything BEFORE the verbatim window. Updated incrementally
   after each completed turn by a small on-device FM call that
   takes `(prior summary, new turn pair)` and outputs
   `(updated summary)`.

The summary is injected into the system prompt as a leading
addendum: `<conversation_so_far>...</conversation_so_far>`. Token
budget capped (~400 tokens) so it never blows up the planner input.

## Why now / boundary vs episodic memory

Pace already has two memory layers and is about to add a third:

| Layer | Lifetime | Granularity | Purpose | Lives in |
|---|---|---|---|---|
| Verbatim history window | Current session, last K turns | Raw turn pairs | Exact recent context for the planner | `CompanionManager.conversationHistory` (today) |
| **Rolling thread summary** *(this PRD)* | Current session, ephemeral | Compressed paragraph of older turns | Session continuity past K | New: `PaceThreadMemory` |
| Episodic facts ([episodic-memory.md](episodic-memory.md)) | Durable, cross-session | Atomic `(subject, predicate, value)` rows | Long-term recall ("how is your mom?") | `PaceLocalRetrieval` `episodicMemory` source |

The boundary is intentional and load-bearing:

- **Thread memory is session-scoped and ephemeral.** It dies when the
  conversation cools. It does not survive a restart. It is never
  written to disk. Its job is "stay coherent for 30 minutes."
- **Episodic memory is durable and atomic.** It survives sessions,
  is user-auditable in Settings, and is retrieved by content
  relevance — not by being "the same conversation."

The two layers compose, they do not overlap:

- A 30-minute conversation about debugging a Swift bug generates a
  thread summary like "the user is debugging an actor-isolation
  warning in `PaceActionExecutor`, has tried marking the closure
  `@MainActor`, and is now investigating the call site." That
  summary is discarded once the user walks away.
- The same conversation might leave behind a single durable
  episodic fact like "user prefers verbose comments in
  `PaceActionExecutor`" if they explicitly said so — that fact
  persists.

Thread memory is the **cheaper, lower-stakes** layer between literal-
recent-turns and durable-fact-extraction. Episodic memory cares about
*what to remember forever*; thread memory cares about *what to recall
right now*. Episodic memory must be precise (false memories are
embarrassing); thread memory only has to be roughly right (a slightly
imperfect summary is invisible to the user as long as the planner
stays on-topic).

This boundary also dictates the model choice: episodic extraction
uses a typed `@Generable` envelope and a high confidence floor; thread
summarization uses a free-form 1-paragraph response and tolerates
drift because it gets refreshed every turn.

## Scope (v1)

In scope:

- A pure `PaceThreadMemory` module that holds verbatim window + the
  current summary, advances the window when full, and tracks the
  session-idle clock.
- A `PaceThreadSummarizer` that incrementally updates the summary
  via Apple Foundation Models (LM Studio fallback).
- Detached after-turn summarization (mirrors the episodic-extractor
  pattern). User-facing turns never wait on summarization.
- Injection into every planner call as a leading
  `<conversation_so_far>` block in the system prompt.
- Session boundary on idle (default 20 minutes). At session end:
  drop the summary and verbatim window; the next turn starts fresh.
- Settings → Memory → Thread summary section with enable toggle,
  idle-minutes picker, "Reset thread" button, and a debug view that
  reveals the current summary text.

Out of scope for v1:

- Persisting the summary across restarts (intentional — see Privacy).
- Cross-session linking ("you started this yesterday").
- Per-topic threads (one summary per session, no branching).
- Using the summary to seed retrieval re-ranking.
- Bridge upstream summarizer support (Apple FM + LM Studio only).
- A token-counter ladder that aborts a planner call if summary + K
  exceeds a hard budget; v1 caps the summary length at the
  summarizer level and trusts the planner's own truncation.

## Architecture

### New file: `leanring-buddy/PaceThreadMemory.swift` (~200 lines)

Pure module. No AppKit, no async, no Apple FM. Holds the in-memory
state and exposes a small testable API.

```swift
struct PaceThreadMemoryConfiguration: Equatable {
    let verbatimWindowSize: Int            // default 4 turn pairs
    let sessionIdleThreshold: TimeInterval // default 20 * 60
    let summaryMaxTokenEstimate: Int       // soft cap, default 400
}

struct PaceThreadTurnPair: Equatable {
    let turnId: String
    let userText: String
    let assistantText: String
    let recordedAt: Date
}

enum PaceThreadSessionEndCause: Equatable {
    case idleTimeout
    case userReset
}

@MainActor
final class PaceThreadMemory {

    init(configuration: PaceThreadMemoryConfiguration = .default)

    /// Append a completed turn pair. Slides the verbatim window if
    /// it overflows; the displaced pair becomes part of the next
    /// summarization input.
    func record(userTurn: String,
                assistantTurn: String,
                turnId: String,
                now: Date) -> PaceThreadTurnPair?
    // Returned pair (if any) is the one that just fell off the
    // verbatim window and should now be folded into the summary.

    /// The leading addendum injected into the system prompt:
    ///   `<conversation_so_far>summary text</conversation_so_far>`
    /// Returns nil when there is no summary yet (first K turns of a
    /// session).
    func injectionPrefix() -> String?

    /// The verbatim window in the order the planner expects.
    func verbatimWindow() -> [PaceThreadTurnPair]

    /// Update the held summary once `PaceThreadSummarizer` finishes.
    /// Out-of-order updates are dropped (compare against the
    /// monotonically-increasing `summaryVersion`).
    func applySummaryUpdate(summary: String,
                            summaryVersion: Int,
                            updatedAt: Date)

    /// Returns a session-end cause iff the idle threshold elapsed.
    /// Caller invokes on every turn start + via a low-frequency
    /// timer.
    func sessionDidIdle(now: Date) -> PaceThreadSessionEndCause?

    /// Explicit reset (Settings button or session-end). Clears
    /// summary + verbatim window. Bumps `sessionId`.
    func resetSession(cause: PaceThreadSessionEndCause, now: Date)

    /// The current session's identifier (used by `paceHistory`
    /// journaling and audit). Bumped on every reset.
    var currentSessionId: String { get }
}
```

Internal state: `currentSummary: String?`,
`currentSummaryVersion: Int`, `verbatimWindow: [PaceThreadTurnPair]`,
`lastTurnRecordedAt: Date?`, `currentSessionId: String`.

This file owns no I/O. It is what `PaceThreadMemoryTests` exercises
end-to-end.

### New file: `leanring-buddy/PaceThreadSummarizer.swift` (~250 lines)

Owns the FM call that produces an updated summary. Detached.

```swift
struct PaceThreadSummarizerInput {
    let priorSummary: String?         // nil for the first compaction
    let displacedTurnPair: PaceThreadTurnPair
    let sessionStartedAt: Date
    let frontmostAppName: String?     // optional contextual hint
}

protocol PaceThreadSummarizerClient {
    func updatedSummary(for input: PaceThreadSummarizerInput) async throws -> String
}

final class PaceThreadFoundationModelSummarizer: PaceThreadSummarizerClient {
    // Uses the same @Generable path as AppleFoundationModelsPlannerClient.
    // Returns a single compact paragraph. Falls back to
    // LM Studio /v1/chat/completions when Apple FM is unavailable.
}
```

Prompt rules (formalized in the file as constants so they diff
cleanly):

- "You are compressing a voice conversation between the user and
  Pace, an on-device macOS assistant."
- "Given a PRIOR_SUMMARY (may be empty) and a NEW_TURN, produce an
  UPDATED_SUMMARY of at most 4 sentences."
- "Preserve durable facts about user state, current task, and any
  pending intent the user expressed."
- "Drop social filler, repeated greetings, action-tag noise."
- "Write in third person, present tense. Do not invent details."
- "Never exceed 400 tokens."

Latency target: ≤300ms warm. The call is fire-and-forget — the user-
facing planner turn does not block on it. The summarizer holds a
`summaryVersion: Int` counter and tags each output; if two
summarizer calls finish out of order, `PaceThreadMemory.applySummaryUpdate`
drops the older one.

The `@Generable` envelope is single-field:

```swift
@Generable
struct PaceThreadSummaryResponse {
    @Guide(description: "Updated rolling summary, ≤4 sentences, third person.")
    let updatedSummary: String
}
```

### Modify: `leanring-buddy/CompanionManager.swift`

Three additions:

1. **Hold a `threadMemory: PaceThreadMemory` instance.** Created on
   `start()`. Configuration loaded from `PaceUserPreferencesStore`.
2. **After every completed turn**, regardless of intent, call:

   ```swift
   let displacedPair = threadMemory.record(
       userTurn: ...,
       assistantTurn: ...,
       turnId: ...,
       now: Date()
   )
   if let displacedPair {
       Task.detached(priority: .utility) {
           let updated = try await summarizer.updatedSummary(for: ...)
           await threadMemory.applySummaryUpdate(...)
       }
   }
   ```

   Mirrors the episodic-fact-extractor pattern. **Never `await`ed
   on the user-facing path.**
3. **Before every planner call**, prepend
   `threadMemory.injectionPrefix()` to the system prompt (when
   non-nil) AND populate the planner's `conversationHistory` with
   `threadMemory.verbatimWindow()` instead of the existing ad-hoc
   list. Existing `conversationHistory` field on
   `CompanionManager` becomes a thin facade over `threadMemory`.
4. **Idle gate**: on every turn start, call
   `threadMemory.sessionDidIdle(now: Date())`. If non-nil, call
   `resetSession(cause: .idleTimeout, ...)` first, then proceed.
   Also run the same check from a low-frequency timer (every 5 min)
   so the menu-bar surface can drop "session live" indicators
   without needing a new turn.

### Modify: `leanring-buddy/CompanionSystemPrompt.swift`

Formally support an injected `<conversation_so_far>` block. The
system-prompt builder gains a new optional parameter
`threadSummaryInjection: String?`. When provided, the builder emits:

```
<conversation_so_far>
{threadSummaryInjection}
</conversation_so_far>

<tools>
... existing tool docs ...
</tools>

<rules>
... existing rules ...
</rules>
```

The wrapper tags are stable and documented — both the prompt and
the v10 schema fixtures will reference them so drift fails fast.

### Modify: `leanring-buddy/BuddyPlannerClient.swift`

`BuddyPlannerRequest` gains one optional field:

```swift
var threadSummaryInjection: String?
```

Each conformer (`LocalPlannerClient`, `AppleFoundationModelsPlannerClient`,
`HybridPlannerClient`, `CloudBridgePlannerClient`) reads this field
and concatenates it onto the system prompt at request-build time.

**Important**: the verbatim window is still passed via the existing
`conversationHistory: [BuddyConversationTurn]` field. The summary
and the window are passed as **separate** parameters; the request
builder is the only place they get combined. This keeps the
summary out of `conversationHistory` (which is also written to
`paceHistory` retrieval) so the summary doesn't double-count
itself as recall material.

### Modify: `leanring-buddy/PaceUserPreferencesStore.swift`

Add keys:

- `isThreadMemoryEnabled` (Bool, default `true`)
- `threadMemoryVerbatimWindowSize` (Int, default `4`, clamp 1…8)
- `threadMemoryIdleMinutes` (Int, default `20`, clamp 5…60)
- `isThreadMemoryDebugViewEnabled` (Bool, default `false`)

### Modify: `leanring-buddy/PaceSettingsWindow.swift`

New "Thread summary" subsection inside the existing **Memory** tab,
rendered ABOVE the existing episodic-memory subsection (or
side-by-side under one Memory header). Contents:

- Toggle: "Remember this conversation". Disabling immediately
  resets the session and prevents new summarization until re-
  enabled.
- Verbatim window picker (1–8 turn pairs). Tooltip explains "How
  much exact context the planner sees before falling back to a
  summary."
- Idle threshold picker (5–60 minutes).
- "Reset thread now" button — calls
  `threadMemory.resetSession(cause: .userReset, now: Date())`.
- Toggle: "Show current summary" (default off). When on, an
  expandable text block shows the live summary text and the
  `summaryVersion` counter. This is a debug/transparency surface,
  not a daily-use UI.

### Modify: `leanring-buddy/AGENTS.md` (== `CLAUDE.md`)

In the architecture / Planner section, add a paragraph after the
existing planner description:

> **Two-tier in-context memory**: every planner call carries the
> last K turns verbatim (`PaceThreadMemory.verbatimWindow()`) AND
> a rolling summary of everything older (`injectionPrefix()`,
> rendered into the system prompt as `<conversation_so_far>...
> </conversation_so_far>`). The summary is refreshed by a detached
> Apple FM call after each turn; the user-facing path never
> blocks on summarization. Session-scoped and ephemeral — drops
> on a 20-minute idle threshold or via Settings → Memory → Reset
> thread. Durable facts go through episodic memory instead. See
> PRD: `docs/prds/conversational-thread-memory.md`.

Also add Key Files rows for `PaceThreadMemory.swift` and
`PaceThreadSummarizer.swift`.

## Latency budget detail (the race)

The summarizer runs detached. There is therefore a race: the user
fires turn N+1 before the summarizer finishes the update triggered
by turn N. Spec for that race:

- The planner for turn N+1 sees the **stale** summary (last
  completed update, i.e. covering turns ≤N−1).
- The new pair (N) is still in the verbatim window — it has not
  been displaced yet, so the planner sees it inline.
- The summarizer running for turn N completes asynchronously and
  calls `applySummaryUpdate`. If the user has already fired turn
  N+2 by then (which may itself have displaced N from the
  verbatim window), the summarizer call for N+1 — kicked off by
  turn N+2 — runs against the now-current summary.
- Out-of-order arrivals are handled by `summaryVersion`: each
  detached summarization call tags its result with a monotonically
  increasing version snapshot captured BEFORE the FM call. If
  `applySummaryUpdate` receives a version older than what
  `PaceThreadMemory` already holds, it drops the update.

This is acceptable because the verbatim window — not the summary —
is the source of truth for the last K turns. The summary's job is
to keep memory of older turns; slight staleness in compression of
older turns doesn't degrade nearby coherence.

Hard rules:

- The user-facing planner turn MUST NOT await summarization.
- Summarization MUST NOT be triggered synchronously from
  `record(...)`. `CompanionManager` is the only place that kicks
  the detached task.
- If summarization fails (FM unavailable, LM Studio down, parser
  reject), the failure is logged and the prior summary stays.
  No retry storm.

## Session-end behavior

When `sessionDidIdle(now:)` returns non-nil OR the user clicks
"Reset thread":

1. Drop the verbatim window.
2. Drop `currentSummary`.
3. Bump `currentSessionId`.
4. Append a single line to `paceHistory` retrieval:
   `"session ended (cause: idleTimeout|userReset)"` with the
   session id, so "what did we talk about earlier?" can recall via
   the existing keyword retriever.

**Optional bridge to episodic memory** (off by default, behind a
new `isThreadEndingEpisodicHandoffEnabled` preference):

If enabled, on session end the **final** summary is fed to the
episodic fact extractor ([episodic-memory.md](episodic-memory.md))
as a single document. The extractor decides whether anything in
the summary deserves to become a durable fact. The summary itself
is NOT persisted — only any facts the extractor surfaces.

This handoff is opt-in because the summarizer is allowed to be
loose; the episodic extractor is precise; coupling them risks
producing low-confidence facts. Default off. If the user opts in,
the extractor's confidence floor (≥0.7 per the episodic PRD)
remains the floor — the handoff just gives the extractor one more
document to consider.

## Privacy posture

- Entirely on-device. Apple FM runs in-process. LM Studio
  fallback is loopback-guarded by `PaceLocalEndpointGuard`.
- Summary text lives only in process memory. **Never persisted to
  disk**, never written to UserDefaults, never journaled to
  `paceHistory` (the line that journals to paceHistory is the
  *session-id and cause*, not the summary content).
- Session identifier IS journaled to `paceHistory` for audit so
  the user can grep "session abc123" across history.
- Settings → Memory → "Show current summary" is the only surface
  that exposes the summary text. Off by default.
- `Reset thread now` is irreversible by design — there is no undo.

## Acceptance criteria

- [ ] All existing tests still pass via `bash scripts/test-pace.sh`.
- [ ] New `PaceThreadMemoryTests` cover: verbatim window slides on
      record, returned displaced pair matches what fell off,
      `injectionPrefix()` returns nil before any displacement,
      `injectionPrefix()` returns the wrapped block after update,
      out-of-order `applySummaryUpdate` is dropped,
      `sessionDidIdle` fires only after the threshold,
      `resetSession` clears state and bumps `sessionId`.
- [ ] New `PaceThreadSummarizerTests` use a fake FM client and
      assert deterministic update construction (prompt assembly,
      response decoding, error fallback).
- [ ] New `PaceThreadMemoryIntegrationTests` simulates a 10-turn
      synthetic conversation, asserts the summary roughly captures
      the trajectory (string-contains spot checks for canonical
      keywords introduced in early turns and absent from the
      verbatim window).
- [ ] Settings → Memory → Thread summary renders. Toggles persist
      across restart. "Reset thread now" clears the live state.
- [ ] On the 5th turn of a session with K=4, the planner request
      includes a non-nil `threadSummaryInjection` that mentions
      content from turn 1.
- [ ] User-facing turn latency does not regress (TTFSW benchmark
      via `scripts/benchmark_ttfsw.sh` shows no statistically
      meaningful delta — summarization is detached).
- [ ] Default is ON. Users get the benefit without opting in.

## Testing strategy

- `PaceThreadMemoryTests` (pure, fast). The bulk of the coverage
  lives here because the module is intentionally I/O-free.
- `PaceThreadSummarizerTests` exercise the prompt-assembly and
  response-decoding code with a fake `PaceThreadSummarizerClient`.
- `PaceThreadMemoryIntegrationTests` use the fake summarizer plus
  a synthetic 10-turn fixture (`evals/thread-memory-fixtures/...`)
  to validate end-to-end trajectory capture.
- A small `evals/thread-memory-fixtures/` directory holds 3–5
  scripted conversations + expected-keyword assertions. The
  fixtures are evaluated by a new
  `scripts/eval-thread-memory.py` that mirrors `eval-fm.sh` —
  optional, run on demand, not in the standard test path.

## Risks

- **Summary drift over many turns.** Each compaction can lose
  small details; after 20 cycles the summary may diverge from
  ground truth. Mitigation: 20-min idle threshold + the
  user-visible "Reset thread now" button. Also, the summary is
  bounded at ~4 sentences so drift is structurally capped — it
  can't grow into a tangle.
- **Hallucinated continuity.** The summarizer invents a fact that
  was never said. Mitigation: prompt rule "Do not invent details"
  + the user can audit via the debug toggle. Long-term: a unit
  test fixture that includes a known-not-said claim and asserts
  the summarizer omits it.
- **Expense on small-model setups.** Apple FM is free in-process;
  LM Studio fallback adds ~150–300ms per turn. Acceptable because
  it's detached. If a user is on a constrained box without Apple
  Intelligence and finds the fallback latency painful, they can
  disable thread memory entirely from Settings.
- **Memory leak via summary growth.** Summary token cap is
  enforced at the summarizer prompt level (≤4 sentences /
  ≤400 tokens). Mitigation: a hard truncation in
  `applySummaryUpdate` that drops anything past
  `summaryMaxTokenEstimate` characters as a fail-safe.
- **Cross-talk with episodic memory.** A "fact" in the rolling
  summary is not durable; the user shouldn't expect Pace to
  remember it tomorrow. Mitigation: documentation in Settings
  copy makes the lifetime explicit ("This conversation only.").

## Implementation order

1. `PaceThreadMemory.swift` + `PaceThreadMemoryTests` (pure, fast
   feedback).
2. `PaceThreadSummarizer.swift` + `PaceThreadSummarizerTests` with
   a fake summarizer client.
3. `PaceUserPreferencesStore` key additions.
4. `BuddyPlannerClient` / `BuddyPlannerRequest` field addition +
   the four conformer updates (concatenation only; no logic
   change).
5. `CompanionSystemPrompt` injection point.
6. `CompanionManager` wiring (record after turn, prepend before
   turn, detached summarization task, idle gate).
7. `PaceSettingsWindow` Memory tab subsection.
8. AGENTS.md / CLAUDE.md updates (architecture paragraph + two
   Key Files rows).
9. Run `bash scripts/test-pace.sh` — must end green.
10. Commit with the standard format. **Do not run
    release-pace.sh.**

## What NOT to do

- Do NOT persist the summary across app restarts. The lifetime is
  the session. Persistence is what episodic memory is for.
- Do NOT pipe the summary into episodic fact extraction without
  the explicit `isThreadEndingEpisodicHandoffEnabled` toggle —
  the precision floors of the two systems are different.
- Do NOT block the user-facing planner turn on summarization.
  Summarization is detached, period. If you find yourself
  awaiting the summarizer in the request path, the design is
  wrong.
- Do NOT write the summary text to `paceHistory` retrieval.
  Journal only the session id and the lifecycle event.
- Do NOT extend the verbatim window past 8 (clamp enforced).
  Larger windows defeat the point of the summary and bloat the
  planner input.
- Do NOT use the cloud-bridge upstream for summarization in v1.
  The summary is allowed to be slightly stale; routing it to the
  cloud trades the wrong axis.
- Do NOT remove the existing `conversationHistory` field on
  `CompanionManager` — keep it as a thin facade over
  `threadMemory.verbatimWindow()` so callers in unrelated paths
  (smoke tests, debug logs) keep working.

## Effort estimate

~700 lines incl. tests + fixtures (200 + 250 + ~250 across
modifications + tests). Reachable in one Sonnet pass given the
file-by-file spec above. Blocks on no other PRD; can ship before
or after episodic memory because the boundary is clean.

Where in code: `leanring-buddy/PaceThreadMemory.swift` (verbatim window + summary
state, monotonic `summaryVersion` race guard) and
`leanring-buddy/PaceThreadSummarizer.swift` (Apple FM `@Generable` summarizer
with LM Studio loopback fallback).
