#!/usr/bin/env bash
# scripts/setup.sh — One-command Hermes host setup for the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
GATEWAYS_TOML="$CONFIG_DIR/gateways.toml"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"

PASSTHRU=()
for arg in "$@"; do
  case "$arg" in
    --non-interactive)
      export HERMES_NONINTERACTIVE=1
      PASSTHRU+=("$arg")
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

main() {
  [[ $EUID -ne 0 ]] \
    || log_warn "setup.sh is the hermes-side orchestrator — run setup-server.sh as root separately, then re-run this as the 'hermes' user"

  log_act "setting up Hermes"
  bash "$SCRIPT_DIR/setup-hermes.sh" "${PASSTHRU[@]}"

  log_act "setting up MCP servers"
  bash "$SCRIPT_DIR/setup-mcp.sh" "${PASSTHRU[@]}"

  if [[ -f "$GATEWAYS_TOML" ]]; then
    log_act "setting up gateways"
    bash "$SCRIPT_DIR/setup-gateway.sh" "${PASSTHRU[@]}"
  fi

  log_ok "setup complete"
}

main "$@"
