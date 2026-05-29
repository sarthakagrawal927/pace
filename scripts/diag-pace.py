#!/usr/bin/env python3
"""
diag-pace.py — Pace runtime self-diagnostic.

Why this exists
---------------
After every code change the loop has been: rebuild Pace, hold push-to-
talk, speak, read the Xcode console, judge. That makes me (the agent)
useless for validation between changes — the user has to be the QA.

This script removes that bottleneck. It exercises the exact LM Studio
call pattern Pace uses on every turn (VLM first, then planner), measures
per-call latency, and flags two of the most common runtime failure
modes empirically:

  1. **Model thrashing** — LM Studio evicting the VLM when the planner
     loads (or vice versa). Symptom: every call has a 5-10s "cold load"
     TTFT instead of warm-cache TTFT. The thrash detector sees this as
     all-calls-slow or alternating-slow.

  2. **VLM JSON parse fragility** — the VLM sometimes returns malformed
     JSON missing the `description` field (especially the 2B model on
     dense screens like Xcode). This script sends a synthetic image
     and asserts the response decodes into Pace's expected shape.

Reads model identifiers from Info.plist so it tests EXACTLY what Pace
will use at runtime. Doesn't touch any Pace state — only talks HTTP
to LM Studio.

Usage
-----
  ./scripts/diag-pace.py                  # full diagnostic
  ./scripts/diag-pace.py --quick          # 3 alternating calls instead of 6
  ./scripts/diag-pace.py --no-load        # skip lms load (assume both already loaded)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
INFO_PLIST = PROJECT_DIR / "leanring-buddy" / "Info.plist"
LMS_BIN = os.environ.get("LMS_BIN", str(Path.home() / ".lmstudio" / "bin" / "lms"))

def _build_test_png_base64() -> str:
    """Generate a 96x96 grayscale gradient PNG using only stdlib.

    Why bigger than 1×1: ui-venus and several other LM Studio VLMs reject
    very small images with HTTP 400 "Invalid image detected". 96×96 is
    large enough to be accepted while still encoding to ~250 bytes of
    PNG, keeping the request body small.
    """
    import base64
    import struct
    import zlib

    width = 96
    height = 96

    def chunk(chunk_type: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(chunk_type + data)
        return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)

    png_signature = b"\x89PNG\r\n\x1a\n"
    # IHDR: width, height, bit-depth=8, color-type=0 (grayscale),
    # compression=0, filter=0, interlace=0
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)

    raw_image_bytes = bytearray()
    for y in range(height):
        raw_image_bytes.append(0)  # filter type 0 (None) per scanline
        for x in range(width):
            raw_image_bytes.append((x + y) * 2 % 256)  # simple gradient

    compressed_image = zlib.compress(bytes(raw_image_bytes))
    png_bytes = (
        png_signature
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", compressed_image)
        + chunk(b"IEND", b"")
    )
    return base64.b64encode(png_bytes).decode("ascii")


TEST_PNG_BASE64 = _build_test_png_base64()


# ---------------------------------------------------------------------------
# ANSI colouring — pure stdlib, falls back to plain text if not a TTY.
# ---------------------------------------------------------------------------


def _is_tty() -> bool:
    return sys.stdout.isatty()


def _colour(code: str, text: str) -> str:
    if not _is_tty():
        return text
    return f"\033[{code}m{text}\033[0m"


def red(text: str) -> str:
    return _colour("31", text)


def green(text: str) -> str:
    return _colour("32", text)


def yellow(text: str) -> str:
    return _colour("33", text)


def cyan(text: str) -> str:
    return _colour("36", text)


def bold(text: str) -> str:
    return _colour("1", text)


# ---------------------------------------------------------------------------
# Info.plist reader
# ---------------------------------------------------------------------------


def read_info_plist_value(key: str) -> str | None:
    try:
        completed = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(INFO_PLIST)],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip() or None


# ---------------------------------------------------------------------------
# LM Studio model lifecycle helpers
# ---------------------------------------------------------------------------


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str
    # "fail" — counts toward the exit code; verify.sh will block commits.
    # "warn" — surface the issue but don't gate. Use for symptoms Pace's
    #          code already tolerates (e.g. ui-venus dropping description,
    #          which the parser now handles transparently).
    severity: str = "fail"

    @property
    def is_blocking_failure(self) -> bool:
        return (not self.passed) and self.severity == "fail"

    def render(self) -> str:
        if self.passed:
            marker = green("PASS")
        elif self.severity == "warn":
            marker = yellow("WARN")
        else:
            marker = red("FAIL")
        return f"  [{marker}] {self.name} — {self.detail}"


def lms_ps_loaded_identifiers() -> list[str]:
    completed = subprocess.run(
        [LMS_BIN, "ps"], capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        return []
    loaded: list[str] = []
    for line in completed.stdout.splitlines():
        if not line.strip() or line.lower().startswith("identifier"):
            continue
        # First column is the identifier. Split on 2+ spaces to keep model
        # names with spaces intact (unlikely here, but defensive).
        parts = re.split(r"\s{2,}", line.strip())
        if parts:
            loaded.append(parts[0])
    return loaded


def lms_load(identifier: str) -> bool:
    print(f"  ⬇ loading {identifier} …", flush=True)
    completed = subprocess.run(
        [LMS_BIN, "load", identifier],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if completed.returncode != 0:
        print(f"     {red('failed')}: {completed.stderr.strip()}")
        return False
    print(f"     {green('loaded')}")
    return True


def lm_studio_reachable(base_url: str) -> bool:
    try:
        with urllib.request.urlopen(f"{base_url.rstrip('/')}/models", timeout=2):
            return True
    except (urllib.error.URLError, TimeoutError):
        return False


# ---------------------------------------------------------------------------
# Call adapters
# ---------------------------------------------------------------------------


def call_vlm(base_url: str, model: str) -> tuple[int, str | None, dict | None]:
    """Returns (elapsed_ms, error_message_or_none, parsed_payload_or_none)."""
    chat_url = f"{base_url.rstrip('/')}/chat/completions"
    body = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a UI vision model. Output STRICT JSON only with this "
                    'schema: {"elements":[{"label":"<≤4 words>","role":"button|'
                    'text_field|static_text|other","bbox":[x,y,w,h],"text":'
                    '"<verbatim or null>"}],"description":"<≤20 words>"}'
                ),
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "User intent: test. Return the JSON element map.",
                    },
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:image/png;base64,{TEST_PNG_BASE64}"
                        },
                    },
                ],
            },
        ],
        "temperature": 0.1,
        "max_tokens": 800,
    }
    started_at = time.monotonic()
    request = urllib.request.Request(
        chat_url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer lm-studio",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response_stream:
            response_body = response_stream.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as http_error:
        return (
            int((time.monotonic() - started_at) * 1000),
            f"HTTP {http_error.code}: {http_error.read().decode('utf-8', errors='replace')[:200]}",
            None,
        )
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return (
            int((time.monotonic() - started_at) * 1000),
            f"transport: {transport_error}",
            None,
        )

    elapsed_ms = int((time.monotonic() - started_at) * 1000)
    try:
        payload = json.loads(response_body)
        message_content = payload["choices"][0]["message"]["content"]
    except (KeyError, json.JSONDecodeError, TypeError, IndexError) as parse_err:
        return elapsed_ms, f"unwrap error: {parse_err}", None

    # Extract the JSON object from the message content — VLM may wrap
    # in prose or markdown fences. Same extractor logic as
    # LocalVLMClient.extractJSONObjectString.
    first_brace = message_content.find("{")
    last_brace = message_content.rfind("}")
    if first_brace == -1 or last_brace == -1 or last_brace <= first_brace:
        return elapsed_ms, f"no JSON braces in: {message_content[:200]!r}", None
    json_substring = message_content[first_brace : last_brace + 1]
    try:
        parsed_vlm_payload = json.loads(json_substring)
    except json.JSONDecodeError as parse_err:
        return elapsed_ms, f"inner JSON parse: {parse_err}", None
    return elapsed_ms, None, parsed_vlm_payload


def call_planner(base_url: str, model: str) -> tuple[int, str | None]:
    """Sends Pace's exact planner request shape. Returns (elapsed_ms, error)."""
    chat_url = f"{base_url.rstrip('/')}/chat/completions"
    body = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are pace, a voice assistant. Always respond with strict "
                    'JSON: {"spokenText":"<short reply>","pointAtElementId":-1,'
                    '"clickElementId":-1}'
                ),
            },
            {
                "role": "user",
                "content": (
                    "On-device screen analysis (auto-extracted):\n\n"
                    "=== primary focus ===\n"
                    "[0] button|412,40|search button|Search\n\n"
                    "User said: hello"
                ),
            },
        ],
        "temperature": 0,
        "max_tokens": 200,
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": "PaceTurn",
                "strict": True,
                "schema": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "spokenText": {"type": "string"},
                        "pointAtElementId": {"type": "integer"},
                        "clickElementId": {"type": "integer"},
                    },
                    "required": [
                        "spokenText",
                        "pointAtElementId",
                        "clickElementId",
                    ],
                },
            },
        },
    }
    started_at = time.monotonic()
    request = urllib.request.Request(
        chat_url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer lm-studio",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response_stream:
            response_body = response_stream.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as http_error:
        return (
            int((time.monotonic() - started_at) * 1000),
            f"HTTP {http_error.code}: {http_error.read().decode('utf-8', errors='replace')[:200]}",
        )
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return (
            int((time.monotonic() - started_at) * 1000),
            f"transport: {transport_error}",
        )

    elapsed_ms = int((time.monotonic() - started_at) * 1000)
    # Just verify response parses — we don't care about contents here,
    # only about whether the call completed at all and how long it took.
    try:
        payload = json.loads(response_body)
        _ = payload["choices"][0]["message"]["content"]
    except (KeyError, json.JSONDecodeError, TypeError, IndexError) as parse_err:
        return elapsed_ms, f"unwrap error: {parse_err}"
    return elapsed_ms, None


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------


def diagnose_thrash(
    base_url: str,
    vlm_model: str,
    planner_model: str,
    call_count: int,
) -> list[CheckResult]:
    """Alternates VLM and planner calls, looking for the latency pattern
    that indicates LM Studio is evicting one to make room for the other.

    Without thrash: per-call latencies are roughly stable across the run.
    With thrash: every call carries a cold-load penalty (multi-second TTFT),
    so per-call latencies are uniformly high AND highly variable.
    """
    print(bold(f"\n▶ Thrash check: {call_count} alternating VLM+planner calls"))

    vlm_latencies: list[int] = []
    planner_latencies: list[int] = []
    errors: list[str] = []

    for call_index in range(call_count):
        # VLM call
        vlm_elapsed_ms, vlm_error, _ = call_vlm(base_url, vlm_model)
        vlm_latencies.append(vlm_elapsed_ms)
        print(
            f"  turn {call_index + 1}  VLM     {vlm_elapsed_ms:>5}ms"
            + (f"  {red(vlm_error)}" if vlm_error else "")
        )
        if vlm_error:
            errors.append(f"VLM turn {call_index + 1}: {vlm_error}")

        # Planner call
        planner_elapsed_ms, planner_error = call_planner(base_url, planner_model)
        planner_latencies.append(planner_elapsed_ms)
        print(
            f"  turn {call_index + 1}  planner {planner_elapsed_ms:>5}ms"
            + (f"  {red(planner_error)}" if planner_error else "")
        )
        if planner_error:
            errors.append(f"planner turn {call_index + 1}: {planner_error}")

    results: list[CheckResult] = []

    if errors:
        results.append(
            CheckResult(
                "no transport errors during thrash run",
                False,
                f"{len(errors)} call(s) failed — see log above",
            )
        )
    else:
        results.append(
            CheckResult(
                "no transport errors during thrash run",
                True,
                f"{call_count * 2} calls completed",
            )
        )

    # Thrash heuristic only applies to calls that actually completed.
    # A stable string of HTTP 400s isn't "stable" in any useful sense —
    # we want stability of SUCCESSFUL calls. The successful-call latency
    # tells us whether the model is being evicted between turns.
    vlm_successful_latencies = [
        latency
        for latency, error in zip(vlm_latencies, [None] * len(vlm_latencies))
        if True  # placeholder so the comprehension stays parallel-safe below
    ]
    # Actually pair latencies with error positions to filter.
    vlm_successful_latencies = []
    planner_successful_latencies = []
    for index, latency in enumerate(vlm_latencies):
        if f"VLM turn {index + 1}: " not in "\n".join(errors):
            vlm_successful_latencies.append(latency)
    for index, latency in enumerate(planner_latencies):
        if f"planner turn {index + 1}: " not in "\n".join(errors):
            planner_successful_latencies.append(latency)

    if len(vlm_successful_latencies) >= 2:
        vlm_median = statistics.median(vlm_successful_latencies)
        vlm_max = max(vlm_successful_latencies)
        vlm_thrash_ratio = vlm_max / max(vlm_median, 1)
        results.append(
            CheckResult(
                "VLM latency stable (no eviction by planner)",
                vlm_thrash_ratio < 8.0,
                f"median {int(vlm_median)}ms, max {vlm_max}ms (max/median = {vlm_thrash_ratio:.1f}×)",
            )
        )
    elif vlm_latencies:
        results.append(
            CheckResult(
                "VLM latency stable (no eviction by planner)",
                False,
                "skipped — too few successful VLM calls to assess",
            )
        )

    if len(planner_successful_latencies) >= 2:
        planner_median = statistics.median(planner_successful_latencies)
        planner_max = max(planner_successful_latencies)
        planner_thrash_ratio = planner_max / max(planner_median, 1)
        results.append(
            CheckResult(
                "planner latency stable (no eviction by VLM)",
                planner_thrash_ratio < 8.0,
                f"median {int(planner_median)}ms, max {planner_max}ms (max/median = {planner_thrash_ratio:.1f}×)",
            )
        )
    elif planner_latencies:
        results.append(
            CheckResult(
                "planner latency stable (no eviction by VLM)",
                False,
                "skipped — too few successful planner calls to assess",
            )
        )

    # Absolute thresholds. Even without thrash, very slow planner calls
    # (>3s median) point at LM Studio config or hardware issues.
    if planner_successful_latencies:
        median_ms = int(statistics.median(planner_successful_latencies))
        results.append(
            CheckResult(
                "planner median latency under 3s",
                median_ms < 3000,
                f"{median_ms}ms",
            )
        )

    return results


def diagnose_planner_behavior(planner_model: str) -> list[CheckResult]:
    """Delegate to eval-planners.py for the configured planner and parse
    its summary line so a single diag-pace.py call asserts behavior
    regressions alongside runtime health.

    `eval-planners.py` writes a summary like:

        - **qwen/qwen3-30b-a3b**: 15/15 pass, mean latency 925ms

    We pull pass count and mean latency out of that line and turn them
    into CheckResult entries with strict thresholds.
    """
    print(bold(f"\n▶ Planner behavior eval ({planner_model})"))
    results: list[CheckResult] = []

    eval_script_path = SCRIPT_DIR / "eval-planners.py"
    if not eval_script_path.exists():
        results.append(
            CheckResult(
                "planner behavior eval available",
                False,
                f"missing: {eval_script_path}",
            )
        )
        return results

    # --no-load is critical here: diag-pace.py already ensured both models
    # are resident in the Loading phase. Without --no-load, eval-planners.py
    # would lms-load the planner a second time, creating a duplicate `:2`
    # slot that wastes ~18 GB and breaks routing — every fixture then
    # appears to fail with parse errors. The "0/15 pass" symptom of that
    # bug used to corrupt the diag-pace summary.
    completed = subprocess.run(
        [
            sys.executable,
            str(eval_script_path),
            "--models",
            planner_model,
            "--no-load",
        ],
        capture_output=True,
        text=True,
        timeout=900,
    )

    # Always echo the eval's summary block so a human reader (or me)
    # can see per-fixture verdicts without scrolling the raw stdout.
    summary_marker = "### Summary"
    if summary_marker in completed.stdout:
        summary_section = completed.stdout.split(summary_marker, 1)[1].strip()
        # Show only the first ~600 chars to keep diag output focused.
        print(summary_section[:600])

    pass_pattern = re.compile(
        rf"\*\*{re.escape(planner_model)}\*\*: (\d+)/(\d+) pass, mean latency (\d+)ms"
    )
    pass_match = pass_pattern.search(completed.stdout)
    if not pass_match:
        results.append(
            CheckResult(
                "planner behavior eval completed",
                False,
                f"could not parse summary from eval-planners.py output. stderr head: {completed.stderr[:200]}",
            )
        )
        return results

    passed_count = int(pass_match.group(1))
    total_count = int(pass_match.group(2))
    mean_latency_ms = int(pass_match.group(3))

    results.append(
        CheckResult(
            "planner passes every fixture",
            passed_count == total_count,
            f"{passed_count}/{total_count} pass",
        )
    )
    # Sub-3s mean across the full eval (which includes long-list-pick-target,
    # the heaviest fixture) is the bar for "snappy enough to ship".
    results.append(
        CheckResult(
            "planner mean eval latency under 3s",
            mean_latency_ms < 3000,
            f"{mean_latency_ms}ms",
        )
    )
    return results


def diagnose_vlm_json_health(
    base_url: str, vlm_model: str
) -> list[CheckResult]:
    """Sends two VLM calls (ui-venus-2b is non-deterministic on what
    fields it includes — single sample is too flaky) and checks the
    response decodes into Pace's expected shape.

    The `description` field is checked across samples: pass if ANY sample
    includes it. Pace's decoder now tolerates a missing description (see
    LocalVLMScreenAnalysisDecoderTests), so a single drop is no longer
    a hard failure for the app — only a chronic absence indicates a
    VLM regression worth flagging.
    """
    print(bold("\n▶ VLM JSON health check (2 samples)"))
    samples: list[tuple[int, str | None, dict | None]] = []
    for sample_index in range(2):
        sample = call_vlm(base_url, vlm_model)
        samples.append(sample)
        elapsed_ms, error, payload = sample
        if error:
            print(f"  sample {sample_index + 1}: ERROR after {elapsed_ms}ms — {error}")
        else:
            has_desc = isinstance((payload or {}).get("description"), str)
            print(
                f"  sample {sample_index + 1}: {elapsed_ms}ms, "
                f"elements={len((payload or {}).get('elements') or [])}, "
                f"description={'yes' if has_desc else 'NO'}"
            )

    results: list[CheckResult] = []

    any_decoded = any(payload is not None for _, _, payload in samples)
    results.append(
        CheckResult(
            "VLM returned JSON-decodable payload (>=1 of 2 samples)",
            any_decoded,
            "ok" if any_decoded else "all samples errored",
        )
    )
    if not any_decoded:
        return results

    any_elements = any(
        isinstance((payload or {}).get("elements"), list)
        for _, _, payload in samples
        if payload is not None
    )
    results.append(
        CheckResult(
            "payload has `elements` array (>=1 of 2 samples)",
            any_elements,
            "ok" if any_elements else "no sample had a list under `elements`",
        )
    )

    any_description = any(
        isinstance((payload or {}).get("description"), str)
        for _, _, payload in samples
        if payload is not None
    )
    # severity="warn" — Pace's decoder defaults missing description to ""
    # since the LocalVLMScreenAnalysis parser hardening in commit 197993a.
    # The 2B VLM is known to drop the field on simple test images, so
    # this isn't a blocking regression — surface it as a heads-up but
    # don't fail the gate.
    results.append(
        CheckResult(
            "payload has `description` string in >=1 of 2 samples",
            any_description,
            "ok"
            if any_description
            else (
                "BOTH samples missing description — ui-venus dropped the "
                "field. Pace's decoder defaults it to '' so this is non-"
                "blocking, but if it's chronic and the element list also "
                "looks sparse, consider a larger VLM."
            ),
            severity="warn",
        )
    )
    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Pace runtime self-diagnostic — verifies LM Studio + VLM + planner are healthy without needing a Pace.app run."
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="3 alternating calls instead of 6 (faster, less reliable thrash signal)",
    )
    parser.add_argument(
        "--no-load",
        action="store_true",
        help="Skip `lms load` — assume both models are already resident",
    )
    parser.add_argument(
        "--eval",
        action="store_true",
        help="Also run the planner behavior eval (delegates to eval-planners.py). "
        "Adds ~30-60s but catches regressions runtime health alone misses.",
    )
    args = parser.parse_args(argv)

    call_count = 3 if args.quick else 6

    base_url = read_info_plist_value("LocalPlannerBaseURL") or "http://localhost:1234/v1"
    vlm_model = read_info_plist_value("LocalVLMModelIdentifier")
    planner_model = read_info_plist_value("LocalPlannerModelIdentifier")

    print(bold("Pace runtime diagnostic"))
    print(f"  config from {INFO_PLIST.name}:")
    print(f"    {cyan('base url      ')}  {base_url}")
    print(f"    {cyan('VLM model     ')}  {vlm_model}")
    print(f"    {cyan('planner model ')}  {planner_model}")

    if not vlm_model or not planner_model:
        print(red("\n❌ Missing VLM or planner identifier in Info.plist — aborting."))
        return 2

    print(bold("\n▶ Preflight"))
    preflight_results: list[CheckResult] = []

    server_up = lm_studio_reachable(base_url)
    preflight_results.append(
        CheckResult(
            "LM Studio server reachable",
            server_up,
            base_url if server_up else "no response — start LM Studio first",
        )
    )

    if not server_up:
        for result in preflight_results:
            print(result.render())
        print(red("\n❌ Aborting — LM Studio isn't responding."))
        return 1

    for result in preflight_results:
        print(result.render())

    # Load both models if requested. We want both resident — that's the
    # configuration Pace's actual runtime needs.
    if not args.no_load:
        print(bold("\n▶ Loading models (both must stay resident)"))
        before_load = lms_ps_loaded_identifiers()
        print(f"  before: {before_load or '(none)'}")
        if vlm_model not in before_load:
            if not lms_load(vlm_model):
                return 1
        if planner_model not in before_load:
            if not lms_load(planner_model):
                return 1
        after_load = lms_ps_loaded_identifiers()
        print(f"  after:  {after_load or '(none)'}")

        both_loaded = vlm_model in after_load and planner_model in after_load
        if not both_loaded:
            print(
                yellow(
                    f"\n⚠ One of the models did not stay resident — LM Studio likely "
                    f"has a single-model slot configured. Open LM Studio → Developer "
                    f"settings and raise the max-loaded-models or per-model memory "
                    f"budget. Currently loaded: {after_load}"
                )
            )

    # Thrash check
    thrash_results = diagnose_thrash(base_url, vlm_model, planner_model, call_count)

    # VLM JSON health check (one extra call against the VLM)
    vlm_health_results = diagnose_vlm_json_health(base_url, vlm_model)

    # Optional planner behavior eval — slower but catches behavior
    # regressions thrash + VLM-health alone won't see (e.g. the planner
    # starts hallucinating element IDs after a prompt change).
    behavior_results: list[CheckResult] = []
    if args.eval:
        behavior_results = diagnose_planner_behavior(planner_model)

    all_results = thrash_results + vlm_health_results + behavior_results

    # Summary
    print(bold("\n▶ Summary"))
    for result in all_results:
        print(result.render())

    blocking_failures = [r for r in all_results if r.is_blocking_failure]
    warnings = [r for r in all_results if not r.passed and r.severity == "warn"]

    if warnings:
        print(yellow(f"\n⚠ {len(warnings)} non-blocking warning(s) — see WARN lines above"))

    if blocking_failures:
        print(red(f"\n❌ {len(blocking_failures)} blocking check(s) failed"))
        return 1

    print(green("\n✅ All blocking checks passed."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
