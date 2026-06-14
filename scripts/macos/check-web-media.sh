#!/usr/bin/env bash
# Validate live web search and OpenRouter media provider registration.

set -uo pipefail

HERMES_PYTHON="${HERMES_PYTHON:-$HOME/.hermes/hermes-agent/venv/bin/python}"
failures=0

ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

if "$HERMES_PYTHON" - <<'PY'
from tools.web_tools import web_search_tool
result = web_search_tool("official Python website", limit=2)
raise SystemExit(0 if "python.org" in result.lower() else 1)
PY
then
  ok "web search returns live results"
else
  fail "web search failed"
fi

if "$HERMES_PYTHON" - <<'PY'
from dotenv import load_dotenv
from pathlib import Path
from agent.image_gen_registry import get_provider
from hermes_cli.plugins import _ensure_plugins_discovered
load_dotenv(Path.home() / ".hermes" / ".env")
_ensure_plugins_discovered()
provider = get_provider("openrouter")
raise SystemExit(0 if provider and provider.name == "openrouter" and provider.is_available() else 1)
PY
then
  ok "OpenRouter image generation provider is registered"
else
  fail "OpenRouter image generation provider is unavailable"
fi

if "$HERMES_PYTHON" - <<'PY'
from dotenv import load_dotenv
from pathlib import Path
from agent.video_gen_registry import get_provider
from hermes_cli.plugins import _ensure_plugins_discovered
load_dotenv(Path.home() / ".hermes" / ".env")
_ensure_plugins_discovered()
provider = get_provider("openrouter")
raise SystemExit(0 if provider and provider.name == "openrouter" and provider.is_available() else 1)
PY
then
  ok "OpenRouter video generation provider is registered"
else
  fail "OpenRouter video generation provider is unavailable"
fi

exit "$failures"
