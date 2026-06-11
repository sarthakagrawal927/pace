#!/usr/bin/env python3
"""Minimal stdio MCP fixture server for validating Pace's MCP bridge.

Speaks the exact dialect PaceMCPClient.swift expects:
- newline-delimited JSON-RPC (one JSON object per line, no Content-Length headers)
- responds to `initialize` and `tools/call`; ignores notifications
- never writes non-JSON to stdout (the client treats any stdout line with an
  `error` key as a JSON-RPC error, and any other noise breaks line framing) —
  diagnostics go to stderr only

Tools:
- echo  {"text": "..."}     -> returns the text verbatim
- fail  {}                  -> returns a result with isError=true
- sleep {"seconds": 5}      -> sleeps, then echoes; drives client-timeout tests
- anything else             -> JSON-RPC error -32601 (drives rpcError tests)

Used by leanring-buddyTests/PaceMCPClientIntegrationTests.swift and by
SETUP_LOCAL.md's "verify your MCP setup" recipe.
"""

import json
import sys
import time


def respond(payload):
    print(json.dumps(payload), flush=True)


def handle_initialize(message):
    respond({
        "jsonrpc": "2.0",
        "id": message["id"],
        "result": {
            "protocolVersion": "2025-03-26",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "pace-mcp-fixture", "version": "0.1"},
        },
    })


def handle_tools_call(message):
    params = message.get("params", {})
    tool_name = params.get("name", "")
    arguments = params.get("arguments", {}) or {}

    if tool_name == "echo":
        respond({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "content": [{"type": "text", "text": arguments.get("text", "")}],
            },
        })
    elif tool_name == "fail":
        respond({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "isError": True,
                "content": [{"type": "text", "text": "intentional fixture failure"}],
            },
        })
    elif tool_name == "sleep":
        time.sleep(float(arguments.get("seconds", 5)))
        respond({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "content": [{"type": "text", "text": "slept"}],
            },
        })
    else:
        respond({
            "jsonrpc": "2.0",
            "id": message["id"],
            "error": {"code": -32601, "message": f"unknown tool: {tool_name}"},
        })


def main():
    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            message = json.loads(raw_line)
        except json.JSONDecodeError:
            print(f"fixture: skipping unparseable line: {raw_line!r}", file=sys.stderr)
            continue

        if "id" not in message:
            continue  # notification (e.g. notifications/initialized)

        method = message.get("method", "")
        if method == "initialize":
            handle_initialize(message)
        elif method == "tools/call":
            handle_tools_call(message)
        else:
            respond({
                "jsonrpc": "2.0",
                "id": message["id"],
                "error": {"code": -32601, "message": f"unknown method: {method}"},
            })


if __name__ == "__main__":
    main()
