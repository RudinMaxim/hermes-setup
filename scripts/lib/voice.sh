# shellcheck shell=bash
# Telegram voice (speech-to-text) self-healing for the Hermes container.
#
# Hermes' `stt.provider = local_command` backend invokes the `whisper` binary by
# name. On this 3 GB VPS a local whisper model large enough for accurate Russian
# does not fit, so STT is routed through OpenRouter via a drop-in whisper-CLI
# shim (scripts/vps/openrouter-stt.py). These helpers make every gateway
# setup/restart verify and, if needed, repair that path:
#
#   1. the shim is present and current in the volume (/opt/data/bin);
#   2. `whisper` on PATH points at the shim (re-healed after container recreate);
#   3. the Hermes `stt` config is enabled with provider=local_command;
#   4. OPENROUTER_API_KEY and ffmpeg are available in the container.
#
# Idempotent: a run with nothing to change emits only [SKIP] lines, preserving
# the project's "second run is all [SKIP]" invariant (see tests/README.md).

CONTAINER_STT_DIR=/opt/data/bin
CONTAINER_STT_SCRIPT=/opt/data/bin/openrouter-stt.py
CONTAINER_WHISPER_LINK=/usr/local/bin/whisper

voice_repo_script() {
  printf '%s' "$REPO_ROOT/scripts/vps/openrouter-stt.py"
}

voice_local_sha() {
  sha256sum "$(voice_repo_script)" 2>/dev/null | awk '{print $1}'
}

voice_container_sha() {
  docker exec hermes sh -lc "sha256sum '$CONTAINER_STT_SCRIPT' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true
}

ensure_voice_stt_script() {
  [[ -f "$(voice_repo_script)" ]] \
    || { log_warn "missing $(voice_repo_script) — cannot deploy voice STT shim"; return 1; }
  local local_sha cont_sha
  local_sha="$(voice_local_sha)"
  cont_sha="$(voice_container_sha)"
  if [[ -n "$local_sha" && "$local_sha" == "$cont_sha" ]]; then
    log_skip "voice STT shim already current ($CONTAINER_STT_SCRIPT)"
    return 0
  fi
  log_act "deploying voice STT shim to $CONTAINER_STT_SCRIPT"
  docker exec -u root hermes sh -lc "mkdir -p '$CONTAINER_STT_DIR'"
  docker cp "$(voice_repo_script)" "hermes:$CONTAINER_STT_SCRIPT" >/dev/null
  docker exec -u root hermes sh -lc "chmod +x '$CONTAINER_STT_SCRIPT'"
  log_ok "voice STT shim deployed"
}

ensure_voice_whisper_link() {
  # Hermes calls bare `whisper`; container recreation wipes /usr/local/bin, so
  # re-heal the wrapper on every run when it is missing or points elsewhere.
  if docker exec hermes sh -lc "grep -q 'openrouter-stt.py' '$CONTAINER_WHISPER_LINK' 2>/dev/null"; then
    log_skip "whisper -> OpenRouter STT shim already linked"
    return 0
  fi
  log_act "pointing $CONTAINER_WHISPER_LINK at the OpenRouter STT shim"
  docker exec -u root hermes sh -lc \
    "printf '#!/bin/sh\nexec python3 %s \"\$@\"\n' '$CONTAINER_STT_SCRIPT' > '$CONTAINER_WHISPER_LINK' && chmod +x '$CONTAINER_WHISPER_LINK'"
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

# Verify and, when needed, repair the Telegram voice (STT) path. Safe to call on
# every gateway setup/restart. Never fails the gateway: missing prerequisites
# downgrade to a [WARN] so text messaging still comes up.
ensure_voice_stt() {
  if ! docker_container_running hermes; then
    log_warn "hermes not running; skipping voice STT check"
    return 0
  fi
  if ! docker exec hermes sh -lc 'test -n "$OPENROUTER_API_KEY"'; then
    log_warn "OPENROUTER_API_KEY not set in container — Telegram voice STT disabled until it is configured"
    return 0
  fi
  if ! docker exec hermes sh -lc 'command -v ffmpeg >/dev/null 2>&1'; then
    log_warn "ffmpeg missing in container — voice STT needs it to convert Telegram audio"
  fi

  VOICE_CONFIG_CHANGED=0
  ensure_voice_stt_script || return 0
  ensure_voice_whisper_link
  ensure_voice_stt_config

  if [[ "${VOICE_CONFIG_CHANGED:-0}" == "1" ]]; then
    log_act "restarting hermes to apply stt config"
    docker restart hermes >/dev/null
    wait_for_gateway
  fi
}
