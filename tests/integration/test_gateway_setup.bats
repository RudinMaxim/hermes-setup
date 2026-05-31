#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

STUB=/tmp/gw-bin-stub
STATE=/tmp/.gw-stub-cmd

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  mkdir -p "$STUB"
  rm -f "$STATE"

  # docker stub: models PID-1 command via $STATE, reports container running.
  cat >"$STUB/docker" <<'DOCKER'
#!/usr/bin/env bash
STATE=/tmp/.gw-stub-cmd
case "$*" in
  "inspect -f "*"State.Status"*)  echo running ;;
  "inspect -f "*"Config.Cmd"*)    [[ -f "$STATE" ]] && cat "$STATE" || echo hermes ;;
  *"docker-compose.gateway.yml up -d"*) echo "hermes gateway run" >"$STATE"; echo up ;;
  *"up -d --force-recreate"*)     echo "hermes" >"$STATE"; echo recreated ;;
  "exec hermes hermes gateway status"*) exit 0 ;;
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
  chown hermes "$REPO_ROOT/config/gateways.toml" "$REPO_ROOT/config/.env"
}

teardown() {
  rm -rf "$STUB" "$STATE"
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
  grep -q 'gateway run' "$STATE"
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
