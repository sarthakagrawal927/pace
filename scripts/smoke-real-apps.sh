#!/usr/bin/env bash
#
# smoke-real-apps.sh — lightweight real-app checks for executor PRD acceptance.
#
# Verifies Notes, Safari, and Mail respond to automation without driving
# Pace UI through Accessibility. Does NOT replace a full Mail streaming
# latency demo — that still needs a user Xcode Debug build + mic turn.
#
# Usage:
#   bash scripts/smoke-real-apps.sh

set -euo pipefail

FAILURES=0

pass() { echo "✓ $1"; }
fail() { echo "✗ $1" >&2; FAILURES=$((FAILURES + 1)); }

require_app() {
  local app_name="$1"
  if osascript -e "exists application process \"$app_name\"" >/dev/null 2>&1 \
     || osascript -e "exists application \"$app_name\"" >/dev/null 2>&1; then
    pass "$app_name is installed"
  else
    fail "$app_name is not installed"
  fi
}

echo "▶ Real-app smoke — app presence"
require_app "Notes"
require_app "Safari"
require_app "Mail"

echo
echo "▶ Real-app smoke — Notes activate"
if osascript <<'APPLESCRIPT' >/dev/null 2>&1
tell application "Notes" to activate
delay 0.4
tell application "System Events"
  if not (exists process "Notes") then error "Notes process missing"
end tell
APPLESCRIPT
then
  pass "Notes activated"
else
  fail "Notes activation failed (Automation permission may be missing for Terminal/Cursor)"
fi

echo
echo "▶ Real-app smoke — Safari open blank page"
if osascript <<'APPLESCRIPT' >/dev/null 2>&1
tell application "Safari"
  activate
  if (count of windows) = 0 then make new document
  set URL of front document to "about:blank"
end tell
APPLESCRIPT
then
  pass "Safari opened a document"
else
  fail "Safari automation failed"
fi

echo
echo "▶ Real-app smoke — Mail mailto compose latency"
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
open "mailto:pace-smoke@example.com?subject=Pace%20real-app%20smoke&body=hello"
sleep 0.8
END_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
ELAPSED_MS=$((END_MS - START_MS))

if osascript -e 'tell application "System Events" to return exists process "Mail"' >/dev/null 2>&1; then
  pass "Mail process visible after mailto (${ELAPSED_MS}ms to activate)"
  if [[ "$ELAPSED_MS" -gt 2000 ]]; then
    echo "  ⚠️  mailto→Mail took ${ELAPSED_MS}ms (>2s); prewarm Mail in Pace settings for draft streaming"
  fi
else
  fail "Mail did not appear after mailto:"
fi

echo
echo "▶ Real-app smoke — executor dry-run unit coverage"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  beta_xcode="$(find /Applications -maxdepth 1 -name 'Xcode*.app' -type d 2>/dev/null | sort | tail -1)"
  if [[ -n "$beta_xcode" ]]; then
    export DEVELOPER_DIR="$beta_xcode/Contents/Developer"
  fi
fi
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-pace.sh" PaceActionExecutorDryRunTests >/dev/null
pass "PaceActionExecutorDryRunTests green"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "✅ real-app smoke passed"
  exit 0
fi

echo "❌ real-app smoke: $FAILURES failure(s)"
exit "$FAILURES"
