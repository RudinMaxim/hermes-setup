#!/usr/bin/env bash
# Make Google access stable for Telegram by using the built-in Google Workspace
# skill token and disabling the separate remote google_drive MCP OAuth path.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"

require_hermes_running() {
  docker_container_exists hermes \
    || die "hermes container does not exist — run scripts/setup-hermes.sh first"
  docker_container_running hermes \
    || die "hermes container is not running — run scripts/setup-hermes.sh first"
}

require_workspace_token() {
  docker exec hermes sh -lc 'test -f /opt/data/google_token.json' >/dev/null 2>&1 \
    || die "Google Workspace token is missing at /opt/data/google_token.json — authorize once in CLI chat first"
}

ensure_workspace_token_link() {
  docker exec -u root hermes sh -lc 'mkdir -p /home/hermes/.hermes && ln -sf /opt/data/google_token.json /home/hermes/.hermes/google_token.json && chown -h hermes:hermes /home/hermes/.hermes/google_token.json' >/dev/null
  log_skip "google workspace token link is ready (/home/hermes/.hermes/google_token.json -> /opt/data/google_token.json)"
}

disable_remote_google_drive_mcp() {
  local result
  result=$(docker exec -i hermes python3 - <<'PY'
import os
from pathlib import Path

import yaml

path = Path(os.environ.get("HERMES_HOME") or "/opt/data") / "config.yaml"
if not path.exists():
    raise SystemExit("missing_config")

config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
servers = config.get("mcp_servers")
if not isinstance(servers, dict):
    print("absent")
    raise SystemExit(0)

server = servers.get("google_drive")
if not isinstance(server, dict):
    print("absent")
    raise SystemExit(0)

if server.get("enabled") is False:
    print("already_disabled")
    raise SystemExit(0)

server["enabled"] = False
path.write_text(yaml.safe_dump(config, allow_unicode=True, sort_keys=False), encoding="utf-8")
print("disabled")
PY
)

  case "$result" in
    disabled) log_ok "disabled remote MCP google_drive to avoid repeated MCP OAuth prompts" ;;
    already_disabled) log_skip "remote MCP google_drive already disabled" ;;
    absent) log_skip "remote MCP google_drive is not configured" ;;
    missing_config) die "Hermes config.yaml is missing under HERMES_HOME" ;;
    *) die "unexpected google_drive MCP update result: $result" ;;
  esac
}

main() {
  require_hermes_running
  require_workspace_token
  ensure_workspace_token_link
  disable_remote_google_drive_mcp
  docker exec hermes hermes config check >/dev/null
  "$SCRIPT_DIR/setup-gateway.sh" --restart
  log_ok "google workspace access stabilized for Telegram"
}

main "$@"
