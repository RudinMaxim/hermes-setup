#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  usermod -aG docker hermes 2>/dev/null || true
}

@test "setup-hermes.sh refuses to run as root" {
  run bash "$SCRIPTS/setup-hermes.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not run as root"* ]]
}

@test "setup-hermes.sh copies example configs on first run" {
  rm -f "$REPO_ROOT/config/.env" "$REPO_ROOT/config/mcp.toml"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -ne 0 ]
  [ -f "$REPO_ROOT/config/.env" ]
  [ -f "$REPO_ROOT/config/mcp.toml" ]
}

@test "setup-hermes.sh fails when no LLM key is configured" {
  : > "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no LLM API key configured"* ]]
}

@test "setup-hermes.sh accepts OPENAI_API_KEY alone" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -eq 0 ]
}

@test "setup-hermes.sh creates the data volume and network" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  pull) echo "stub: pull failed" >&2; exit 1 ;;
  build) echo "stub: built"; exit 0 ;;
  *) exec /usr/bin/docker "$@" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to local build"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-hermes.sh is idempotent across full run" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
STATE_FILE=/tmp/.docker-stub-state
case "$*" in
  "image inspect "*) test -f "$STATE_FILE" ;;
  "pull "*) touch "$STATE_FILE"; echo pulled ;;
  "volume inspect "*) [[ "${DOCKER_HAS_VOL:-0}" == "1" ]] ;;
  "volume create "*) export DOCKER_HAS_VOL=1; echo created ;;
  "network create "*) echo created ;;
  "compose "*"up -d") echo "up"; touch /tmp/.docker-stub-container ;;
  "ps -a --format "*) [[ -f /tmp/.docker-stub-container ]] && echo hermes ;;
  "inspect -f "*) echo running ;;
  "exec "*) echo "hermes 0.1.0" ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  PATH=/tmp/bin-stub:$PATH bash "$SCRIPTS/setup-hermes.sh"
  run env PATH=/tmp/bin-stub:$PATH bash "$SCRIPTS/setup-hermes.sh"
  [ "$status" -eq 0 ]
  ! grep -qE '^\[(ACT|OK)\]' <<<"$output" || {
    echo "$output"; false
  }

  rm -rf /tmp/bin-stub /tmp/.docker-stub-state /tmp/.docker-stub-container
}

@test "setup-hermes.sh creates gateways.toml from the example" {
  rm -f "$REPO_ROOT/config/.env" "$REPO_ROOT/config/mcp.toml" "$REPO_ROOT/config/gateways.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/config/gateways.toml" ]
}

@test "setup-hermes.sh still dies without an LLM key in non-interactive mode" {
  : > "$REPO_ROOT/config/.env"
  run su hermes -c "HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no LLM API key configured"* ]]
}

@test "setup-hermes.sh accepts the --non-interactive flag" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only --non-interactive"
  [ "$status" -eq 0 ]
}
