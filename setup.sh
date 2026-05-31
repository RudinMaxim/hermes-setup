#!/usr/bin/env bash
# setup.sh — Thin hermes-side orchestrator. Runs the unprivileged setup steps in
# order and (interactively) offers the optional gateway / MCP steps. The server
# step is root-only and one-off, so it is NOT included here — run
# scripts/setup-server.sh as root separately.
#
# Flags are passed through to the child scripts. --non-interactive (or
# HERMES_NONINTERACTIVE=1) disables every prompt.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/scripts/lib/log.sh"
# shellcheck source=scripts/lib/checks.sh
source "$SCRIPT_DIR/scripts/lib/checks.sh"
# shellcheck source=scripts/lib/prompt.sh
source "$SCRIPT_DIR/scripts/lib/prompt.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
  esac
done

main() {
  [[ $EUID -ne 0 ]] \
    || log_warn "setup.sh is the hermes-side orchestrator — run setup-server.sh as root separately, then re-run this as the 'hermes' user"

  log_act "running setup-hermes.sh"
  bash "$SCRIPT_DIR/scripts/setup-hermes.sh" "$@"

  if is_interactive && confirm "Configure a messaging gateway (Telegram) now?"; then
    bash "$SCRIPT_DIR/scripts/setup-gateway.sh" "$@"
  fi

  if is_interactive && confirm "Sync MCP servers from mcp.toml now?"; then
    bash "$SCRIPT_DIR/scripts/setup-mcp.sh" "$@"
  fi

  log_ok "setup complete"
}

main "$@"
