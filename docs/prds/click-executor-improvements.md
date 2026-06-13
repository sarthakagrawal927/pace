---
name: Click executor — accuracy improvements
Status: partial (actionable) — coordinate/label top-K parser/scorer plus focused-window scoring, focused AX-tree verify/retry, recency hint scoring, and all-fail observations landed in Pace; manual ambiguity evals still queued
owner: future Pace-repo agent
created: 2026-06-08
source-conversation: tinygpt session 2026-06-08 (planner v5→v6 daily-drive feedback)
upstream-deps: TinyGPT v6 planner (label-based architecture, shipped 2026-06-08); tool-caller plumbing landed — the readiness gate is satisfied
priority: P0 — addresses real-screen click misses observed during v5 daily-drive ("trouble clicking the exact part, was going at wrong point")
---

# Click executor — accuracy improvements

## Why this PRD exists

During v5 daily-drive, the planner sometimes told Pace to click the
right *element* but the click landed at the wrong *point* on screen.
Three classes of failure were identified:

1. **Off-center click points** — the executor was clicking near, but
   not on, the target element's interactive region.
2. **Ambiguous labels** — the planner emitted one label, and when
   multiple elements matched (e.g., two "Submit" buttons), the
   executor picked arbitrarily.
3. **Silent misses** — when a click missed for any reason (modal
   overlay, scrolled-off element, dynamic UI), Pace didn't notice and
   moved on to the next step.

This PRD describes three executor-side changes. None of them require
re-training the planner (a separate v7 PRD will eventually update the
planner output schema for Change 2; the executor side here can ship
first as a backwards-compatible no-op).

Implementation note, 2026-06-09: Pace now accepts coordinate and label-only
`candidates` on `click` / `AX.press` tool calls and dispatches a
`clickCandidates` action. Candidate arrays are accepted from both typed v10
JSON payloads and `<tool_calls>` blocks. The selector applies the
high-confidence shortcut, cursor-proximity scoring for coordinate candidates,
focused-window scoring when AX exposes the active window frame, and low-weight
recency hints (`recencyRank` / `lastSeenMsAgo` aliases) for ambiguous near-ties.
Label-only candidates resolve against the frontmost focused window's AX tree
and press the best exact/substring label match.
Coordinate candidate execution also captures a local AX/window state snapshot
before and after each click, including a bounded focused-window AX-tree
fingerprint, waits 200ms, and retries up to the next two candidates when no
state change is observed and `expectStateChange` is not false.
If every tried candidate fails or produces no observable state change, the
executor emits a `click_candidates` observation with the tried labels/locations
so the planner can re-plan or Pace can surface a useful failure message.
Manual ambiguity evals remain queued.

## Upstream context (TinyGPT side)

The v6 planner emits a JSON object with shape:
```json
{
  "spokenText": "Opening Twitter for you",
  "pointAtLabel": "Twitter",
  "clickLabel": "Twitter"
}
```

Pace currently maps `clickLabel` → element_id via the deterministic
lookup in `element_id_for_label()` (exact match → substring containment
→ reverse containment → -1 fallback). The lookup uses the AX-derived
element list Pace already builds for every screen.

This PRD's changes layer on top of that. **No v6 planner change is
required for Changes 1 and 3.** Change 2 needs a v7 planner upgrade,
which TinyGPT will ship later — the executor work here lands first as
schema-tolerant code (accepts both v6 single-label and v7 top-K).

## Change 1 — Click at center-of-bbox, not raw point

### What

Audit the click-dispatch site. Verify the click coordinate is computed
as `(bbox.midX, bbox.midY)` of the AX-reported element frame, not a
stored fixed point or the bbox origin or a screen-relative offset.

### Why

The center of the bbox is the most robust click target. Off-center
clicks can:
- Land on element padding (no click registers)
- Miss small buttons by a few pixels
- Hit a child element instead of the parent
- Land on overlapping siblings in dense UIs

The center is always inside the element and farthest from any boundary.

### How to apply

1. Grep clickyLocal for the click-dispatch site (likely
   `ClickExecutor.swift`, `Clicker.swift`, or wherever
   `clickLabel` is consumed).
2. Confirm: given an `AXUIElement` with attribute
   `kAXFrameAttribute`, the click point = `CGPoint(x: frame.midX, y: frame.midY)`.
3. If the current code uses `frame.origin` or a stored offset, fix it.
4. If it already uses midpoint: PASS, no code change, just record this
   audit in a comment.

### Edge cases

- **Wide elements (search bars, full-width buttons)**: midpoint is
  fine — anywhere inside is clickable.
- **Sub-region elements (cell in a table)**: the model is supposed to
  return the cell's element_id, not the table's. Not the executor's
  job to figure out sub-regions.
- **Multi-region elements (toolbar with multiple icons in one AX
  parent)**: rare; if it comes up, the AX tree usually exposes the
  sub-elements as children. Click the child, not the parent.

### Acceptance

- Code review confirms `(bbox.midX, bbox.midY)` formula
- Unit test: given a synthetic AX element with frame
  `CGRect(x: 100, y: 100, width: 80, height: 30)`, computed click point
  is `(140, 115)` — not `(100, 100)` or `(180, 130)`

## Change 2 — Top-K candidates + tiebreak

### What

Today the planner emits one `clickLabel`. The executor maps it to one
element and clicks. When multiple elements match the label, the
executor picks the first one (typically AX tree order, which is
basically random for our purposes).

This change has two parts:
- **Executor side (this PRD)**: accept BOTH single-label (v6) AND
  top-K candidates (v7-future) schemas. When given top-K, use
  context-aware tiebreaking.
- **Planner side (separate v7 PRD)**: emit top-K with confidence.

The executor change can ship first as a no-op for v6 traffic (top-K
becomes a list-of-one) and immediately benefit when v7 lands.

### v7 schema (target shape)

```json
{
  "spokenText": "Submitting your form",
  "candidates": [
    {"label": "Submit",            "confidence": 0.85},
    {"label": "Submit and continue", "confidence": 0.12},
    {"label": "Submit feedback",   "confidence": 0.03}
  ]
}
```

Pace's currently implemented compatible coordinate-candidate shape:

```json
{
  "tool": "click",
  "screen": 1,
  "expectStateChange": false,
  "candidates": [
    {"x": 100, "y": 120, "label": "Save", "confidence": 0.40},
    {"x": 300, "y": 120, "label": "Save Draft", "confidence": 0.90}
  ]
}
```

### Tiebreak algorithm

Given candidates ordered by model confidence:

1. **High-confidence shortcut**: if `candidates[0].confidence > 0.80`,
   click `candidates[0]`'s element and exit. The model is confident;
   trust it.
2. **Ambiguous case**: iterate candidates in confidence order. For
   each, find all AX elements that match its label. Across all matches
   from all candidates, score each match using:
   - **+5** if element is in the foreground/focused window
   - **+3** if element is within 200 pixels of current cursor position
   - **+2** if label is an exact match (vs substring)
   - **+1** if element was added to the AX tree in the last 1s (newest UI)
   - **× confidence** of the originating candidate
3. Click the highest-scoring match.
4. **All-fail fallback**: if no candidate's label resolves to any AX
   element, do not click. Just emit the `spokenText` so Pace doesn't
   silently no-op.

### Why this scoring

Each signal addresses a specific real-world ambiguity:
- **Focused-window** — when two apps both have "Submit" buttons, the
  user almost always means the focused one.
- **Cursor proximity** — when two cards both have a "Like" button,
  the user means the one they're looking at (cursor proxy).
- **Exact match** — model says "Submit"; "Submit" beats "Submit
  feedback" by specificity.
- **Recency** — modals/dropdowns that just appeared are usually the
  intended target.

### How to apply

1. Add a `candidates: [Candidate]?` field to whatever struct decodes
   the planner output. Keep `clickLabel: String?` for backwards-compat.
2. When decoding, if `candidates` is present, use it. Otherwise wrap
   `clickLabel` into `[Candidate(label: clickLabel, confidence: 1.0)]`.
3. Implement the scoring function above.
4. Replace the current first-match-wins lookup with the scored selection.

### Acceptance

- Backwards-compat: v6 coordinate JSON still works. Label-only candidate JSON
  resolves through the frontmost app AX tree.
- Forward-compat: coordinate and label top-K JSON parses and scores correctly.
- Unit tests cover current coordinate-candidate high-confidence,
  cursor-proximity, focused-window, and recency selection plus label-only
  parsing and normalization. The all-fail path now emits a structured
  observation. Real-app ambiguity verification tests remain queued.
- Manual test on the v5-daily-drive ambiguity scenarios (the ones that
  prompted this PRD): correct element selected

## Change 3 — Click verification loop

### What

After every click, capture screenshot + new AX tree. Diff against
pre-click state. If no meaningful state change happened, the click
likely missed — try the next candidate from Change 2's top-K.

### Why

Even with center-of-bbox + top-K, ~5% of clicks fail for reasons the
model can't predict from a static screenshot:
- Modal overlay covered the target
- Element scrolled off-screen between perception and action
- Dynamic UI re-rendered with the element in a new position
- Permission dialog stole focus

Verify-and-retry catches almost all of these. The ~200ms cost per
click is invisible to the user (faster than human reaction time) and
takes per-click accuracy from ~90% to ~99%.

### State-change detection (cheap)

Compute a tuple before and after the click:
```swift
struct ClickState {
  let axTreeHash: UInt64       // hash of (element_ids, roles, labels) in current screen
  let focusedElementID: Int?   // ID of the AX-focused element
  let windowCount: Int         // number of visible windows
  let frontmostBundleID: String?  // bundleID of frontmost app
}
```

Current Pace implementation for coordinate candidates uses a local snapshot:
frontmost bundle id, visible layer-0 window count, focused window title,
focused-element fingerprint, and a bounded focused-window AX-tree fingerprint
from role/subrole/title/description/value.

If `pre == post` for all snapshot fields, the click did nothing observable
→ try candidate #2.

If any field changed, the click had effect → success, exit.

### Retry policy

- Max 2 retries (3 total click attempts)
- Each retry uses the next candidate from the top-K list
- After all candidates fail, emit "click failed" as a structured tool
  observation. Pace feeds it to the next planner step and can surface it as
  user feedback.

### Edge cases — expectNoStateChange

Some clicks intentionally produce no observable state change:
- Clicking an already-focused text field to position the cursor
- Clicking on empty canvas to deselect everything
- Clicking a non-interactive label

For these, the planner's v7 output should include:
```json
{
  ...
  "expectStateChange": false
}
```

When `false`, the executor skips verification (single click attempt,
trust it worked).

For v6 backwards-compat (no `expectStateChange` field), candidate clicks default
to `true` and verify by default. Legacy single-coordinate clicks keep the old
single-attempt behavior.

### How to apply

1. Wrap the click call in a `verifyAndRetry` block.
2. Capture `ClickState` before. Click. Wait 200ms. Capture
   `ClickState` after.
3. If unchanged AND `expectStateChange != false`, try next candidate.
4. After all candidates exhausted, emit failure callback.

### Acceptance

- Coordinate candidate clicks retry when state is unchanged. A separate feature
  flag is still queued if real-app smoke shows a need to disable it.
- Smoke test on Pace's existing fm-fixtures: same or better hit rate,
  no regressions
- Manual test: known-flaky real-screen scenarios from v5 daily-drive
  now succeed
- Latency overhead: <250ms added to a successful click (verification
  only runs after); <500ms added to a retry (verification + second
  click)

## Acceptance — full ship

1. Change 1: code review confirms midpoint click
2. Change 2: schema-tolerant executor accepts v6 and v7 outputs;
   scoring function unit-tested
3. Change 3: verify-and-retry behind feature flag, default ON
4. Smoke on existing fm-fixtures: pass rate same or better
5. Manual: previously failing real-screen scenarios click correctly
6. No regression in click latency for the success path (any added
   verification is post-click)

## Not in scope

- Training data changes (that's TinyGPT-side, in
  `docs/prds/factory-vision-specialist.md`'s M6 — AX-derived ground
  truth)
- Planner v7 SFT (TinyGPT-side PRD, queued after current ANE + VLM
  arcs land)
- Voice / TTS path
- Multi-step task planning — separate concern from per-click accuracy

## Where the code lives (best guesses for the next agent)

The next agent should grep clickyLocal for these signals to find the
right files:

- `clickLabel` — finds the planner output decode site
- `element_id_for_label` — finds the label→ID resolver
- `kAXPressAction` or `AXPerformAction` or `CGEvent.*click` — finds
  the actual click dispatch
- `element.frame` or `kAXFrameAttribute` — finds the bbox extraction
- `LocalPlannerClient` or whatever talks to TinyGPT's serve endpoint

Likely file names (verify before assuming):
- `ClickExecutor.swift` / `Clicker.swift` — click dispatch
- `PlannerClient.swift` / `LocalPlannerClient.swift` — schema decode
- `AccessibilityTree.swift` / `ElementMap.swift` — AX tree management

## Tool-caller readiness gate (satisfied)

Originally gated on tool-caller plumbing landing on the Pace side. That
plumbing shipped (grouped tool calls, registry validation, v10 envelope),
so the gate is satisfied — implementation landed; only the manual
ambiguity evals remain queued.

## TinyGPT-side coordination

When v7 planner training happens (separate TinyGPT PRD), the output
schema additions are:
- `candidates: [{label: String, confidence: Float}]` (replaces or
  supplements `clickLabel`)
- `expectStateChange: Bool?` (optional, defaults to `true`)

The executor side here is forward-compatible with these additions, so
no second wave of clickyLocal work is needed when v7 lands.

Remaining v1 scope:
- Turn the manual ambiguity eval set into a unit-test fixture suite so
  regressions in the top-K scorer/recency-hint logic surface in CI.
- Add a runtime smoke flow (under `scripts/smoke-runtime-hooks.sh`) that
  drives the all-fail observation path through `PaceActionExecutor` to
  the planner re-plan/user feedback surfaces.
