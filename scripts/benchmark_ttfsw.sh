#!/usr/bin/env bash
#
# benchmark_ttfsw.sh — aggregate Pace's per-turn latency + throughput
# numbers from the macOS unified log.
#
# Why this exists
# ---------------
# The product positioning is "the fastest voice tool in the market."
# The research agent that surveyed the May-2026 landscape was explicit:
# the speed claim is empty without a published, reproducible benchmark.
# RCLI publishes sub-200ms E2E and 550 tok/s — this script lets Pace
# publish comparable numbers.
#
# The Swift app emits these metrics on every turn:
#   - TTFSW=NNNms  (PTT-release → first TTS dispatch)  — the headline
#   - TTFT=NNNms   (planner HTTP send → first SSE token) — diagnostic
#   - E2E=NNNms    (PTT press → last spoken word)       — user-perceived
#   - STT=NNNms    (PTT press → transcript ready)       — STT isolation
#   - VLM=NNNms    (screenshot → element map)           — VLM isolation
#   - TPS=N.N      (planner tokens/second)              — throughput
#   - RAG=NNNms    (retrieval query latency)            — RAG isolation
# All go through `PaceTelemetryLog` (OSLog subsystem `com.pace.app`,
# category `metrics`), which is what makes the unified log queryable.
#
# Usage
# -----
#   ./scripts/benchmark_ttfsw.sh                      # last 30 minutes
#   ./scripts/benchmark_ttfsw.sh --last 10m           # last 10 minutes
#   ./scripts/benchmark_ttfsw.sh --last 2h            # last 2 hours
#   ./scripts/benchmark_ttfsw.sh --live               # stream as Pace runs
#   ./scripts/benchmark_ttfsw.sh --file pace.log      # parse a saved file
#
# Exit codes: 0 on success (including "no samples found"), 2 on bad args.

set -euo pipefail

LOG_PREDICATE='subsystem == "com.pace.app" AND category == "metrics"'
LAST_WINDOW="30m"
MODE="show"
INPUT_FILE=""

usage() {
    sed -n '2,28p' "$0"
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)
            LAST_WINDOW="${2:?--last needs an argument like 10m or 2h}"
            MODE="show"
            shift 2
            ;;
        --live)
            MODE="live"
            shift
            ;;
        --file)
            INPUT_FILE="${2:?--file needs a path}"
            MODE="file"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown arg: $1" >&2
            usage
            ;;
    esac
done

# stats_from_stream: read a stream of metric strings on stdin,
# print a markdown row for each metric. Handles both <key>=NNNms
# (latency metrics) and TPS=N.N (throughput metric).
stats_from_stream() {
    awk '
        {
            while (match($0, /(TTFSW|TTFT|E2E|STT|VLM|RAG)=([0-9]+)ms/)) {
                kv = substr($0, RSTART, RLENGTH)
                eq = index(kv, "=")
                key = substr(kv, 1, eq - 1)
                value = substr(kv, eq + 1, length(kv) - eq - 2)
                samples[key] = samples[key] " " value
                $0 = substr($0, RSTART + RLENGTH)
            }
            while (match($0, /TPS=([0-9]+\.[0-9]+)/)) {
                kv = substr($0, RSTART, RLENGTH)
                eq = index(kv, "=")
                value = substr(kv, eq + 1)
                samples["TPS"] = samples["TPS"] " " value
                $0 = substr($0, RSTART + RLENGTH)
            }
        }
        END {
            print "| Metric | n | min | p50 | p95 | max | mean |"
            print "|---|---:|---:|---:|---:|---:|---:|"
            for (key in samples) {
                n = split(samples[key], values, " ")
                count = 0
                for (i = 1; i <= n; i++) {
                    if (values[i] != "") {
                        count++
                        sorted[count] = values[i] + 0
                        sum += values[i] + 0
                    }
                }
                if (count == 0) continue
                for (i = 2; i <= count; i++) {
                    cur = sorted[i]
                    j = i - 1
                    while (j > 0 && sorted[j] > cur) {
                        sorted[j+1] = sorted[j]
                        j--
                    }
                    sorted[j+1] = cur
                }
                p50_idx = int((count + 1) / 2)
                p95_idx = int(count * 95 / 100)
                if (p95_idx < 1) p95_idx = 1
                if (p95_idx > count) p95_idx = count
                mean = sum / count
                if (key == "TPS") {
                    printf "| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f |\n", \
                        key, count, sorted[1], sorted[p50_idx], sorted[p95_idx], \
                        sorted[count], mean
                } else {
                    printf "| %s | %d | %d | %d | %d | %d | %d |\n", \
                        key, count, sorted[1], sorted[p50_idx], sorted[p95_idx], \
                        sorted[count], int(mean)
                }
                sum = 0
                delete sorted
            }
        }
    '
}

case "$MODE" in
    show)
        echo "▶ Pace TTFSW benchmark — last $LAST_WINDOW"
        echo "  (predicate: $LOG_PREDICATE)"
        echo
        log show --last "$LAST_WINDOW" --predicate "$LOG_PREDICATE" --info --style compact 2>/dev/null \
            | stats_from_stream
        ;;
    live)
        echo "▶ Pace TTFSW benchmark — live stream (Ctrl-C to stop and print stats)"
        echo "  (predicate: $LOG_PREDICATE)"
        echo
        # Accumulate into a temp file so we can compute stats at exit.
        ACCUMULATED="$(mktemp -t pace_ttfsw.XXXXXX)"
        trap 'echo; echo "▶ Stopping stream — computing stats…"; stats_from_stream <"$ACCUMULATED"; rm -f "$ACCUMULATED"; exit 0' INT TERM
        log stream --predicate "$LOG_PREDICATE" --info --style compact \
            | tee -a "$ACCUMULATED"
        ;;
    file)
        if [[ ! -f "$INPUT_FILE" ]]; then
            echo "File not found: $INPUT_FILE" >&2
            exit 2
        fi
        echo "▶ Pace TTFSW benchmark — file: $INPUT_FILE"
        echo
        stats_from_stream <"$INPUT_FILE"
        ;;
esac
