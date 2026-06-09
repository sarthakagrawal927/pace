#!/usr/bin/env python3
"""
run_fixture.py — execute one Pace eval fixture and report TTFT + content.

Why this exists
---------------
`curl` can give us time-to-first-byte, but for an SSE chat-completion
stream `time_starttransfer` only marks the HTTP header arrival, not
the first *content* token. We want the latter — that's what Pace's
streaming TTS pipeline waits for to start speaking.

This script makes a streaming request, time-stamps the moment the
first non-empty `choices[0].delta.content` chunk arrives, then reads
the rest of the stream so we can run correctness regexes against the
final assembled response.

Outputs a single JSON line on stdout:
  {"ttft_ms": int, "total_ms": int, "content": str, "http_status": int}

The wrapping shell script parses that line with `python3 -c "import json, sys; ..."`.

Usage
-----
  python3 evals/run_fixture.py <fixture-path> <chat-completions-url> <model-id>
"""

import json
import re
import sys
import time
import urllib.error
import urllib.request


def execute_streaming_request(
    request_body: dict,
    chat_completions_url: str,
) -> dict:
    request = urllib.request.Request(
        chat_completions_url,
        data=json.dumps(request_body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer lm-studio",
        },
        method="POST",
    )

    started_at = time.monotonic()
    first_content_token_at: float | None = None
    full_response_content_parts: list[str] = []
    http_status_code = 0

    try:
        with urllib.request.urlopen(request, timeout=120) as response_stream:
            http_status_code = response_stream.status
            # Iterate line by line. OpenAI-compatible SSE prefixes each
            # event with `data: ` and terminates the stream with
            # `data: [DONE]`. Empty lines separate events.
            for raw_line in response_stream:
                decoded_line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
                if not decoded_line.startswith("data: "):
                    continue
                payload_string = decoded_line[len("data: "):]
                if payload_string == "[DONE]":
                    break
                try:
                    payload = json.loads(payload_string)
                except json.JSONDecodeError:
                    continue
                choices = payload.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                content_chunk = delta.get("content")
                if not content_chunk:
                    continue
                if first_content_token_at is None:
                    first_content_token_at = time.monotonic()
                full_response_content_parts.append(content_chunk)
    except urllib.error.HTTPError as http_error:
        http_status_code = http_error.code
        # Read the body so the wrapper can show the error message.
        error_body_bytes = http_error.read() if hasattr(http_error, "read") else b""
        return {
            "ttft_ms": 0,
            "total_ms": int((time.monotonic() - started_at) * 1000),
            "content": error_body_bytes.decode("utf-8", errors="replace")[:500],
            "http_status": http_status_code,
            "error": f"HTTPError {http_status_code}",
        }
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return {
            "ttft_ms": 0,
            "total_ms": int((time.monotonic() - started_at) * 1000),
            "content": "",
            "http_status": 0,
            "error": f"transport: {transport_error}",
        }

    finished_at = time.monotonic()
    raw_content = "".join(full_response_content_parts)
    # Strip <think>…</think> blocks before returning so correctness
    # checks evaluate the user-facing portion of the response.
    spoken_content = re.sub(
        r"<think>.*?</think>",
        "",
        raw_content,
        flags=re.DOTALL | re.IGNORECASE,
    ).strip()

    ttft_ms = (
        int((first_content_token_at - started_at) * 1000)
        if first_content_token_at is not None
        else 0
    )
    total_ms = int((finished_at - started_at) * 1000)

    return {
        "ttft_ms": ttft_ms,
        "total_ms": total_ms,
        "content": spoken_content,
        "raw_content_length": len(raw_content),
        "http_status": http_status_code,
    }


def execute_non_streaming_fallback_request(
    request_body: dict,
    chat_completions_url: str,
) -> dict:
    fallback_request_body = dict(request_body)
    fallback_request_body["stream"] = False
    fallback_request_body["cache_prompt"] = False

    request = urllib.request.Request(
        chat_completions_url,
        data=json.dumps(fallback_request_body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer lm-studio",
        },
        method="POST",
    )

    started_at = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            response_body = response.read().decode("utf-8", errors="replace")
            payload = json.loads(response_body)
            choices = payload.get("choices") or []
            message = (choices[0].get("message") if choices else {}) or {}
            raw_content = message.get("content") or ""
            spoken_content = re.sub(
                r"<think>.*?</think>",
                "",
                raw_content,
                flags=re.DOTALL | re.IGNORECASE,
            ).strip()
            total_ms = int((time.monotonic() - started_at) * 1000)
            return {
                "ttft_ms": total_ms,
                "total_ms": total_ms,
                "content": spoken_content,
                "raw_content_length": len(raw_content),
                "http_status": response.status,
                "fallback": "non_streaming",
            }
    except urllib.error.HTTPError as http_error:
        error_body_bytes = http_error.read() if hasattr(http_error, "read") else b""
        return {
            "ttft_ms": 0,
            "total_ms": int((time.monotonic() - started_at) * 1000),
            "content": error_body_bytes.decode("utf-8", errors="replace")[:500],
            "http_status": http_error.code,
            "error": f"fallback HTTPError {http_error.code}",
        }
    except (json.JSONDecodeError, urllib.error.URLError, TimeoutError) as error:
        return {
            "ttft_ms": 0,
            "total_ms": int((time.monotonic() - started_at) * 1000),
            "content": "",
            "http_status": 0,
            "error": f"fallback transport: {error}",
        }


def main() -> int:
    if len(sys.argv) != 4:
        print(json.dumps({
            "ttft_ms": 0,
            "total_ms": 0,
            "content": "",
            "http_status": 0,
            "error": "usage: run_fixture.py <fixture-path> <url> <model-id>",
        }))
        return 2

    fixture_path = sys.argv[1]
    chat_completions_url = sys.argv[2]
    model_identifier = sys.argv[3]

    with open(fixture_path) as fixture_file:
        fixture = json.load(fixture_file)

    request_body = dict(fixture["request"])
    request_body["model"] = model_identifier
    # Force streaming regardless of what the fixture said — the whole
    # point of this script is measuring TTFT, which requires SSE.
    request_body["stream"] = True

    maximum_attempts = 3
    result: dict = {}
    for attempt_number in range(1, maximum_attempts + 1):
        request_body_for_attempt = dict(request_body)
        if attempt_number > 1:
            request_body_for_attempt["cache_prompt"] = False
        result = execute_streaming_request(request_body_for_attempt, chat_completions_url)
        result["attempts"] = attempt_number
        if not (
            result.get("http_status") == 200
            and result.get("raw_content_length", 0) == 0
            and attempt_number < maximum_attempts
        ):
            break

    if result.get("http_status") == 200 and result.get("raw_content_length", 0) == 0:
        result = execute_non_streaming_fallback_request(request_body, chat_completions_url)
        result["attempts"] = maximum_attempts + 1

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
