#!/usr/bin/env python3
"""Minimal cloud-bridge SSE fixture for CloudBridgePlannerClient tests.

Serves the local-ai bridge SSE shape at POST /chat:
  data: {"text":"Hello"}
  data: {"text":" world"}
  data: [DONE]

And an error variant at POST /chat when the request body contains
  {"trigger_error": true}:
  data: {"error":"fixture upstream error"}
  data: [DONE]

Also serves GET /health as the bridge does.

Stdlib only. Usage:
  python3 scripts/cloud-bridge-fixture-server.py <port>
Prints "READY" to stdout once listening.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CANNED_TOKENS = ["Hello", " world", " from", " the", " fixture"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/api/health"):
            body = json.dumps({"status": "ok", "providers": ["claude", "codex", "gemini"]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path not in ("/chat", "/api/chat"):
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length else b""
        try:
            request_payload = json.loads(raw_body) if raw_body else {}
        except json.JSONDecodeError:
            request_payload = {}

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        should_trigger_error = request_payload.get("trigger_error", False)

        if should_trigger_error:
            # Emit an upstream error event so the client's error-path is exercised.
            error_event = f"data: {json.dumps({'error': 'fixture upstream error'})}\n\n"
            self.wfile.write(error_event.encode())
        else:
            # Emit canned token chunks followed by [DONE].
            for token in CANNED_TOKENS:
                chunk_event = f"data: {json.dumps({'text': token})}\n\n"
                self.wfile.write(chunk_event.encode())
                self.wfile.flush()

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3456
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("READY", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
