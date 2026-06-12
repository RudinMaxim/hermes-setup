#!/usr/bin/env bash
# Keep the Ollama desktop service available for Hermes.

set -euo pipefail

OLLAMA_URL="${OLLAMA_HEALTH_URL:-http://127.0.0.1:11434/api/tags}"
WAIT_SECONDS="${OLLAMA_START_WAIT_SECONDS:-30}"

if curl -fsS --max-time 3 "$OLLAMA_URL" >/dev/null 2>&1; then
  exit 0
fi

open -gj -a Ollama

for ((second = 1; second <= WAIT_SECONDS; second++)); do
  if curl -fsS --max-time 3 "$OLLAMA_URL" >/dev/null 2>&1; then
    printf '%s [ollama-watchdog] Ollama is ready\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
  fi
  sleep 1
done

printf '%s [ollama-watchdog] Ollama did not become ready in %ss\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$WAIT_SECONDS" >&2
exit 1
