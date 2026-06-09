# fm-fixtures-v2 — model-required fixtures

The v1 `fm-fixtures/` set is **format-compliance only**. A rule-based
endpoint (`scripts/fake_pace.py` in tinygpt) scores 19/19 on v1 with
zero model inference. See
`tinygpt/docs/learn/eval-methodology-2026-06-08.md` for the full
analysis.

This v2 set is designed so a rule-based endpoint **must fail** —
forcing the eval to measure actual model contribution.

## Axes covered

1. **Semantic disambiguation** — the user refers to a function the
   model must know maps to a specific app/UI element. Element labels
   never contain the function word; only the model's world knowledge
   does.
   - "open the app i use to write code" → Xcode (not Mail/Safari/Spotify)
   - "take me to my email" → Mail
   - "do a budget calculation" → Numbers

2. **Multi-element reasoning** — the user asks for the element with a
   superlative property the model must read from the `text` field
   and compare across elements.
   - "click the cheapest plan" → parse prices, pick min
   - "play the longest one" → parse durations, pick max
   - "open the latest email" → parse timestamps, pick most recent

3. **Abstract reference resolution** — the user names a goal, not a
   label. Model must understand the goal maps to an action.
   - "click the one for sending money" → Transfer (not Buy/Sell)

## Acceptance bar

For this set to validate model-vs-framework separation:

- FakePace baseline (rule-based, zero model) should score **≤ 50%**
- A real model with adequate world knowledge should score **≥ 85%**
- The delta IS the moat being measured

## Fixture format

Identical to v1 fm-fixtures format. Same scoring rules. The only
difference is content — every fixture here is designed such that
the answer is NOT recoverable from label substring matching alone.
