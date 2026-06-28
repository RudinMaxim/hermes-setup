#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

STUB=/tmp/gw-bin-stub
STATE=/tmp/.gw-stub-cmd
STATUS=/tmp/.gw-stub-status

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  mkdir -p "$STUB"
  rm -f "$STATE" "$STATUS" /tmp/.gw-status-checks \
        /tmp/.gw-stt-sha /tmp/.gw-whisper-link /tmp/.gw-stt-config

  # docker stub: models PID-1 command via $STATE, reports container running.
  cat >"$STUB/docker" <<'DOCKER'
#!/usr/bin/env bash
STATE=/tmp/.gw-stub-cmd
STATUS=/tmp/.gw-stub-status
STT_SHA=/tmp/.gw-stt-sha
WHISPER_LINK=/tmp/.gw-whisper-link
STT_CFG=/tmp/.gw-stt-config
case "$*" in
  "ps -a --format {{.Names}}") echo hermes ;;
  "inspect -f "*"State.Status"*)  [[ -f "$STATUS" ]] && cat "$STATUS" || echo running ;;
  "inspect -f "*"Config.Cmd"*)    [[ -f "$STATE" ]] && cat "$STATE" || echo hermes ;;
  *"docker-compose.gateway.yml up -d --force-recreate"*) echo "gateway run" >"$STATE"; echo running >"$STATUS"; printf '%s\n' "${HERMES_IMAGE:-}" > /tmp/.gw-image; echo restarted ;;
  *"docker-compose.gateway.yml up -d"*) echo "gateway run" >"$STATE"; echo running >"$STATUS"; printf '%s\n' "${HERMES_IMAGE:-}" > /tmp/.gw-image; echo up ;;
  *"up -d --force-recreate"*)     echo "hermes" >"$STATE"; echo running >"$STATUS"; printf '%s\n' "${HERMES_IMAGE:-}" > /tmp/.gw-image; echo recreated ;;
  "exec hermes hermes gateway status"*) echo status >> /tmp/.gw-status-checks; exit 0 ;;
  "exec hermes sh -lc test -f /opt/data/google_token.json"*) [[ "${GOOGLE_TOKEN_PRESENT:-0}" = "1" ]] && exit 0 || exit 1 ;;
  "exec -u root hermes sh -lc mkdir -p /home/hermes/.hermes && ln -sf /opt/data/google_token.json /home/hermes/.hermes/google_token.json && chown -h hermes:hermes /home/hermes/.hermes/google_token.json"*) echo "$*" > /tmp/.gw-token-link; exit 0 ;;
  # --- voice STT path (lib/voice.sh) -----------------------------------------
  *YANDEX_API_KEY*) [[ "${YANDEX_KEY_MISSING:-0}" = "1" ]] && exit 1 || exit 0 ;;
  *YANDEX_FOLDER_ID*) [[ "${YANDEX_FOLDER_MISSING:-0}" = "1" ]] && exit 1 || exit 0 ;;
  *OPENROUTER_API_KEY*) touch /tmp/.gw-openrouter-key-checked; exit 0 ;;
  *"command -v ffmpeg"*) exit 0 ;;
  "cp "*"yandex-speechkit-stt.py"*) sha256sum "$2" | awk '{print $1}' > "$STT_SHA"; exit 0 ;;
  *sha256sum*yandex-speechkit-stt.py*) [[ -f "$STT_SHA" ]] && cat "$STT_SHA"; exit 0 ;;
  *"grep -q "*"yandex-speechkit-stt.py"*) [[ -f "$WHISPER_LINK" ]] && exit 0 || exit 1 ;;
  "cp "*"openrouter-stt.py"*) sha256sum "$2" | awk '{print $1}' > "$STT_SHA"; exit 0 ;;
  *sha256sum*openrouter-stt.py*) [[ -f "$STT_SHA" ]] && cat "$STT_SHA"; exit 0 ;;
  *"grep -q "*"openrouter-stt.py"*) [[ -f "$WHISPER_LINK" ]] && exit 0 || exit 1 ;;
  *printf*whisper*) touch "$WHISPER_LINK"; exit 0 ;;
  "exec -i hermes python3 -") [[ -f "$STT_CFG" ]] && echo OK || { echo CHANGED; touch "$STT_CFG"; } ;;
  "restart hermes") echo restarted ;;
  *) echo "stub: $*" ;;
esac
DOCKER
  chmod +x "$STUB/docker"

  # curl stub: returns $GETME_RESPONSE for getMe URLs.
  cat >"$STUB/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
  *getMe*) printf '%s' "${GETME_RESPONSE:-{\"ok\":true,\"result\":{\"username\":\"test_bot\"}}}" ;;
  *) exit 1 ;;
esac
CURL
  chmod +x "$STUB/curl"

  # Fresh gateways.toml + .env owned by hermes.
  cp "$REPO_ROOT/config/gateways.toml.example" "$REPO_ROOT/config/gateways.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^YANDEX_API_KEY=|YANDEX_API_KEY=test-yandex-key|' "$REPO_ROOT/config/.env"
  sed -i 's|^YANDEX_FOLDER_ID=|YANDEX_FOLDER_ID=b1gtestfolder|' "$REPO_ROOT/config/.env"
  sed -i 's|^HERMES_STT_PROVIDER=.*|HERMES_STT_PROVIDER=yandex|' "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/gateways.toml" "$REPO_ROOT/config/.env"
}

teardown() {
  rm -rf "$STUB" "$STATE" "$STATUS" /tmp/.gw-image /tmp/.gw-status-checks /tmp/.gw-token-link \
         /tmp/.gw-stt-sha /tmp/.gw-whisper-link /tmp/.gw-stt-config /tmp/.gw-openrouter-key-checked
  rm -f "$REPO_ROOT/config/gateways.toml"
}

# Flip ONLY the first `enabled = false` (the [telegram] section) — the [webui]
# section uses an identical line, so an unanchored global sed would enable both.
enable_telegram() {
  sed -i '0,/^enabled = false/s//enabled = true/' "$REPO_ROOT/config/gateways.toml"
  printf 'TELEGRAM_BOT_TOKEN=123:ABC\nTELEGRAM_ALLOWED_USERS=111,222\n' >> "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/.env" "$REPO_ROOT/config/gateways.toml"
}

@test "setup-gateway.sh brings up the telegram gateway when enabled + valid" {
  enable_telegram
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"telegram gateway is up"* ]]
  [ "$(cat "$STATE")" = "gateway run" ]
}

@test "setup-gateway.sh dies on an invalid token" {
  enable_telegram
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 GETME_RESPONSE='{\"ok\":false}' bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected the token"* ]]
}

@test "setup-gateway.sh dies on a non-numeric allowlist (before any network call)" {
  sed -i '0,/^enabled = false/s//enabled = true/' "$REPO_ROOT/config/gateways.toml"
  printf 'TELEGRAM_BOT_TOKEN=123:ABC\nTELEGRAM_ALLOWED_USERS=abc\n' >> "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/.env" "$REPO_ROOT/config/gateways.toml"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"comma-separated numeric"* ]]
}

@test "setup-gateway.sh is idempotent when telegram stays enabled" {
  enable_telegram
  assert_idempotent su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
}

@test "setup-gateway.sh deploys and configures the voice STT path" {
  enable_telegram
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"voice STT shim deployed"* ]]
  [[ "$output" == *"whisper shim linked"* ]]
  [[ "$output" == *"stt config updated"* ]]
  [ ! -f /tmp/.gw-openrouter-key-checked ]
}

@test "setup-gateway.sh re-heals the whisper link when it is missing (container recreate)" {
  enable_telegram
  echo "gateway run" > "$STATE"
  # Simulate state after a container recreate: shim + config survive in the
  # volume, but the /usr/local/bin/whisper link was wiped.
  sha256sum "$REPO_ROOT/scripts/vps/yandex-speechkit-stt.py" | awk '{print $1}' > /tmp/.gw-stt-sha
  touch /tmp/.gw-stt-config
  rm -f /tmp/.gw-whisper-link
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"whisper shim linked"* ]]
  [[ "$output" == *"voice STT shim already current"* ]]
  [[ "$output" == *"stt config already enabled"* ]]
}

@test "setup-gateway.sh warns and skips Yandex voice STT when YANDEX_API_KEY is absent" {
  enable_telegram
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 YANDEX_KEY_MISSING=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"YANDEX_API_KEY not set"* ]]
  [[ "$output" != *"voice STT shim deployed"* ]]
}

@test "check-voice.sh reports Yandex backend without OpenRouter ping" {
  touch /tmp/.gw-whisper-link /tmp/.gw-stt-config

  run env PATH="$STUB:$PATH" bash "$SCRIPTS/vps/check-voice.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend: yandex"* ]]
  [[ "$output" == *"YANDEX_API_KEY is set"* ]]
  [[ "$output" == *"YANDEX_FOLDER_ID is set"* ]]
  [[ "$output" != *"OpenRouter ping"* ]]
  [ ! -f /tmp/.gw-openrouter-key-checked ]
}

@test "check-voice.sh requires complete Yandex credentials for automatic selection" {
  sed -i 's|^YANDEX_FOLDER_ID=.*|YANDEX_FOLDER_ID=|' "$REPO_ROOT/config/.env"
  sed -i 's|^HERMES_STT_PROVIDER=.*|HERMES_STT_PROVIDER=|' "$REPO_ROOT/config/.env"
  sed -i 's|^OPENROUTER_API_KEY=.*|OPENROUTER_API_KEY=legacy-test-key|' "$REPO_ROOT/config/.env"
  touch /tmp/.gw-whisper-link /tmp/.gw-stt-config

  run env PATH="$STUB:$PATH" bash "$SCRIPTS/vps/check-voice.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend: openrouter"* ]]
  [ -f /tmp/.gw-openrouter-key-checked ]
}

@test "setup-gateway.sh preserves automatic OpenRouter voice fallback" {
  enable_telegram
  sed -i 's|^YANDEX_API_KEY=.*|YANDEX_API_KEY=|' "$REPO_ROOT/config/.env"
  sed -i 's|^YANDEX_FOLDER_ID=.*|YANDEX_FOLDER_ID=|' "$REPO_ROOT/config/.env"
  sed -i 's|^HERMES_STT_PROVIDER=.*|HERMES_STT_PROVIDER=|' "$REPO_ROOT/config/.env"
  sed -i 's|^OPENROUTER_API_KEY=.*|OPENROUTER_API_KEY=legacy-test-key|' "$REPO_ROOT/config/.env"

  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"deploying openrouter voice STT shim"* ]]
  [ -f /tmp/.gw-openrouter-key-checked ]
}

@test "setup-gateway.sh does not call Telegram when gateway is already active" {
  enable_telegram
  echo "gateway run" > "$STATE"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 GETME_RESPONSE='{\"ok\":false}' bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"telegram gateway already running"* ]]
}

@test "setup-gateway.sh recreates a legacy duplicated gateway command" {
  enable_telegram
  echo "hermes gateway run" > "$STATE"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy gateway command"* ]]
  [[ "$output" == *"telegram gateway restarted"* ]]
  [ "$(cat "$STATE")" = "gateway run" ]
}

@test "setup-gateway.sh recreates an active gateway command when the container is stopped" {
  enable_telegram
  echo "gateway run" > "$STATE"
  echo "exited" > "$STATUS"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"telegram gateway command is configured but container is not running"* ]]
  [[ "$output" == *"telegram gateway restarted"* ]]
  [ "$(cat "$STATE")" = "gateway run" ]
  [ "$(cat "$STATUS")" = "running" ]
}

@test "setup-gateway.sh links the Workspace token path before reporting an active gateway" {
  enable_telegram
  echo "gateway run" > "$STATE"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 GOOGLE_TOKEN_PRESENT=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"google workspace token link is ready"* ]]
  [[ "$output" == *"telegram gateway already running"* ]]
  grep -q 'ln -sf /opt/data/google_token.json /home/hermes/.hermes/google_token.json' /tmp/.gw-token-link
}

@test "setup-gateway.sh --restart recreates an already active telegram gateway" {
  enable_telegram
  echo "gateway run" > "$STATE"
  rm -f /tmp/.gw-status-checks
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 GOOGLE_TOKEN_PRESENT=1 bash '$SCRIPTS/setup-gateway.sh' --restart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restarting telegram gateway"* ]]
  [[ "$output" == *"google workspace token link is ready"* ]]
  [[ "$output" == *"telegram gateway restarted"* ]]
  [ "$(cat "$STATE")" = "gateway run" ]
  grep -q 'ln -sf /opt/data/google_token.json /home/hermes/.hermes/google_token.json' /tmp/.gw-token-link
  [ "$(wc -l < /tmp/.gw-status-checks)" -ge 3 ]
}

@test "setup-gateway.sh reuses persisted HERMES_IMAGE when recreating the container" {
  enable_telegram
  printf 'HERMES_IMAGE=hermes-agent:local\n' >> "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/.env"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [ "$(cat /tmp/.gw-image)" = "hermes-agent:local" ]
}

@test "setup-gateway.sh rolls back to idle when telegram is disabled" {
  enable_telegram
  su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  grep -q 'gateway run' "$STATE"
  # now disable
  sed -i 's|^enabled = true|enabled = false|' "$REPO_ROOT/config/gateways.toml"
  chown hermes "$REPO_ROOT/config/gateways.toml"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"back to idle"* ]]
  ! grep -q 'gateway run' "$STATE"
}

@test "setup.sh runs the hermes step and completes (non-interactive, as hermes)" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/.env"
  run su hermes -c "HERMES_NONINTERACTIVE=1 bash '$REPO_ROOT/setup.sh' --non-interactive --configs-only"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running setup-hermes.sh"* ]]
  [[ "$output" == *"setup complete"* ]]
}

@test "setup.sh warns when run as root" {
  # As root the orchestrator prints the warning, then setup-hermes refuses to
  # run as root — we only assert the warning is shown.
  run bash "$REPO_ROOT/setup.sh" --non-interactive
  [[ "$output" == *"run setup-server.sh as root separately"* ]]
}
