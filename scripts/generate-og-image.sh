#!/usr/bin/env bash
#
# generate-og-image.sh — rasterize public/og-image.svg → og-image.png
# Uses macOS Quick Look (qlmanage). Install rsvg-convert for CI/Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_DIR="$(cd "$SCRIPT_DIR/../website/public" && pwd)"
SVG_PATH="$PUBLIC_DIR/og-image.svg"
PNG_PATH="$PUBLIC_DIR/og-image.png"

if [[ ! -f "$SVG_PATH" ]]; then
  echo "missing $SVG_PATH" >&2
  exit 1
fi

if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1200 -h 630 "$SVG_PATH" -o "$PNG_PATH"
elif command -v qlmanage >/dev/null 2>&1; then
  rm -f "$PNG_PATH" "$PUBLIC_DIR/og-image.svg.png"
  qlmanage -t -s 1200 -o "$PUBLIC_DIR" "$SVG_PATH" >/dev/null
  if [[ -f "$PUBLIC_DIR/og-image.svg.png" ]]; then
    mv "$PUBLIC_DIR/og-image.svg.png" "$PNG_PATH"
  fi
else
  echo "need rsvg-convert or qlmanage to rasterize OG image" >&2
  exit 1
fi

echo "wrote $PNG_PATH ($(wc -c < "$PNG_PATH" | tr -d ' ') bytes)"
