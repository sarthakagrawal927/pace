#!/usr/bin/env bash
#
# eval-v10-gate.sh — pre-ship gate for v10 planner + schema work.
#
# Always runs:
#   - Swift unit tests (scripts/test-pace.sh)
#   - v10 schema fixtures (scripts/eval-v10-schema-fixtures.py)
#
# When Apple Intelligence is ready:
#   - FM fixture sweep (scripts/eval-fm.sh)
#   - FM scorecard via eval-planners.py --models fm (informational)
#
# Optional:
#   PACE_RUN_MLX_EVAL=1 bash scripts/eval-v10-gate.sh
#     also runs PaceMLXPlannerEvalHarnessTests (multi-GB download)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    beta_xcode="$(find /Applications -maxdepth 1 -name 'Xcode*.app' -type d 2>/dev/null | sort | tail -1)"
    if [[ -n "$beta_xcode" && -d "$beta_xcode/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$beta_xcode/Contents/Developer"
    fi
  fi
fi

echo "▶ v10 gate — unit tests"
bash "$SCRIPT_DIR/test-pace.sh"

echo
echo "▶ v10 gate — schema fixtures"
python3 "$SCRIPT_DIR/eval-v10-schema-fixtures.py"

echo
echo "▶ v10 gate — Apple FM fixture sweep"
if bash "$SCRIPT_DIR/check-apple-intelligence.sh" >/dev/null 2>&1; then
  bash "$SCRIPT_DIR/eval-fm.sh"
  echo
  echo "▶ v10 gate — FM scorecard (legacy tag fixtures; informational)"
  python3 "$SCRIPT_DIR/eval-planners.py" --models fm | tail -8
else
  echo "⚠️  Apple Intelligence not ready — skipped FM eval"
fi

if [[ "${PACE_RUN_MLX_EVAL:-}" == "1" ]]; then
  echo
  echo "▶ v10 gate — bundled MLX planner harness (PACE_RUN_MLX_EVAL=1)"
  PACE_RUN_MLX_EVAL=1 bash "$SCRIPT_DIR/test-pace.sh" PaceMLXPlannerEvalHarnessTests
else
  echo
  echo "ℹ️  Bundled MLX eval skipped (set PACE_RUN_MLX_EVAL=1 to include)"
fi

echo
echo "✅ v10 gate passed (schema + unit tests; FM sweep when available)"
