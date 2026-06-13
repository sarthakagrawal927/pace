---
name: Pace planner v8 deployment
Status: superseded — the runtime planner default moved to the off-the-shelf qwen/qwen3-30b-a3b MoE via LM Studio (15/15 on FM fixtures, 925ms mean, per scripts/eval-planners.py); the v8 LoRA deployment is parked on the TinyGPT side and resumes only if a trained specialist beats the MoE on the eval gate
artifact: ~/.cache/tinygpt/runs/pace-planner-v8/baked-hf/  (1.4 GB)
source-eval: tinygpt/docs/learn/eval-matrix-2026-06-08.md
Replaced by: the runtime LM Studio default declared in `Info.plist` as `LocalPlannerModelIdentifier=qwen/qwen3-30b-a3b`. The architecture/runtime planner role lives in `leanring-buddy/LocalPlannerClient.swift`; eval evidence in `scripts/eval-planners.py`.
---

# Pace planner v8 — deployment

## What this is

A Qwen3-0.6B base with the Pace v8 LoRA pre-baked into the weights.
Drop-in replacement for the current `qwen3-4b-instruct` LM Studio
endpoint that `LocalPlannerClient` uses today.

## Why ship this

First Pace planner to demonstrably beat Qwen3-14B on the
model-required eval:

| System | fm-fixtures-v2 | holdout | overfit? |
|---|---|---|---|
| Pace v5 LoRA (prior best) | 6/15 (40%) | — | — |
| Qwen3-14B (current Pace teacher) | 9/15 (60%) | — | — |
| **Pace v8 LoRA (this artifact)** | **11/15 (73%)** | **10/15 (67%)** | **no** |

v8 generalizes to novel apps it never saw in training (Figma, Zoom,
Slack, Lightroom, hotels, cars, abstract goals like "leave tip" /
"bookmark"). Generalization gap only 6.7 pp from training-adjacent
to held-out.

Holdout test set: `clickyLocal/evals/fm-fixtures-holdout/`.
Full eval matrix: `tinygpt/docs/learn/eval-matrix-2026-06-08.md`.

## Two deployment options

### Option A — LM Studio (matches current Pace pattern)

```bash
# 1. Copy the baked dir into LM Studio's models location
cp -r ~/.cache/tinygpt/runs/pace-planner-v8/baked-hf \
      ~/.lmstudio/models/tinygpt/pace-planner-v8

# 2. Restart LM Studio; the model appears as "tinygpt/pace-planner-v8"
# 3. Update Pace's planner model ID to that string
```

Pros: zero changes to Pace's HTTP client; runs in the existing
LM Studio process; benefits from LM Studio's quantization.

Cons: not on ANE (LM Studio uses GPU via MLX); doesn't yet route
through the chunked ANE bundle we shipped (separate path).

### Option B — tinygpt serve (matches today's eval setup)

```bash
# 1. Run TinyGPT serve as a background service
tinygpt serve \
  ~/.cache/tinygpt/runs/pace-planner-v8/baked-hf \
  --grammar /Users/sarthak/Desktop/fleet/tinygpt/grammars/pace-fm-label-response.schema.json \
  --port 8765

# 2. Point Pace's LocalPlannerClient at:
#    http://127.0.0.1:8765/v1/chat/completions
#    model = "tinygpt"
```

Pros: this is exactly what `scripts/eval_pace_v2.py` validated. Known
good. Lower memory than LM Studio.

Cons: separate process to manage; not currently wrapped in launchd.

### Recommended

**Option B for now** — that's the path we've measured. Migrate to
Option A once we've ported a snappier serve to a launchd daemon.

## Validating the deployment

After wiring, run the eval against the deployed endpoint:

```bash
# tinygpt serve path:
python3 scripts/eval_pace_v2.py \
  --serve-url http://127.0.0.1:8765/v1/chat/completions \
  --fixtures-dir /Users/sarthak/Desktop/fleet/clickyLocal/evals/fm-fixtures-v2

# Expected: 11/15 (73.3%) on v2, 10/15 (66.7%) on holdout. If you
# see significantly less, the deployment has a bug (wrong model ID,
# missing grammar, wrong endpoint, etc.)
```

## What v8 still misses

Four fm-fixtures-v2 failures (and matching shapes in holdout):
- `abstract-make-payment` ("pay electric bill" → Transfer)
- `reason-most-expensive` (parse $0/$15/$99, pick max)
- `reason-oldest-email` (timestamp comparison)
- `semantic-word-processor` ("write a letter" → Pages)

Mostly multi-element numeric/temporal reasoning. v9 with ~10 more
diverse comparison examples could land at ≥85%. Not blocking v8
ship; just a follow-up.

## Caveats

- v8 is a JSON-grammar-constrained model. Pace's existing system
  prompt + JSON schema enforcement at the endpoint must be applied.
  Without the grammar, output shape is unreliable.
- Sub-100ms target: a single v8 call via tinygpt serve is ~50-150ms
  TTFW + grammar-constrained decode. Sub-100ms ceiling only achievable
  with prompt-cache + MLX compile + short outputs. Should be fine for
  Pace's short JSON responses.
- This is the PLANNER artifact. Pace's VLM still uses Qwen3-VL-8B
  via LM Studio. VLM specialist work is separate (#266, #275).
