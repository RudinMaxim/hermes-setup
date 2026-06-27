#!/usr/bin/env bash
# Interactive one-shot migration of Hermes chat + Telegram voice to Yandex.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${HERMES_MIGRATION_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_DIR="$REPO_ROOT/config"
ENVFILE="$CONFIG_DIR/.env"
GW_TOML="$CONFIG_DIR/gateways.toml"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_operator() {
  if [[ $EUID -eq 0 && "${HERMES_MIGRATION_ALLOW_ROOT:-0}" != "1" ]]; then
    die "run this script as the hermes user, not root: su - hermes"
  fi
  [[ -d "$CONFIG_DIR" ]] || die "missing $CONFIG_DIR — run from the hermes-setup repository"
  [[ -f "$ENVFILE" ]] || die "missing $ENVFILE — run ./scripts/setup-hermes.sh --configs-only first"
  has_command curl || die "curl is required"
  has_command docker || die "docker is required"
}

read_required_secret() {
  local name="$1" value
  value=$(printenv "$name" 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    [[ "${HERMES_NONINTERACTIVE:-0}" != "1" ]] \
      || die "$name is required in non-interactive mode"
    value=$(prompt_secret "$name")
  fi
  [[ -n "$value" ]] || die "$name cannot be empty"
  printf '%s' "$value"
}

read_required_value() {
  local name="$1" value
  value=$(printenv "$name" 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    [[ "${HERMES_NONINTERACTIVE:-0}" != "1" ]] \
      || die "$name is required in non-interactive mode"
    value=$(prompt_value "$name")
  fi
  [[ -n "$value" ]] || die "$name cannot be empty"
  printf '%s' "$value"
}

read_model() {
  local folder_id="$1" default value
  default="gpt://$folder_id/aliceai-llm"
  value="${HERMES_MODEL:-}"
  if [[ -z "$value" && "${HERMES_NONINTERACTIVE:-0}" != "1" ]]; then
    value=$(prompt_value "Yandex model URI [$default]")
  fi
  printf '%s' "${value:-$default}"
}

validate_inputs() {
  local folder_id="$1" model="$2"
  [[ "$folder_id" =~ ^[a-z0-9]+$ ]] \
    || die "YANDEX_FOLDER_ID must contain only lowercase Latin letters and digits"
  [[ "$model" =~ ^gpt://[a-z0-9]+/[A-Za-z0-9._/@-]+$ ]] \
    || die "Yandex model URI must look like gpt://<folder-id>/aliceai-llm"
  [[ "$model" == "gpt://$folder_id/"* ]] \
    || die "model URI folder must match YANDEX_FOLDER_ID"
}

validate_yandex_api() {
  local api_key="$1" folder_id="$2" model="$3" response payload
  response=$(mktemp)
  payload=$(printf '%s' '{"model":"'"$model"'","messages":[{"role":"user","content":"Call migration_probe now"}],"tools":[{"type":"function","function":{"name":"migration_probe","description":"Verify agent tool calling","parameters":{"type":"object","properties":{},"additionalProperties":false}}}],"tool_choice":{"type":"function","function":{"name":"migration_probe"}},"max_tokens":32}')
  if ! curl --fail-with-body --silent --show-error --max-time 60 \
      --request POST https://ai.api.cloud.yandex.net/v1/chat/completions \
      --header "Authorization: Api-Key $api_key" \
      --header "OpenAI-Project: $folder_id" \
      --header "Content-Type: application/json" \
      --data "$payload" \
      --output "$response"; then
    rm -f "$response"
    die "YandexGPT API validation failed — check API key, folder ID, roles, scope, billing, and VPS network"
  fi
  if ! grep -q '"choices"' "$response"; then
    rm -f "$response"
    die "YandexGPT API validation returned an unexpected response"
  fi
  if ! grep -q '"tool_calls"' "$response"; then
    rm -f "$response"
    die "selected Yandex model does not support function calling required by Hermes"
  fi
  rm -f "$response"
  log_ok "Yandex AI Studio credentials and model validated"
}

create_backups() {
  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP_DIR="$HOME/.hermes-yandex-migration-backups/$timestamp"
  mkdir -p "$BACKUP_DIR"
  cp "$ENVFILE" "$BACKUP_DIR/config.env"
  chmod 0600 "$BACKUP_DIR/config.env"
  if docker inspect hermes >/dev/null 2>&1; then
    if docker cp hermes:/opt/data/config.yaml "$BACKUP_DIR/config.yaml" >/dev/null 2>&1; then
      chmod 0600 "$BACKUP_DIR/config.yaml"
    else
      log_warn "could not back up /opt/data/config.yaml; .env backup is available"
    fi
  fi
  log_ok "backup created: $BACKUP_DIR"
}

show_recovery() {
  log_warn "migration stopped; backups are in $BACKUP_DIR"
  log_warn "restore .env: cp '$BACKUP_DIR/config.env' '$ENVFILE'"
  if [[ -f "$BACKUP_DIR/config.yaml" ]]; then
    log_warn "restore config: docker cp '$BACKUP_DIR/config.yaml' hermes:/opt/data/config.yaml"
  fi
}

persist_configuration() {
  local api_key="$1" folder_id="$2" model="$3"
  set_env_value "$ENVFILE" YANDEX_API_KEY "$api_key" || true
  set_env_value "$ENVFILE" YANDEX_FOLDER_ID "$folder_id" || true
  set_env_value "$ENVFILE" HERMES_MODEL_PROVIDER "custom:yandex" || true
  set_env_value "$ENVFILE" HERMES_MODEL "$model" || true
  set_env_value "$ENVFILE" HERMES_STT_PROVIDER "yandex" || true
  set_env_value "$ENVFILE" HERMES_YANDEX_STT_MODEL "general" || true
  set_env_value "$ENVFILE" HERMES_YANDEX_STT_TIMEOUT "600" || true
  chmod 0600 "$ENVFILE"
  log_ok "Yandex chat and voice settings saved to config/.env"
}

wait_for_hermes() {
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec hermes hermes --version >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "Hermes did not become ready after container recreation"
}

apply_configuration() {
  bash "$REPO_ROOT/scripts/setup-hermes.sh"
  if [[ -f "$GW_TOML" ]] && toml_get_bool "$GW_TOML" telegram enabled; then
    bash "$REPO_ROOT/scripts/setup-gateway.sh" --restart
  else
    log_act "recreating Hermes container to load Yandex environment"
    docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d --force-recreate >/dev/null
    wait_for_hermes
    log_ok "Hermes container recreated"
  fi
}

main() {
  local api_key folder_id model
  require_operator
  printf 'Hermes migration: Yandex AI Studio chat + SpeechKit voice\n'
  api_key=$(read_required_secret YANDEX_API_KEY)
  folder_id=$(read_required_value YANDEX_FOLDER_ID)
  model=$(read_model "$folder_id")
  validate_inputs "$folder_id" "$model"
  validate_yandex_api "$api_key" "$folder_id" "$model"
  create_backups
  trap show_recovery ERR
  persist_configuration "$api_key" "$folder_id" "$model"
  apply_configuration
  trap - ERR
  log_ok "Migration complete"
  printf '\nSend the Telegram bot a voice message longer than 30 seconds.\n'
  printf 'Then run: bash scripts/vps/check-voice.sh\n'
  printf 'Backups: %s\n' "$BACKUP_DIR"
}

main "$@"
