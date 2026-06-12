#!/usr/bin/env bash
# Render UTF-8 text with the native macOS voice and encode Telegram-ready Opus.

set -euo pipefail

input_path="${1:?input text path is required}"
output_path="${2:?output audio path is required}"
voice="${3:-Milena}"
rate="${4:-190}"
tmp_aiff=$(mktemp "${TMPDIR:-/tmp}/hermes-say.XXXXXX.aiff")
trap 'rm -f "$tmp_aiff"' EXIT

/usr/bin/say -v "$voice" -r "$rate" -f "$input_path" -o "$tmp_aiff"
/usr/local/bin/ffmpeg -hide_banner -loglevel error -y \
  -i "$tmp_aiff" -ac 1 -ar 48000 -c:a libopus -b:a 48k "$output_path"
