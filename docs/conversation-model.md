# How Pace Holds a Conversation

Pace stays coherent across turns with a **two-tier in-context memory** plus the
per-turn exchange list. This is *conversational* memory (this session only) —
distinct from *episodic* memory (durable facts across sessions). See
[capabilities.md](capabilities.md) for where each fits.

Canonical PRD: `docs/prds/conversational-thread-memory.md`. This page is the
short mental model.

## The two tiers

Every planner turn is built from:

1. **Verbatim window** — the last **K = 4 turn-pairs** (you + Pace), passed
   exactly as `conversationHistory`. This is what lets "it", "that one", or "do
   it again" resolve to something said a couple of turns ago.
2. **Rolling summary** — everything *older* than those 4 turns, compressed into
   one paragraph and injected into the system prompt as
   `<conversation_so_far>…</conversation_so_far>`.

So the planner sees, each turn:

```
[system prompt + <conversation_so_far> rolling summary of older turns]
[verbatim: user/assistant × last 4 turns]
[current user transcript]
```

`K` (verbatim window) and the idle threshold are user-tunable in
**Settings → Activity** (window 1–8 pairs, idle 5–60 min).

## The components

| Piece | Role |
|---|---|
| `PaceThreadMemory` | Owns both tiers. Session-scoped, **never written to disk**. Drops on a 20-minute idle threshold or a manual reset (Settings → Activity → Reset thread). |
| `PaceThreadSummarizer` | After each turn, a **detached** Apple FM call rolls the displaced turn into the summary. Fire-and-forget — the user-facing turn never waits on it. LM Studio is the fallback summarizer. |
| `CompanionManager.conversationHistory` | The live exchange list handed to the planner each call. |
| `PaceChatSession` | The in-window chat transcript. Voice and chat turns share one history (`paceHistory`). |

## Race-safety

Summarization runs off the hot path and can finish out of order (a slow summary
for turn N arriving after turn N+1). `PaceThreadMemory` stamps a monotonic
`summaryVersion` before each detached call and drops any update whose version is
stale at `applySummaryUpdate`. So a late summary can never clobber a newer one.

## Why it's session-scoped, not persisted

The rolling summary is deliberately ephemeral: it is never journaled to
`paceHistory` and never written to disk. Durable, cross-session facts are the
job of **episodic memory** (a precise extractor with dedup + tombstones), not the
loose conversational summary — coupling them would let low-confidence chatter
leak into long-term memory. The 20-minute idle drop means a fresh conversation
starts clean rather than dragging stale context.

## Single-shot turns and conversation

Action turns are **single-shot** when the planner is decode-constrained to the
v10 JSON envelope (`response_format`): one envelope can carry multiple actions
via `payload.calls`, and the loop does not re-invoke the planner. This keeps the
constrained model from inventing spurious follow-up actions. Conversational
*coherence* is unaffected — the next turn still sees the verbatim window and
summary as above. (Background: this replaced an 8-step runaway where the
re-looped constrained planner dictated the user's own command.)

## Relationship to the planner tiers

The same conversation context flows through whichever planner tier is active
(Local / Apple FM / CLI bridge / Direct API), so switching tiers never forks
conversational behavior. See `docs/prds/planner-tier-picker.md`.
