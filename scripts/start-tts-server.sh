#!/usr/bin/env bash
#
# start-tts-server.sh — run the local Kokoro TTS sidecar Pace's
# LocalServerTTSClient talks to (OpenAI-compatible /v1/audio/speech).
#
# Uses mlx-audio (Apple-Silicon-native MLX runtime; Kokoro-82M). First
# synthesis call downloads the model (~350 MB) from Hugging Face; warm
# synthesis of a sentence is ~150 ms on an M-series Mac.
#
# Pace needs no restart: when this server is down it speaks with the
# Apple voice, and the next turn after the server comes up uses Kokoro.
#
# Usage:
#   ./scripts/start-tts-server.sh           # foreground on port 8880
#   PORT=9000 ./scripts/start-tts-server.sh # custom port (update Info.plist too)

set -euo pipefail

PORT="${PORT:-8880}"

if ! command -v uvx >/dev/null 2>&1; then
    echo "uvx not found — install uv first: https://docs.astral.sh/uv/" >&2
    exit 1
fi

echo "▶ Kokoro TTS sidecar on http://localhost:${PORT}/v1 (Ctrl-C to stop)"
exec uvx \
    --with uvicorn \
    --with fastapi \
    --with python-multipart \
    --with webrtcvad \
    --with "setuptools<81" \
    --with "misaki[en]" \
    --from mlx-audio \
    python -m mlx_audio.server --port "${PORT}"
