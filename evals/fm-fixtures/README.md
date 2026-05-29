# FM eval fixtures

Plain-text fixtures consumed by `scripts/eval-fm.sh`,
`scripts/eval-planners.py`, and `scripts/diag-pace.py --eval`.

## Fixture format

```
USER: <transcript the user spoke>
ELEMENT: [N] role|x,y|label|text
ELEMENT: [N+1] role|x,y|label|text
...

# Optional mode toggle:
FREE_TEXT_MODE: true             # see "Action-chain fixtures" below

# Optional scoring fields (any/all):
EXPECT_POINT_ID: 3               # exact match required (-1 = must refuse / no target)
EXPECT_POINT_ID_ONE_OF: 3,7,12   # any of these IDs acceptable (use for ambiguous targets)
EXPECT_CLICK_ID: 3               # exact match required (-1 = must refuse)
EXPECT_CLICK_ID_ONE_OF: 3,7      # any acceptable
SPOKEN_MUST_CONTAIN: pace        # case-insensitive substring
SPOKEN_MUST_NOT_CONTAIN: ID,coord,element  # comma-separated forbidden substrings
SPOKEN_MUST_MATCH_REGEX: \[TYPE:hello\]    # one regex (one line); repeat for ANDed patterns
SPOKEN_MAX_WORDS: 12             # spokenText word count cap
```

If a fixture omits all `EXPECT_*` lines, eval-fm.sh runs it for
diagnostic output only — no pass/fail score. Use this for
exploration; convert to scored when behavior is locked in.

Scoring is strict: every EXPECT_* present must pass for the
fixture to count as passing.

## Action-chain fixtures (FREE_TEXT_MODE)

The typed @Generable schema only covers spokenText + pointAt + click.
Pace's production `LocalPlannerClient` ALSO emits inline action tags
(`[CLICK:x,y]`, `[TYPE:exact text]`, `[KEY:cmd+s]`, `[SCROLL:down:3]`)
as free text, which `PaceActionTagParser` later extracts. To eval
these end-to-end, add `FREE_TEXT_MODE: true` to the fixture.

When set, the eval skips `response_format` so the planner's raw
output (with action tags) flows through, and you can assert tag
shapes via `SPOKEN_MUST_MATCH_REGEX`. Use `\[`, `\]`, `\+` etc. since
the value is a regex. The fm-fixtures named `action-*.txt` are the
reference examples.

FM (`PaceFMTurnResponse`) doesn't have a free-text path today, so
FREE_TEXT_MODE fixtures only run against LM Studio models. The FM
runner skips them implicitly (no point/click expectations to score).
