#!/usr/bin/env bash
#
# smoke-executor-surface.sh — executor PRD acceptance runner.
#
# Runs the deterministic dry-run unit suite (no real app mutations) and,
# when a Debug Pace.app is available, the runtime smoke hooks that cover
# click-target clarification and all-fail observation breadcrumbs.
#
# Real-app AX/performance smokes (Mail latency, Safari click, etc.) still
# require a user Xcode Debug build with TCC grants — see the checklist at
# the end of this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "▶ Executor surface smoke — dry-run unit tests"
bash "$SCRIPT_DIR/test-pace.sh" PaceActionExecutorDryRunTests

echo
echo "▶ v10 schema fixture gate"
python3 "$SCRIPT_DIR/eval-v10-schema-fixtures.py"

echo
if APP_PATH="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Pace.app 2>/dev/null | head -1)" \
   && [[ -x "$APP_PATH/Contents/MacOS/Pace" ]]; then
    echo "▶ Runtime smoke hooks (click clarification + all-fail observation)"
    bash "$SCRIPT_DIR/smoke-runtime-hooks.sh"
else
    echo "⚠️  Skipping runtime smoke hooks — build Pace.app from Xcode first."
    echo "    (Dry-run unit coverage above still validates the dispatcher surface.)"
fi

echo
echo "▶ Real-app smoke (Notes / Safari / Mail mailto + dry-run)"
bash "$SCRIPT_DIR/smoke-real-apps.sh" || exit 1

cat <<'EOF'

Manual checklist (pace-v9-body-streaming-wiring.md):
  [ ] Voice Mail draft with prewarm: compose + body streaming <700ms after stop-talk
  [ ] Slack / VS Code / Cursor focused-field smoke when those apps are foreground

Optional model gate before default switch:
  bash scripts/eval-v10-gate.sh
  PACE_RUN_MLX_EVAL=1 bash scripts/eval-v10-gate.sh

EOF

echo "executor surface smoke runner finished"
