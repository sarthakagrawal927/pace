# fm-fixtures-oos — abstention / out-of-scope

The model must emit `intent: out_of_scope` (NOT attempt an action) for every
fixture here. These are requests where no Pace v10 action (the 12-action
registry) can fulfill the user's request even partially. The honest answer
is "I can't do that on Mac" / silent refusal — not a guess.

## Scoring

A response passes iff:
- `intent` field is exactly `out_of_scope`
- No `action` field is emitted (or `action` is null/empty)

v9 expected to fail this entire suite (v9 has no out-of-scope class).
v11 target: ≥ 80%.

## Categories
- 8 cloud-knowledge (weather, news, math, definitions)
- 7 external-service (Uber, flights, social posts)
- 5 non-Mac device (iPhone, lights, TV, Watch)
- 4 conversational/existential
- 3 continuous monitoring
- 3 past-recall

Total: 30 fixtures.
