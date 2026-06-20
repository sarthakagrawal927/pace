# Pace-tuned planner v1 — training plan

Status: **data gate** — engineering scaffold is in repo; the LoRA run waits on opt-in turn export.

## Target

- Base: `mlx-community/Qwen3-4B-Instruct-2507-bf16`
- Output: `pace-ai/pace-planner-v1` (HuggingFace + Sparkle manifest)
- Ship path: `RemoteModelManifestURL` or Info.plist `BundledMLXPlannerModelIdentifier` bump

## Dataset

1. Export anonymized planner turns (user opt-in) to `evals/pace-tuned-export/*.jsonl`.
2. Mix with existing `evals/fm-fixtures/*.txt` converted to v10 JSON envelope shape.
3. Hold out `evals/fm-fixtures-holdout/` — never train on holdout.

## Train

```bash
bash scripts/train-pace-tuned-model.sh --check
# follow printed mlx_lm.lora command after dataset exists
```

## Eval gate (must pass before default switch)

```bash
bash scripts/eval-v10-gate.sh
PACE_RUN_MLX_EVAL=1 bash scripts/eval-v10-gate.sh
python3 scripts/eval-planners.py --models <candidate-id>
```

Update `PaceBundledModelsSettingsTests.shippingDefaults` pin when the candidate wins.

## Ship

```bash
bash scripts/train-pace-tuned-model.sh --emit-manifest pace-ai/pace-planner-v1 > remote-model-manifest.json
```

Host manifest → set `RemoteModelManifestURL` in Info.plist → Sparkle release.
