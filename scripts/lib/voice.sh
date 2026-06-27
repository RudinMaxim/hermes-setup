# shellcheck shell=bash
# Telegram voice (speech-to-text) self-healing for the Hermes container.
#
# Hermes invokes a bare `whisper` command for stt.provider=local_command. This
# module deploys a whisper-compatible hosted-STT adapter into the persistent
# volume and restores /usr/local/bin/whisper after every container recreate.

CONTAINER_STT_DIR=/opt/data/bin
CONTAINER_WHISPER_LINK=/usr/local/bin/whisper

voice_provider() {
  local configured
  configured=$(read_env_value "$ENVFILE" HERMES_STT_PROVIDER 2>/dev/null || true)
  if [[ -n "$configured" ]]; then
    printf '%s' "$configured"
  elif env_var_set_in_file "$ENVFILE" YANDEX_API_KEY \
       && env_var_set_in_file "$ENVFILE" YANDEX_FOLDER_ID; then
    printf '%s' yandex
  else
    printf '%s' openrouter
  fi
}

voice_script_name() {
  case "$1" in
    yandex)     printf '%s' yandex-speechkit-stt.py ;;
    openrouter) printf '%s' openrouter-stt.py ;;
    *) return 1 ;;
  esac
}

voice_repo_script() {
  local name
  name=$(voice_script_name "$1") || return 1
  printf '%s' "$REPO_ROOT/scripts/vps/$name"
}

voice_container_script() {
  local name
  name=$(voice_script_name "$1") || return 1
  printf '%s' "$CONTAINER_STT_DIR/$name"
}

voice_local_sha() {
  sha256sum "$(voice_repo_script "$1")" 2>/dev/null | awk '{print $1}'
}

voice_container_sha() {
  local target
  target=$(voice_container_script "$1") || return 1
  docker exec hermes sh -lc "sha256sum '$target' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true
}

ensure_voice_stt_script() {
  local provider="$1" source target local_sha cont_sha
  source=$(voice_repo_script "$provider") \
    || { log_warn "unsupported HERMES_STT_PROVIDER=$provider"; return 1; }
  target=$(voice_container_script "$provider") || return 1
  [[ -f "$source" ]] \
    || { log_warn "missing $source — cannot deploy voice STT shim"; return 1; }

  local_sha=$(voice_local_sha "$provider")
  cont_sha=$(voice_container_sha "$provider")
  if [[ -n "$local_sha" && "$local_sha" == "$cont_sha" ]]; then
    log_skip "voice STT shim already current ($target)"
    return 0
  fi
  log_act "deploying $provider voice STT shim to $target"
  docker exec -u root hermes sh -lc "mkdir -p '$CONTAINER_STT_DIR'"
  docker cp "$source" "hermes:$target" >/dev/null
  docker exec -u root hermes sh -lc "chmod +x '$target'"
  log_ok "voice STT shim deployed"
}

ensure_voice_whisper_link() {
  local provider="$1" target name
  target=$(voice_container_script "$provider") || return 1
  name=$(voice_script_name "$provider") || return 1
  if docker exec hermes sh -lc "grep -q '$name' '$CONTAINER_WHISPER_LINK' 2>/dev/null"; then
    log_skip "whisper -> $provider STT shim already linked"
    return 0
  fi
  log_act "pointing $CONTAINER_WHISPER_LINK at the $provider STT shim"
  docker exec -u root hermes sh -lc \
    "printf '#!/bin/sh\nexec python3 %s \"\$@\"\n' '$target' > '$CONTAINER_WHISPER_LINK' && chmod +x '$CONTAINER_WHISPER_LINK'"
  log_ok "whisper shim linked"
}

ensure_voice_stt_config() {
  local result
  result="$(docker exec -i hermes python3 - <<'PY'
import os, yaml
from pathlib import Path

path = Path(os.environ.get("HERMES_HOME", "/opt/data")) / "config.yaml"
cfg = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
stt = cfg.get("stt") or {}
local = stt.get("local") or {}

changed = (
    not stt.get("enabled")
    or stt.get("provider") != "local_command"
    or local.get("language") != "ru"
)
if changed:
    local["language"] = "ru"
    stt.update({"enabled": True, "provider": "local_command", "local": local})
    cfg["stt"] = stt
    path.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding="utf-8")
    print("CHANGED")
else:
    print("OK")
PY
)" || { log_warn "could not read/update stt config in container"; return 1; }

  case "$result" in
    *CHANGED*) log_act "stt config updated (enabled, provider=local_command, language=ru)"; VOICE_CONFIG_CHANGED=1 ;;
    *OK*)      log_skip "stt config already enabled (local_command, ru)" ;;
    *)         log_warn "unexpected stt config check output: $result" ;;
  esac
}

ensure_voice_credentials() {
  local provider="$1"
  case "$provider" in
    yandex)
      if ! docker exec hermes sh -lc 'test -n "$YANDEX_API_KEY"'; then
        log_warn "YANDEX_API_KEY not set in container — Telegram voice STT disabled until it is configured"
        return 1
      fi
      if ! docker exec hermes sh -lc 'test -n "$YANDEX_FOLDER_ID"'; then
        log_warn "YANDEX_FOLDER_ID not set in container — Telegram voice STT disabled until it is configured"
        return 1
      fi
      ;;
    openrouter)
      if ! docker exec hermes sh -lc 'test -n "$OPENROUTER_API_KEY"'; then
        log_warn "OPENROUTER_API_KEY not set in container — Telegram voice STT disabled until it is configured"
        return 1
      fi
      if ! docker exec hermes sh -lc 'command -v ffmpeg >/dev/null 2>&1'; then
        log_warn "ffmpeg missing in container — OpenRouter voice STT needs audio conversion"
      fi
      ;;
    *)
      log_warn "unsupported HERMES_STT_PROVIDER=$provider (expected yandex or openrouter)"
      return 1
      ;;
  esac
}

# Safe to call on every gateway setup/restart. Missing voice prerequisites are
# warnings: they must never take down text messaging.
ensure_voice_stt() {
  local provider
  if ! docker_container_running hermes; then
    log_warn "hermes not running; skipping voice STT check"
    return 0
  fi
  provider=$(voice_provider)
  ensure_voice_credentials "$provider" || return 0

  VOICE_CONFIG_CHANGED=0
  ensure_voice_stt_script "$provider" || return 0
  ensure_voice_whisper_link "$provider"
  ensure_voice_stt_config

  if [[ "${VOICE_CONFIG_CHANGED:-0}" == "1" ]]; then
    log_act "restarting hermes to apply stt config"
    docker restart hermes >/dev/null
    wait_for_gateway
  fi
}
