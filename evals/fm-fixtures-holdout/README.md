# fm-fixtures-holdout — held-out generalization test

Designed AFTER Pace v8 trained, using app names and scenarios that
DO NOT appear in v8's training corpus (pace-v8-sft.jsonl).

The same three axes as fm-fixtures-v2:
1. Semantic disambiguation (5)
2. Multi-element reasoning (5)
3. Abstract reference (5)

But every scenario is novel from v8's perspective:
- App list does not include Mail/Xcode/Safari/Spotify/Pages/Numbers/
  Keynote/Reminders/Calendar/Messages/Photos/Notes/Chrome/Calendar
- Products are not "Free/Pro/Enterprise plan", "Phone Lite/Pro/Ultra",
  "Episode 1/2/3", "Inception/Interstellar/Tenet", etc.
- Abstract goals are not "send money", "pay bill", "save document"

If v8 generalizes (rather than overfitting to training patterns),
the holdout score should be CLOSE to its v2 score (73.3%). If v8
overfit, holdout collapses.

Run via `python3 scripts/eval_pace_v2.py --fixtures-dir <this dir> ...`
