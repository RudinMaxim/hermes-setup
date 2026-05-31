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

@test "setup-mcp.sh refuses to run when hermes container is missing" {
  run su hermes -c "bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hermes container is not running"* ]]
}

@test "setup-mcp.sh reports missing required env for enabled github" {
  sed -i '/^\[github\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ps -a --format "*) echo hermes ;;
  "inspect -f "*) echo running ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [[ "$output" == *"mcp.github: missing GITHUB_TOKEN"* ]]
  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh installs npm package + registers stdio MCP" {
  sed -i '/^\[github\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  sed -i 's|^GITHUB_TOKEN=$|GITHUB_TOKEN=ghp_test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "bash -c npm list -g --depth=0 2>/dev/null | grep"*) exit 1 ;;
      "npm install -g "*) echo "installed" ;;
      "hermes mcp list --quiet") echo "" ;;
      "hermes mcp add"*) echo "added: $*" ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installing @modelcontextprotocol/server-github"* ]]
  [[ "$output" == *"registering mcp 'github'"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh removes MCPs that were disabled in toml" {
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "hermes mcp list --quiet") echo github ;;
      "hermes mcp remove "*) echo "removed"; touch /tmp/.removed ;;
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
  [[ "$output" == *"unregistering mcp 'github'"* ]]

  rm -rf /tmp/bin-stub /tmp/.removed
}

@test "setup-mcp.sh does not remove MCPs it does not manage" {
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "hermes mcp list --quiet") printf 'github\nmanual_server\n' ;;
      "hermes mcp remove github") echo github >> /tmp/.removed ;;
      "hermes mcp remove manual_server") echo manual_server >> /tmp/.removed ;;
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
  grep -qx github /tmp/.removed
  ! grep -qx manual_server /tmp/.removed

  rm -rf /tmp/bin-stub /tmp/.removed
}

@test "setup-mcp.sh registers filesystem MCP with the configured mount path" {
  sed -i '/^\[filesystem\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  sed -i '/^\[filesystem\]/,/^$/ s|^mount = .*$|mount = "/home/hermes/projects"|' "$REPO_ROOT/config/mcp.toml"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "bash -c npm list -g --depth=0 2>/dev/null | grep"*) exit 1 ;;
      "npm install -g "*) echo installed ;;
      "hermes mcp list --quiet") echo "" ;;
      "hermes mcp add"*) printf '%s\n' "$*" > /tmp/.mcp-add ;;
      "hermes mcp test filesystem") exit 0 ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.mcp-add

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  grep -q -- '--command npx' /tmp/.mcp-add
  grep -q -- '--args -y @modelcontextprotocol/server-filesystem /home/hermes/projects' /tmp/.mcp-add

  rm -rf /tmp/bin-stub /tmp/.mcp-add
}

@test "setup-mcp.sh refuses docker_mcp without acknowledge_socket_risk" {
  sed -i '/^\[docker_mcp\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"

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
