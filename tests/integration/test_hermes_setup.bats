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

@test "setup-hermes.sh accepts OPENROUTER_API_KEY alone" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENROUTER_API_KEY=|OPENROUTER_API_KEY=sk-or-test|' "$REPO_ROOT/config/.env"
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

@test "setup-hermes.sh fails early when Docker is not accessible" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) echo "permission denied" >&2; exit 1 ;;
  *) echo "unexpected docker call: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot access Docker daemon"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-hermes.sh persists the selected local fallback image" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  image) exit 1 ;;
  pull) exit 1 ;;
  build) exit 0 ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -eq 0 ]
  grep -qx 'HERMES_IMAGE=hermes-agent:local' "$REPO_ROOT/config/.env"

  rm -rf /tmp/bin-stub
}

@test "setup-hermes.sh builds fallback image from the Ubuntu 26.04 Docker Hub mirror base" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  image) exit 1 ;;
  pull) exit 1 ;;
  build) printf '%s\n' "$*" > /tmp/.hermes-build-args; exit 0 ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -eq 0 ]
  grep -q -- '--build-arg BASE_IMAGE=public.ecr.aws/docker/library/ubuntu:26.04' /tmp/.hermes-build-args

  rm -rf /tmp/bin-stub /tmp/.hermes-build-args
}

@test "fallback Dockerfile makes useradd available before using it" {
  grep -q 'passwd' "$REPO_ROOT/docker/Dockerfile.hermes"
  grep -q 'PATH=.*:/usr/sbin:.*:/sbin:' "$REPO_ROOT/docker/Dockerfile.hermes"
  grep -q 'useradd -m -s /bin/bash hermes' "$REPO_ROOT/docker/Dockerfile.hermes"
}

@test "fallback Dockerfile installs xz for Hermes Node tarballs" {
  grep -q 'xz-utils' "$REPO_ROOT/docker/Dockerfile.hermes"
}

@test "fallback Dockerfile runs the gateway in foreground" {
  grep -q 'CMD \["gateway", "run"\]' "$REPO_ROOT/docker/Dockerfile.hermes"
}

@test "setup-hermes.sh lets config override the fallback base image" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  sed -i 's|^HERMES_FALLBACK_BASE_IMAGE=.*|HERMES_FALLBACK_BASE_IMAGE=ubuntu:24.04|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  image) exit 1 ;;
  pull) exit 1 ;;
  build) printf '%s\n' "$*" > /tmp/.hermes-build-args; exit 0 ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -eq 0 ]
  grep -q -- '--build-arg BASE_IMAGE=ubuntu:24.04' /tmp/.hermes-build-args

  rm -rf /tmp/bin-stub /tmp/.hermes-build-args
}

@test "setup-hermes.sh streams fallback build output" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  image) exit 1 ;;
  pull) exit 1 ;;
  build)
    echo "build-progress-marker"
    exit 1
    ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build-progress-marker"* ]]
  [[ "$output" == *"fallback docker build failed"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-hermes.sh explains Docker Hub rate limits during fallback build" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  sed -i 's|^HERMES_FALLBACK_BASE_IMAGE=.*|HERMES_FALLBACK_BASE_IMAGE=ubuntu:24.04|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  image) exit 1 ;;
  pull) exit 1 ;;
  build)
    cat >&2 <<'EOF'
ERROR: failed to build: failed to solve: ubuntu:24.04: failed to resolve source metadata for docker.io/library/ubuntu:24.04: unexpected status from GET request: 429 Too Many Requests
toomanyrequests: You have reached your unauthenticated pull rate limit.
EOF
    exit 1
    ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker Hub anonymous pull rate limit"* ]]
  [[ "$output" == *"current fallback base image: ubuntu:24.04"* ]]
  [[ "$output" == *"HERMES_FALLBACK_BASE_IMAGE=public.ecr.aws/docker/library/ubuntu:26.04"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-hermes.sh recreates a running container when the projects mount is missing" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "info") exit 0 ;;
  "image inspect nousresearch/hermes-agent:latest") exit 0 ;;
  "volume inspect hermes_data") exit 0 ;;
  "network inspect hermes_net") exit 0 ;;
  "inspect -f {{.State.Status}} hermes") echo running ;;
  "inspect -f "*"Mounts"*" hermes") echo "/home/hermes/.hermes" ;;
  "compose "*"up -d --force-recreate") touch /tmp/.hermes-recreated; echo recreated ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.hermes-recreated

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -eq 0 ]
  [ -f /tmp/.hermes-recreated ]
  [[ "$output" == *"recreating container 'hermes' to apply compose mounts"* ]]

  rm -rf /tmp/bin-stub /tmp/.hermes-recreated
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
  "inspect -f "*"Mounts"*" hermes") echo "/home/hermes/projects" ;;
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
