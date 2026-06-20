#!/usr/bin/env bash
#
# train-pace-tuned-model.sh — scaffold for the first Pace-tuned 4B LoRA.
#
# This does NOT run training automatically. It validates prerequisites,
# prints the exact MLX LoRA command sequence, and emits a manifest JSON
# you can host at RemoteModelManifestURL after eval-gate passes.
#
# Prerequisites (human):
#   1. Opt-in anonymized turn export (see docs/plans/pace-tuned-model-v1.md)
#   2. MLX + mlx-lm installed
#   3. eval-v10-gate.sh green on the candidate checkpoint
#
# Usage:
#   bash scripts/train-pace-tuned-model.sh --check
#   bash scripts/train-pace-tuned-model.sh --emit-manifest pace-ai/pace-planner-v1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATASET_DIR="$PROJECT_DIR/evals/pace-tuned-export"
BASE_MODEL="${PACE_TUNED_BASE_MODEL:-mlx-community/Qwen3-4B-Instruct-2507-bf16}"
OUTPUT_DIR="${PACE_TUNED_OUTPUT_DIR:-$PROJECT_DIR/.artifacts/pace-planner-v1-lora}"

mode="${1:-}"
model_id="${2:-pace-ai/pace-planner-v1}"

case "$mode" in
  --check)
    echo "▶ Checking pace-tuned model prerequisites"
    command -v python3 >/dev/null || { echo "need python3"; exit 1; }
    if [[ ! -d "$DATASET_DIR" ]]; then
      echo "⚠️  Missing dataset dir: $DATASET_DIR"
      echo "   Export opt-in turns into JSONL there before training."
    else
      echo "✓ dataset dir exists: $DATASET_DIR"
    fi
    echo "✓ base model pin: $BASE_MODEL"
    echo "✓ output dir: $OUTPUT_DIR"
    echo
    echo "Next: collect data → train LoRA → run bash scripts/eval-v10-gate.sh with PACE_RUN_MLX_EVAL=1"
    ;;
  --emit-manifest)
    cat <<EOF
{
  "plannerModelIdentifier": "$model_id",
  "embedderModelIdentifier": null,
  "vlmModelIdentifier": null,
  "publishedAt": "$(date -u +%Y-%m-%d)"
}
EOF
    ;;
  *)
    cat <<EOF
Pace-tuned model training scaffold

1. Export dataset to: $DATASET_DIR
2. Fine-tune (example — adjust paths/ranks to your MLX setup):

   mlx_lm.lora \\
     --model $BASE_MODEL \\
     --train \\
     --data $DATASET_DIR \\
     --adapter-path $OUTPUT_DIR \\
     --iters 1000 \\
     --batch-size 4

3. Eval gate:

   PACE_RUN_MLX_EVAL=1 bash scripts/eval-v10-gate.sh

4. Ship manifest + Info.plist bump:

   bash scripts/train-pace-tuned-model.sh --emit-manifest $model_id > remote-model-manifest.json
   # Host JSON + set RemoteModelManifestURL in Info.plist

Commands:
  bash scripts/train-pace-tuned-model.sh --check
  bash scripts/train-pace-tuned-model.sh --emit-manifest pace-ai/pace-planner-v1
EOF
    ;;
esac
