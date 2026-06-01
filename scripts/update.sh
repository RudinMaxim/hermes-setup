#!/usr/bin/env bash
# scripts/update.sh — Pull the latest repo and re-sync Hermes + MCP + gateway.
#
# Idempotent orchestrator: run it anytime to bring a host up to date. It only
# changes what drifted — every wrapped setup script reports [SKIP] when nothing
# changed. Run as the 'hermes' user from the repo root.
#
# Usage:
#   ./scripts/update.sh                  # git pull + re-sync hermes/mcp/gateway + update MCP npm packages
#   ./scripts/update.sh --no-pull        # skip git pull (re-sync only)
#   ./scripts/update.sh --no-pkg-update  # skip 'npm update -g' of MCP packages
#   ./scripts/update.sh --pull-image     # also docker compose pull a newer hermes image (not auto-applied)
#   ./scripts/update.sh --non-interactive
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

PULL=1
PULL_IMAGE=0
UPDATE_PKGS=1
PASSTHRU=()
for arg in "$@"; do
  case "$arg" in
    --no-pull)         PULL=0 ;;
    --pull-image)      PULL_IMAGE=1 ;;
    --no-pkg-update)   UPDATE_PKGS=0 ;;
    --non-interactive) PASSTHRU+=("$arg") ;;
    *) die "unknown argument: $arg" ;;
  esac
done

pull_repo() {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    log_warn "not a git repository — skipping pull"
    return 0
  }
  local before after
  before=$(git -C "$REPO_ROOT" rev-parse HEAD)
  git -C "$REPO_ROOT" pull --ff-only
  after=$(git -C "$REPO_ROOT" rev-parse HEAD)
  if [[ "$before" == "$after" ]]; then
    log_skip "repo already up to date ($after)"
  else
    log_ok "repo updated ${before:0:8} -> ${after:0:8}"
  fi
}

# Update the npm-backed MCP servers that are enabled in mcp.toml. HTTP/remote
# MCPs (no 'package') are skipped — they have no npm package to update.
update_npm_mcps() {
  if ! docker_container_running hermes; then
    log_warn "hermes container not running — skipping MCP package update"
    return 0
  fi
  local toml="$CONFIG_DIR/mcp.toml" s pkg
  [[ -f "$toml" ]] || return 0
  for s in $(toml_sections "$toml"); do
    toml_get_bool "$toml" "$s" enabled || continue
    pkg=$(toml_get "$toml" "$s" package 2>/dev/null || true)
    [[ -n "$pkg" ]] || continue
    if [[ ! "$pkg" =~ ^[@a-zA-Z0-9._/-]+$ ]]; then
      log_warn "mcp.$s: skipping update of unsafe package name '$pkg'"
      continue
    fi
    log_act "npm update -g $pkg"
    if docker exec hermes npm update -g "$pkg" >/dev/null 2>&1; then
      log_ok "updated $pkg"
    else
      log_warn "could not update $pkg (check 'docker exec hermes npm update -g $pkg')"
    fi
  done
}

main() {
  (( PULL )) && pull_repo

  log_act "re-syncing hermes"
  bash "$SCRIPT_DIR/setup-hermes.sh" "${PASSTHRU[@]}"
  log_act "re-syncing MCP servers"
  bash "$SCRIPT_DIR/setup-mcp.sh" "${PASSTHRU[@]}"
  if [[ -f "$CONFIG_DIR/gateways.toml" ]]; then
    log_act "re-syncing gateways"
    bash "$SCRIPT_DIR/setup-gateway.sh" "${PASSTHRU[@]}"
  fi

  (( UPDATE_PKGS )) && update_npm_mcps

  if (( PULL_IMAGE )); then
    log_act "docker compose pull (hermes image)"
    docker compose -f "$CONFIG_DIR/docker-compose.yml" pull
    log_warn "newer image pulled but NOT applied — a new image takes effect only on container recreate ('docker compose -f config/docker-compose.yml up -d')."
    log_warn "on an existing host, first ensure the hermes_data volume is mounted at HERMES_HOME (/opt/data) so recreate does not hide existing state — see docs/01-server-setup.md."
  fi

  log_ok "update complete"
}

main "$@"
