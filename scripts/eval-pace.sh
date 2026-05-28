#!/usr/bin/env bash
#
# eval-pace.sh — run the Pace eval suite against the running LM Studio.
#
# Two evals per fixture:
#   1. Latency: time-to-first-byte of the chat-completions response (TTFT
#      proxy). Compared against the fixture's `max_ttft_ms`.
#   2. Correctness: regex must-contain / must-not-contain checks against
#      the planner's response content. Catches markdown leaks, action
#      tags appearing where they shouldn't, forbidden words, etc.
#
# Reads the planner base URL + model identifier from Info.plist so the
# evals always reflect Pace's actual runtime config.
#
# Usage
# -----
#   ./scripts/eval-pace.sh                       # run every fixture
#   ./scripts/eval-pace.sh qa-no-screen          # one fixture by name
#   ./scripts/eval-pace.sh --no-latency          # correctness only
#   ./scripts/eval-pace.sh --model qwen/qwen3-30b-a3b
#                                                # A/B against a different model
#
# Exits non-zero if any fixture fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EVALS_DIR="$PROJECT_DIR/evals"
FIXTURES_DIR="$EVALS_DIR/fixtures"
INFO_PLIST_PATH="$PROJECT_DIR/leanring-buddy/Info.plist"

if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo "❌ Fixtures directory not found: $FIXTURES_DIR" >&2
    exit 2
fi

ENFORCE_LATENCY_CHECKS=true
SINGLE_FIXTURE_NAME=""
MODEL_OVERRIDE=""
PARSE_NEXT_AS_MODEL=false
for argument in "$@"; do
    if [[ "$PARSE_NEXT_AS_MODEL" == "true" ]]; then
        MODEL_OVERRIDE="$argument"
        PARSE_NEXT_AS_MODEL=false
        continue
    fi
    case "$argument" in
        --no-latency) ENFORCE_LATENCY_CHECKS=false ;;
        --model) PARSE_NEXT_AS_MODEL=true ;;
        --help|-h)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *) SINGLE_FIXTURE_NAME="$argument" ;;
    esac
done

# Pull endpoint + model from Info.plist so we evaluate whatever Pace
# actually calls — no stale duplication.
read_plist_string() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST_PATH" 2>/dev/null || echo ""
}

PLANNER_BASE_URL=$(read_plist_string "LocalPlannerBaseURL")
[[ -z "$PLANNER_BASE_URL" ]] && PLANNER_BASE_URL="http://localhost:1234/v1"
PLANNER_MODEL_IDENTIFIER=$(read_plist_string "LocalPlannerModelIdentifier")
[[ -z "$PLANNER_MODEL_IDENTIFIER" ]] && PLANNER_MODEL_IDENTIFIER="qwen/qwen3-14b"

# `--model <id>` overrides the Info.plist value for this run only.
# Use it to A/B test a different model loaded in LM Studio without
# editing Info.plist + rebuilding the app.
if [[ -n "$MODEL_OVERRIDE" ]]; then
    PLANNER_MODEL_IDENTIFIER="$MODEL_OVERRIDE"
fi

CHAT_COMPLETIONS_URL="${PLANNER_BASE_URL%/}/chat/completions"

echo "▶ Pace evals"
echo "  Planner: $PLANNER_MODEL_IDENTIFIER @ $CHAT_COMPLETIONS_URL"
[[ "$ENFORCE_LATENCY_CHECKS" == "false" ]] && echo "  (latency checks: SKIPPED)"
echo

TOTAL_FIXTURE_COUNT=0
PASSED_FIXTURE_COUNT=0
FAILED_FIXTURE_COUNT=0

# Per-fixture report rows accumulated for the summary table.
REPORT_ROWS=()

run_single_fixture() {
    local fixture_path="$1"
    local fixture_name
    fixture_name=$(basename "$fixture_path" .json)

    local fixture_category
    fixture_category=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("category", "uncategorized"))
' "$fixture_path")

    local max_ttft_ms
    max_ttft_ms=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("expectations", {}).get("max_ttft_ms", 0))
' "$fixture_path")

    # Delegate the actual request + streaming-aware timing to the
    # Python helper. Bash + curl can't cleanly measure "time to first
    # content delta in an SSE stream" — `time_starttransfer` only
    # marks header arrival, not the first generated token. The helper
    # returns a JSON line with ttft_ms (time-to-first-content-token),
    # total_ms (full stream finish), content (post-think), and
    # http_status.
    local helper_output
    helper_output=$(python3 "$EVALS_DIR/run_fixture.py" \
        "$fixture_path" \
        "$CHAT_COMPLETIONS_URL" \
        "$PLANNER_MODEL_IDENTIFIER" 2>&1 || true)

    local actual_ttft_ms
    actual_ttft_ms=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.argv[1]).get('ttft_ms', 0))
except Exception:
    print(0)
" "$helper_output")

    local total_ms
    total_ms=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.argv[1]).get('total_ms', 0))
except Exception:
    print(0)
" "$helper_output")

    local http_status_code
    http_status_code=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.argv[1]).get('http_status', 0))
except Exception:
    print(0)
" "$helper_output")

    local response_message_content
    response_message_content=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.argv[1]).get('content', ''))
except Exception:
    print('')
" "$helper_output")

    local fixture_status="PASS"
    local failure_details=""

    if [[ "$http_status_code" != "200" ]]; then
        fixture_status="FAIL"
        failure_details="HTTP $http_status_code — $(echo "$response_message_content" | head -c 200)"
    else
        # Correctness checks. Run against the post-think content the
        # helper already extracted, so the regex sees the actual
        # spoken text.
        local correctness_failure_message
        correctness_failure_message=$(python3 -c '
import json, re, sys
fixture = json.load(open(sys.argv[1]))
content = sys.argv[2]
expectations = fixture.get("expectations", {})
failures = []
for pattern in expectations.get("must_contain_patterns", []):
    if not re.search(pattern, content):
        failures.append(f"missing pattern: {pattern!r}")
for pattern in expectations.get("must_not_contain_patterns", []):
    if re.search(pattern, content):
        failures.append(f"forbidden pattern present: {pattern!r}")
print("; ".join(failures))
' "$fixture_path" "$response_message_content")

        if [[ -n "$correctness_failure_message" ]]; then
            fixture_status="FAIL"
            failure_details="$correctness_failure_message"
        fi

        # Latency check against TTFT (not total).
        if [[ "$ENFORCE_LATENCY_CHECKS" == "true" && "$max_ttft_ms" -gt 0 ]]; then
            if [[ "$actual_ttft_ms" -gt "$max_ttft_ms" ]]; then
                if [[ "$fixture_status" == "PASS" ]]; then
                    fixture_status="FAIL"
                fi
                local latency_message="ttft ${actual_ttft_ms}ms > budget ${max_ttft_ms}ms"
                if [[ -n "$failure_details" ]]; then
                    failure_details="$failure_details; $latency_message"
                else
                    failure_details="$latency_message"
                fi
            fi
        fi
    fi

    local icon="✅"
    if [[ "$fixture_status" == "FAIL" ]]; then icon="❌"; fi
    REPORT_ROWS+=("$icon|$fixture_name|$fixture_category|${actual_ttft_ms}ms|${total_ms}ms|${max_ttft_ms}ms|$failure_details")
    TOTAL_FIXTURE_COUNT=$((TOTAL_FIXTURE_COUNT + 1))
    if [[ "$fixture_status" == "PASS" ]]; then
        PASSED_FIXTURE_COUNT=$((PASSED_FIXTURE_COUNT + 1))
    else
        FAILED_FIXTURE_COUNT=$((FAILED_FIXTURE_COUNT + 1))
    fi

    echo "  $icon $fixture_name ($fixture_category) — TTFT ${actual_ttft_ms}ms / total ${total_ms}ms"
    if [[ "$fixture_status" == "FAIL" ]]; then
        if [[ -n "$failure_details" ]]; then
            echo "      $failure_details"
        fi
        # On correctness failures, show the actual post-think response
        # so we can diagnose what the model emitted instead of what we
        # expected. Capped at 500 chars to keep the report readable.
        if [[ -n "$response_message_content" ]]; then
            local snippet
            snippet=$(echo "$response_message_content" | head -c 500 | tr '\n' ' ')
            echo "      response: $snippet"
        fi
    fi
}

# Iterate fixtures (filtered by name if user specified one).
if [[ -n "$SINGLE_FIXTURE_NAME" ]]; then
    SELECTED_FIXTURE_PATH="$FIXTURES_DIR/$SINGLE_FIXTURE_NAME.json"
    if [[ ! -f "$SELECTED_FIXTURE_PATH" ]]; then
        echo "❌ Fixture not found: $SELECTED_FIXTURE_PATH" >&2
        exit 2
    fi
    run_single_fixture "$SELECTED_FIXTURE_PATH"
else
    for fixture_path in "$FIXTURES_DIR"/*.json; do
        [[ -e "$fixture_path" ]] || continue
        run_single_fixture "$fixture_path"
    done
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo "Summary"
echo "═══════════════════════════════════════════════════════════════"
printf "| %-2s | %-30s | %-18s | %8s | %8s | %8s | %s\n" "" "Fixture" "Category" "TTFT" "Total" "Budget" "Details"
printf "| %-2s | %-30s | %-18s | %8s | %8s | %8s | %s\n" "--" "------------------------------" "------------------" "--------" "--------" "--------" "-------"
for row in "${REPORT_ROWS[@]}"; do
    IFS='|' read -r icon name category ttft total budget details <<< "$row"
    printf "| %-2s | %-30s | %-18s | %8s | %8s | %8s | %s\n" "$icon" "$name" "$category" "$ttft" "$total" "$budget" "$details"
done

echo
if [[ "$FAILED_FIXTURE_COUNT" -eq 0 ]]; then
    echo "✅ All $TOTAL_FIXTURE_COUNT fixtures passed."
    exit 0
else
    echo "❌ $FAILED_FIXTURE_COUNT of $TOTAL_FIXTURE_COUNT fixtures failed."
    exit 1
fi
