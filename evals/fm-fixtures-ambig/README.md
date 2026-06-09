# fm-fixtures-ambig — disambiguation / clarify

The model must emit `intent: clarify` and ask back when the user's request
is ambiguous. Pace is voice-first; a wrong guess is worse than a clarifying
question.

## Scoring

A response passes iff:
- `intent` field is exactly `clarify`
- A `question` (or `clarifying_question`) field is non-empty
- The question references the topic listed in `EXPECT_CLARIFY_TOPIC`
  (substring match, case-insensitive)

v9 expected to fail this suite — v9 always guesses.
v11 target: ≥ 50%.

## Categories
- 5 pronoun-without-referent ("send it", "play this")
- 4 missing recipient ("share the link with — ?")
- 4 multi-element matching ("click the button" with N buttons)
- 4 missing time/quantity ("remind me later")
- 3 missing subject content ("write an email")

Total: 20 fixtures.
