#!/usr/bin/env bash
# Report the actual multimedia capabilities of the native Hermes install.

set -uo pipefail

HERMES_PYTHON="${HERMES_PYTHON:-$HOME/.hermes/hermes-agent/venv/bin/python}"
failures=0

ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

for command in ffmpeg ffprobe whisper say afplay; do
  if command -v "$command" >/dev/null 2>&1; then
    ok "$command: $(command -v "$command")"
  else
    fail "$command is missing"
  fi
done

if "$HERMES_PYTHON" - <<'PY'
from tools.transcription_tools import _has_local_command
raise SystemExit(0 if _has_local_command() else 1)
PY
then
  ok "local speech-to-text backend is available"
else
  fail "local speech-to-text backend is unavailable"
fi

if "$HERMES_PYTHON" - <<'PY'
from tools.tts_tool import check_tts_requirements
raise SystemExit(0 if check_tts_requirements() else 1)
PY
then
  ok "text-to-speech backend is available"
else
  fail "text-to-speech backend is unavailable"
fi

if "$HERMES_PYTHON" - <<'PY'
import sounddevice as sd
inputs = [device for device in sd.query_devices() if device["max_input_channels"] > 0]
raise SystemExit(0 if inputs else 1)
PY
then
  ok "CLI microphone input is available"
else
  warn "no microphone input device; Telegram voice STT still works"
fi

if "$HERMES_PYTHON" - <<'PY'
from tools.vision_tools import check_vision_requirements
raise SystemExit(0 if check_vision_requirements() else 1)
PY
then
  ok "image and video analysis route is configured"
else
  fail "image and video analysis route is unavailable"
fi

if "$HERMES_PYTHON" - <<'PY'
from dotenv import load_dotenv
from pathlib import Path
from tools.image_generation_tool import check_image_generation_requirements
load_dotenv(Path.home() / ".hermes" / ".env")
raise SystemExit(0 if check_image_generation_requirements() else 1)
PY
then
  ok "image generation backend is configured"
else
  warn "image generation is disabled: configure a supported provider plugin"
fi

if "$HERMES_PYTHON" - <<'PY'
from dotenv import load_dotenv
from pathlib import Path
from tools.video_generation_tool import check_video_generation_requirements
load_dotenv(Path.home() / ".hermes" / ".env")
raise SystemExit(0 if check_video_generation_requirements() else 1)
PY
then
  ok "video generation backend is configured"
else
  warn "video generation is disabled: configure a supported provider plugin"
fi

exit "$failures"
