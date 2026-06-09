# fm-vlm-fixtures-v1 — Pace VLM eval fixtures

The eval gate for any Pace VLM specialist (task #272 in tinygpt).

Each fixture provides the inputs a VLM-equipped Pace would see:
- `APP_FRONTMOST` — from `NSWorkspace.frontmostApplication`, deterministic
- `AX_TREE` — AX API output (may be empty in `AX_BLIND: true` cases)
- `OCR_TEXT` — Apple Vision `VNRecognizeTextRequest` output
- `USER` — what the user said

A rule-based baseline (`tinygpt/scripts/fake_pace_vlm.py`) tries to
answer using ONLY AX + OCR + a small app→activity lookup table. The
real VLM has to score meaningfully higher than this baseline to
justify its existence.

## Categories

1. **identity-***  — "what am I doing / which app / what's on screen"
   FakePaceVLM should pass these. Real VLM should at least match.

2. **read-***  — "what does it say / read this"
   FakePaceVLM passes via OCR passthrough.

3. **click-ax-visible-***  — element grounding when AX has the target
   FakePaceVLM passes via substring match.

4. **ax-blind-***  — Electron / canvas / image UIs, AX_BLIND=true
   FakePaceVLM FAILS — element grounding from a screenshot needs the VLM.

5. **activity-deep-***  — "what specifically am I doing"
   FakePaceVLM has shallow heuristics; VLM should beat them.

6. **unknown-app-***  — app not in FakePaceVLM's lookup table
   FakePaceVLM falls back to default; VLM should infer from screenshot.

7. **cross-element-***  — reasoning over both AX and OCR
   FakePaceVLM lacks this; VLM should handle it.

## Acceptance bar

For an LoRA to claim VLM contribution:

- FakePaceVLM baseline: X / N
- Real VLM (M4 Qwen3-VL port or specialist): Y / N
- Delta Y − X must be > 30 percentage points for "real model
  contribution" verdict.

When the M4 Qwen3-VL port (#266) lands and can consume a screenshot
input, extend this README with the second column. Until then, only
FakePaceVLM measurement is meaningful.

## Companion artifact

When the real VLM ships, fixtures will also carry a
`SCREENSHOT_PATH: path/to/png` field. The eval harness will feed both
the metadata (for FakePaceVLM) and the screenshot (for real VLM)
into a side-by-side comparison, just like `eval_pace_v2.py` does for
the planner.
