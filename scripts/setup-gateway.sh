#!/usr/bin/env bash
# scripts/setup-gateway.sh — Idempotently sync messaging gateways from
# config/gateways.toml. Phase 1: Telegram. Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
GW_TOML="$CONFIG_DIR/gateways.toml"
ENVFILE="$CONFIG_DIR/.env"
RESTART_GATEWAY=0

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"
# shellcheck source=lib/telegram.sh
source "$SCRIPT_DIR/lib/telegram.sh"
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    --restart) RESTART_GATEWAY=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_files() {
  [[ -f "$GW_TOML" ]] || die "missing $GW_TOML — run scripts/setup-hermes.sh first"
  [[ -f "$ENVFILE" ]] || die "missing $ENVFILE"
}

require_hermes_container() {
  docker_container_exists hermes \
    || die "hermes container does not exist — run scripts/setup-hermes.sh first"
}

load_compose_env() {
  HERMES_IMAGE=$(read_env_value "$ENVFILE" HERMES_IMAGE 2>/dev/null || printf '%s' "nousresearch/hermes-agent:latest")
  export HERMES_IMAGE
  HERMES_PROJECTS_DIR=$(read_env_value "$ENVFILE" HERMES_PROJECTS_DIR 2>/dev/null || printf '%s' "/home/hermes/projects")
  export HERMES_PROJECTS_DIR
}

gateway_enabled() {
  toml_get_bool "$GW_TOML" "$1" enabled
}

# True when the hermes container command is the gateway runner.
telegram_gateway_active() {
  docker inspect -f '{{join .Config.Cmd " "}}' hermes 2>/dev/null \
    | grep -q 'gateway run'
}

# Interactive fill: if a required Telegram value is missing and we have a TTY,
# prompt for it and write it to .env. No-op when values present or non-interactive.
maybe_prompt_telegram() {
  is_interactive || return 0
  if ! env_var_set_in_file "$ENVFILE" TELEGRAM_BOT_TOKEN; then
    local token
    token=$(prompt_secret "TELEGRAM_BOT_TOKEN")
    [[ -n "$token" ]] || die "empty token entered — aborting"
    log_act "saving TELEGRAM_BOT_TOKEN to .env"
    set_env_value "$ENVFILE" TELEGRAM_BOT_TOKEN "$token" >/dev/null
    log_ok "TELEGRAM_BOT_TOKEN saved to .env (${#token} chars)"
  fi
  if ! env_var_set_in_file "$ENVFILE" TELEGRAM_ALLOWED_USERS; then
    local allow
    allow=$(prompt_value "TELEGRAM_ALLOWED_USERS (comma-separated numeric user IDs — see docs/gateways/telegram.md)")
    log_act "saving TELEGRAM_ALLOWED_USERS to .env"
    set_env_value "$ENVFILE" TELEGRAM_ALLOWED_USERS "$allow" >/dev/null
    log_ok "TELEGRAM_ALLOWED_USERS saved to .env"
  fi
}

# Read-only validation. getMe is logged as a state check ([SKIP]), never [ACT],
# so the idempotency invariant holds on repeat runs.
validate_telegram() {
  local token allow resp uname count
  token=$(read_env_value "$ENVFILE" TELEGRAM_BOT_TOKEN) \
    || die "TELEGRAM_BOT_TOKEN missing in .env — see docs/gateways/telegram.md"
  allow=$(read_env_value "$ENVFILE" TELEGRAM_ALLOWED_USERS) || allow=""

  is_numeric_csv "$allow" \
    || die "TELEGRAM_ALLOWED_USERS must be comma-separated numeric IDs (got: '$allow') — see docs/gateways/telegram.md"

  resp=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getMe") \
    || die "Telegram getMe request failed — token invalid or no network"
  uname=$(telegram_getme_username "$resp") \
    || die "Telegram rejected the token (ok != true) — check TELEGRAM_BOT_TOKEN"
  count=$(tr ',' '\n' <<<"$allow" | grep -c .)
  log_skip "telegram token valid: bot @${uname}, allowlist has ${count} user(s)"
}

wait_for_gateway() {
  local i stable
  stable=0
  for i in $(seq 1 30); do
    if docker_container_running hermes \
      && docker exec hermes hermes gateway status >/dev/null 2>&1; then
      stable=$((stable + 1))
      if [[ "$stable" -ge 3 ]]; then
        return 0
      fi
    else
      stable=0
    fi
    sleep 1
  done
  log_warn "telegram gateway did not report healthy in 30s — recent logs:"
  docker logs --tail=50 hermes || true
  die "gateway health gate failed"
}

ensure_telegram() {
  if telegram_gateway_active; then
    if [[ "$RESTART_GATEWAY" == "1" ]]; then
      maybe_prompt_telegram
      validate_telegram
      log_act "restarting telegram gateway (recreating container with gateway command)"
      load_compose_env
      docker compose -f "$CONFIG_DIR/docker-compose.yml" \
                     -f "$CONFIG_DIR/docker-compose.gateway.yml" up -d --force-recreate >/dev/null
      wait_for_gateway
      log_ok "telegram gateway restarted"
      return 0
    fi
    log_skip "telegram gateway already running (command = gateway run)"
    return 0
  fi
  maybe_prompt_telegram
  validate_telegram
  log_act "starting telegram gateway (recreating container with gateway command)"
  load_compose_env
  docker compose -f "$CONFIG_DIR/docker-compose.yml" \
                 -f "$CONFIG_DIR/docker-compose.gateway.yml" up -d >/dev/null
  wait_for_gateway
  log_ok "telegram gateway is up — message your bot to test"
}

ensure_telegram_off() {
  if ! telegram_gateway_active; then
    log_skip "telegram gateway not running"
    return 0
  fi
  log_act "disabling telegram gateway (recreating container without gateway command)"
  load_compose_env
  docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d --force-recreate >/dev/null
  log_ok "telegram gateway stopped; container back to idle/CLI mode"
}

main() {
  require_files
  require_hermes_container

  if gateway_enabled telegram; then
    ensure_telegram
  else
    ensure_telegram_off
  fi

  if gateway_enabled webui; then
    log_warn "webui gateway is Phase 2 — not implemented yet, ignoring [webui] enabled=true"
  fi

  # No terminal [OK] summary on purpose: the per-branch [OK]/[SKIP] lines above
  # already report the outcome, and the project's idempotency invariant requires
  # a second run to emit only [SKIP] lines (see tests/README.md).
}

main "$@"
