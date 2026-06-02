#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  cp "$REPO_ROOT/config/mcp.toml.example" "$REPO_ROOT/config/mcp.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  chown -R hermes:hermes "$REPO_ROOT/config"
}

teardown() {
  cp "$REPO_ROOT/config/mcp.toml.example" "$REPO_ROOT/config/mcp.toml"
}

# Comprehensive docker stub: container looks running, /var/run/docker.sock is
# mounted, npm package is missing (so install runs), and Hermes config writes /
# smoke tests succeed. Individual tests override the configured-MCP list as needed.
make_docker_stub() {
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f")
    case "$*" in
      *".State.Status"*) echo running ;;
      *"range .Mounts"*) echo /var/run/docker.sock ;;
      *) echo "" ;;
    esac ;;
  "exec hermes")
    shift 2
    case "$*" in
      "bash -c npm list -g --depth=0 2>/dev/null | grep"*) exit 1 ;;
      "npm install -g "*) echo installed ;;
      "hermes mcp test "*) exit 0 ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") echo "" ;;
      "python3 - "*) echo "configured: $*" ;;
      *) echo "exec-i-stub: $*" ;;
    esac ;;
  "compose"*) echo "compose: $*" ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
}

@test "setup-mcp.sh refuses to run when hermes container is missing" {
  run su hermes -c "bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hermes container is not running"* ]]
}

@test "setup-mcp.sh adds new example sections to an existing mcp.toml" {
  awk '
    /^\[docker_mcp\]$/ { skip = 1; next }
    /^\[/ && skip { skip = 0 }
    !skip { print }
  ' "$REPO_ROOT/config/mcp.toml.example" > "$REPO_ROOT/config/mcp.toml"

  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  grep -q '^\[docker_mcp\]$' "$REPO_ROOT/config/mcp.toml"
  [[ "$output" == *"added mcp.docker_mcp to config/mcp.toml from example"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh fills missing keys in an existing docker_mcp section" {
  cat >"$REPO_ROOT/config/mcp.toml" <<'TOML'
[docker_mcp]
enabled = false
TOML

  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  grep -q '^transport = "stdio"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^package = "@modelcontextprotocol/server-docker"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^acknowledge_socket_risk = true$' "$REPO_ROOT/config/mcp.toml"
  [[ "$output" == *"updated mcp.docker_mcp in config/mcp.toml from example"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh installs npm package + registers stdio MCP" {
  # Only docker_mcp enabled (it has the socket already mounted via the stub).
  sed -i '/^\[playwright\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"

  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installing @modelcontextprotocol/server-docker"* ]]
  [[ "$output" == *"registered mcp 'docker_mcp'"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh registers an http MCP" {
  # Only playwright enabled.
  sed -i '/^\[docker_mcp\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"

  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered mcp 'playwright' (http)"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh removes MCPs that were disabled in toml" {
  sed -i '/^\[playwright\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"
  sed -i '/^\[docker_mcp\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      *) echo "" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") echo playwright ;;
      "python3 - playwright") touch /tmp/.removed ;;
      *) echo "" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.removed

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [ -f /tmp/.removed ]
  [[ "$output" == *"unregistering mcp 'playwright'"* ]]

  rm -rf /tmp/bin-stub /tmp/.removed
}

@test "setup-mcp.sh does not remove MCPs it does not manage" {
  sed -i '/^\[playwright\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"
  sed -i '/^\[docker_mcp\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      *) echo "" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") printf 'playwright\nmanual_server\n' ;;
      "python3 - playwright") echo playwright >> /tmp/.removed ;;
      "python3 - manual_server") echo manual_server >> /tmp/.removed ;;
      *) echo "" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.removed

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [ -f /tmp/.removed ]
  grep -qx playwright /tmp/.removed
  ! grep -qx manual_server /tmp/.removed

  rm -rf /tmp/bin-stub /tmp/.removed
}

@test "setup-mcp.sh refuses docker_mcp without acknowledge_socket_risk" {
  sed -i '/^\[playwright\]/,/^$/ s|^enabled = true$|enabled = false|' "$REPO_ROOT/config/mcp.toml"
  sed -i '/^\[docker_mcp\]/,/^$/ s|^acknowledge_socket_risk = true$|acknowledge_socket_risk = false|' "$REPO_ROOT/config/mcp.toml"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [[ "$output" == *"acknowledge_socket_risk"* ]]
  rm -rf /tmp/bin-stub
}
