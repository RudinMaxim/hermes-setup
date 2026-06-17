#!/usr/bin/env bash
# Report the actual Telegram voice (speech-to-text) readiness of the Hermes
# container on the VPS. Structural checks plus a live OpenRouter reachability
# ping. Run on demand — it is intentionally NOT part of every gateway setup, so
# setup runs stay idempotent and free of per-run API calls.
#
# Usage: ./scripts/vps/check-voice.sh

set -uo pipefail

CONTAINER_STT_SCRIPT=/opt/data/bin/openrouter-stt.py
CONTAINER_WHISPER_LINK=/usr/local/bin/whisper
failures=0

ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

if [[ "$(docker inspect -f '{{.State.Status}}' hermes 2>/dev/null)" != "running" ]]; then
  fail "hermes container is not running"
  exit "$failures"
fi

if docker exec hermes sh -lc 'command -v ffmpeg >/dev/null 2>&1'; then
  ok "ffmpeg present (Telegram OGG/Opus -> mp3 conversion)"
else
  fail "ffmpeg missing in container"
fi

if docker exec hermes sh -lc "test -x '$CONTAINER_STT_SCRIPT'"; then
  ok "OpenRouter STT shim present: $CONTAINER_STT_SCRIPT"
else
  fail "OpenRouter STT shim missing — run ./scripts/setup-gateway.sh --restart"
fi

if docker exec hermes sh -lc "grep -q 'openrouter-stt.py' '$CONTAINER_WHISPER_LINK' 2>/dev/null"; then
  ok "whisper -> OpenRouter STT shim is linked"
else
  fail "$CONTAINER_WHISPER_LINK does not point at the shim — run ./scripts/setup-gateway.sh --restart"
fi

if docker exec -i hermes python3 - <<'PY'
import os, yaml
from pathlib import Path
cfg = yaml.safe_load((Path(os.environ.get("HERMES_HOME", "/opt/data")) / "config.yaml").read_text(encoding="utf-8")) or {}
stt = cfg.get("stt") or {}
raise SystemExit(0 if stt.get("enabled") and stt.get("provider") == "local_command" else 1)
PY
then
  ok "stt config enabled (provider=local_command)"
else
  fail "stt config not enabled — run ./scripts/setup-gateway.sh --restart"
fi

if ! docker exec hermes sh -lc 'test -n "$OPENROUTER_API_KEY"'; then
  fail "OPENROUTER_API_KEY not set in container"
  exit "$failures"
fi
ok "OPENROUTER_API_KEY is set"

# Live reachability ping: confirms the key authenticates and the configured
# audio model id is valid, without needing a speech sample.
if docker exec -i hermes python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

key = os.environ["OPENROUTER_API_KEY"].strip()
model = os.environ.get("HERMES_OPENROUTER_STT_MODEL", "google/gemini-2.5-flash").strip() or "google/gemini-2.5-flash"
payload = {"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "ping"}]}
req = urllib.request.Request(
    "https://openrouter.ai/api/v1/chat/completions",
    data=json.dumps(payload).encode(), method="POST",
    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode())
    sys.stderr.write(f"model={model}\n")
    sys.exit(0 if body.get("choices") else 1)
except urllib.error.HTTPError as exc:
    sys.stderr.write(f"HTTP {exc.code}: {exc.read().decode('utf-8','replace')[:200]}\n")
    sys.exit(1)
except Exception as exc:
    sys.stderr.write(f"{exc}\n")
    sys.exit(1)
PY
then
  ok "OpenRouter audio model reachable and authenticated"
else
  fail "OpenRouter ping failed — check OPENROUTER_API_KEY and HERMES_OPENROUTER_STT_MODEL"
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nTelegram voice STT is ready. For a full end-to-end test, send a voice\n'
  printf 'message to the bot in DM and check: docker logs --since 3m hermes\n'
fi

exit "$failures"
