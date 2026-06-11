#!/usr/bin/env python3
"""Minimal OpenAI-compatible /v1/audio/speech fixture for TTS tests.

Returns a short silent WAV for any POST to /v1/audio/speech, so
LocalServerTTSClient's synthesize→decode→play→drain loop can be exercised
end-to-end without installing a real TTS model. Stdlib only.

Usage: python3 scripts/tts-fixture-server.py <port>
Prints "READY" on stdout once listening.
"""

import struct
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def silent_wav(duration_seconds=0.15, sample_rate=16000):
    frame_count = int(duration_seconds * sample_rate)
    pcm = b"\x00\x00" * frame_count
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16,
        1, 1, sample_rate, sample_rate * 2, 2, 16,
        b"data", len(pcm),
    )
    return header + pcm


WAV_PAYLOAD = silent_wav()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/audio/speech":
            self.send_error(404)
            return
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(WAV_PAYLOAD)))
        self.end_headers()
        self.wfile.write(WAV_PAYLOAD)

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("READY", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
