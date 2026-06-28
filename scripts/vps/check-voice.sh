#!/usr/bin/env bash
# Report Telegram voice (speech-to-text) readiness for the selected backend.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENVFILE="$REPO_ROOT/config/.env"
CONTAINER_WHISPER_LINK=/usr/local/bin/whisper
failures=0

# shellcheck source=../lib/checks.sh
source "$REPO_ROOT/scripts/lib/checks.sh"

ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

provider=$(read_env_value "$ENVFILE" HERMES_STT_PROVIDER 2>/dev/null || true)
if [[ -z "$provider" ]]; then
  if env_var_set_in_file "$ENVFILE" YANDEX_API_KEY \
     && env_var_set_in_file "$ENVFILE" YANDEX_FOLDER_ID; then
    provider=yandex
  else
    provider=openrouter
  fi
fi

case "$provider" in
  yandex)
    script_name=yandex-speechkit-stt.py
    required_vars=(YANDEX_API_KEY YANDEX_FOLDER_ID)
    ;;
  openrouter)
    script_name=openrouter-stt.py
    required_vars=(OPENROUTER_API_KEY)
    ;;
  *)
    fail "unsupported voice STT backend: $provider"
    exit "$failures"
    ;;
esac

container_script="/opt/data/bin/$script_name"
ok "backend: $provider"

if [[ "$(docker inspect -f '{{.State.Status}}' hermes 2>/dev/null)" != "running" ]]; then
  fail "hermes container is not running"
  exit "$failures"
fi

if docker exec hermes sh -lc "test -x '$container_script'"; then
  ok "$provider STT shim present: $container_script"
else
  fail "$provider STT shim missing — run ./scripts/setup-gateway.sh --restart"
fi

if docker exec hermes sh -lc "grep -q '$script_name' '$CONTAINER_WHISPER_LINK' 2>/dev/null"; then
  ok "whisper -> $provider STT shim is linked"
else
  fail "$CONTAINER_WHISPER_LINK does not point at $script_name"
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

for var in "${required_vars[@]}"; do
  if docker exec hermes sh -lc "test -n \"\$$var\""; then
    ok "$var is set"
  else
    fail "$var is not set in the container"
  fi
done

if [[ "$provider" == "openrouter" ]]; then
  if docker exec hermes sh -lc 'command -v ffmpeg >/dev/null 2>&1'; then
    ok "ffmpeg present for OpenRouter audio conversion"
  else
    fail "ffmpeg missing in container"
  fi
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nTelegram voice STT is structurally ready. Send a voice message longer\n'
  printf 'than 30 seconds, then inspect: docker logs --since 3m hermes\n'
else
  warn "voice STT has $failures failed readiness check(s)"
fi

exit "$failures"
