#!/usr/bin/env bash
# scripts/setup-mcp.sh — Idempotently sync MCP servers based on config/mcp.toml.
# Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
TOML="$CONFIG_DIR/mcp.toml"
ENVFILE="$CONFIG_DIR/.env"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

require_hermes_running() {
  if ! docker_container_running hermes; then
    die "hermes container is not running — run scripts/setup-hermes.sh first"
  fi
}

require_files() {
  [[ -f "$TOML" ]] || die "missing $TOML"
  [[ -f "$ENVFILE" ]] || die "missing $ENVFILE"
}

enabled_mcps() {
  local s
  for s in $(toml_sections "$TOML"); do
    if toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done
}

disabled_mcps_to_remove() {
  local registered s
  registered=$(docker exec hermes hermes mcp list --quiet 2>/dev/null | awk 'NF{print $1}') || return 0
  for s in $registered; do
    if ! toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done
}

check_required_env() {
  local mcp="$1"
  local missing=()
  local req
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    if ! env_var_set_in_file "$ENVFILE" "$req"; then
      missing+=("$req")
    fi
  done < <(toml_get_array "$TOML" "$mcp" requires)
  if (( ${#missing[@]} )); then
    log_warn "mcp.$mcp: missing ${missing[*]} — see docs/mcp/$mcp.md"
    return 1
  fi
  return 0
}

mcp_registered_in_hermes() {
  docker exec hermes hermes mcp list --quiet 2>/dev/null \
    | awk 'NF{print $1}' \
    | grep -qx "$1"
}

npm_pkg_installed() {
  docker exec hermes bash -c "npm list -g --depth=0 2>/dev/null | grep -q '$1'"
}

deploy_stdio_mcp() {
  local mcp="$1"
  local pkg
  pkg=$(toml_get "$TOML" "$mcp" package) || die "mcp.$mcp: missing 'package'"

  if npm_pkg_installed "$pkg"; then
    log_skip "mcp.$mcp: $pkg already installed in hermes container"
  else
    log_act "installing $pkg in hermes container"
    docker exec hermes npm install -g "$pkg" >/dev/null
    log_ok "installed $pkg"
  fi

  if mcp_registered_in_hermes "$mcp"; then
    log_skip "mcp.$mcp: already registered in hermes"
  else
    log_act "registering mcp '$mcp'"
    local env_args=() req
    while IFS= read -r req; do
      [[ -z "$req" ]] && continue
      env_args+=(--env "$req")
    done < <(toml_get_array "$TOML" "$mcp" requires)
    docker exec hermes hermes mcp add "$mcp" \
      --transport stdio --command "$pkg" "${env_args[@]}" >/dev/null
    log_ok "registered mcp '$mcp'"
  fi
}

deploy_http_mcp() {
  local mcp="$1"
  local port
  port=$(toml_get "$TOML" "$mcp" port) || die "mcp.$mcp: missing 'port'"

  local service="mcp-$mcp"
  if docker_container_running "$service"; then
    log_skip "mcp.$mcp: container $service already running"
  else
    log_act "starting compose service $service (profile $mcp)"
    docker compose -f "$CONFIG_DIR/docker-compose.mcp.yml" --profile "$mcp" up -d "$service" >/dev/null
    log_ok "started $service"
  fi

  if mcp_registered_in_hermes "$mcp"; then
    log_skip "mcp.$mcp: already registered in hermes"
  else
    log_act "registering mcp '$mcp' (http)"
    docker exec hermes hermes mcp add "$mcp" \
      --transport http --url "http://$service:$port" >/dev/null
    log_ok "registered mcp '$mcp'"
  fi
}

main() {
  require_files
  require_hermes_running

  local mcp
  while IFS= read -r mcp; do
    [[ -z "$mcp" ]] && continue

    if [[ "$mcp" == "docker_mcp" ]]; then
      if ! toml_get_bool "$TOML" docker_mcp acknowledge_socket_risk; then
        log_warn "mcp.docker_mcp: skipped — set acknowledge_socket_risk = true in mcp.toml to opt-in (mounts /var/run/docker.sock which is root-equivalent)"
        continue
      fi
    fi

    if ! check_required_env "$mcp"; then
      continue
    fi

    local transport
    transport=$(toml_get "$TOML" "$mcp" transport) || transport="stdio"
    case "$transport" in
      stdio) deploy_stdio_mcp "$mcp" ;;
      http)  deploy_http_mcp "$mcp" ;;
      *)     log_warn "mcp.$mcp: unknown transport '$transport' — skipping" ;;
    esac
  done < <(enabled_mcps)

  local stale
  while IFS= read -r stale; do
    [[ -z "$stale" ]] && continue
    log_act "unregistering mcp '$stale' (no longer enabled in mcp.toml)"
    docker exec hermes hermes mcp remove "$stale" >/dev/null
    log_ok "unregistered mcp '$stale'"
  done < <(disabled_mcps_to_remove)

  log_ok "mcp sync complete"
}

main "$@"
