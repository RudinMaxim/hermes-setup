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

@test "setup-mcp.sh adds new example sections to an existing mcp.toml" {
  awk '
    /^\[google_drive\]$/ { skip = 1; next }
    /^\[/ && skip { skip = 0 }
    !skip { print }
  ' "$REPO_ROOT/config/mcp.toml.example" > "$REPO_ROOT/config/mcp.toml"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") echo "" ;;
      *) echo "" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  grep -q '^\[google_drive\]$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^enabled = false$' "$REPO_ROOT/config/mcp.toml"
  [[ "$output" == *"added mcp.google_drive to config/mcp.toml from example"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh fills missing keys in an existing google_drive section" {
  cat >"$REPO_ROOT/config/mcp.toml" <<'TOML'
[google_drive]
enabled = true
TOML

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") echo "" ;;
      *) echo "" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  grep -q '^enabled = true$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^transport = "http"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^url = "https://drivemcp.googleapis.com/mcp/v1"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^auth = "oauth"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^oauth_client_id_env = "GOOGLE_DRIVE_OAUTH_CLIENT_ID"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^oauth_client_secret_env = "GOOGLE_DRIVE_OAUTH_CLIENT_SECRET"$' "$REPO_ROOT/config/mcp.toml"
  grep -q '^requires = \["GOOGLE_DRIVE_OAUTH_CLIENT_ID", "GOOGLE_DRIVE_OAUTH_CLIENT_SECRET"\]$' "$REPO_ROOT/config/mcp.toml"
  [[ "$output" == *"updated mcp.google_drive in config/mcp.toml from example"* ]]
  [[ "$output" == *"mcp.google_drive: missing GOOGLE_DRIVE_OAUTH_CLIENT_ID GOOGLE_DRIVE_OAUTH_CLIENT_SECRET"* ]]

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
      *) echo "exec-stub: $*" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 - github") exit 1 ;;
      "python3 - github stdio npx "*"GITHUB_TOKEN"*) echo "configured: $*" ;;
      *) echo "exec-i-stub: $*" ;;
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
      *) echo "" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") echo github ;;
      "python3 - github") touch /tmp/.removed ;;
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
      *) echo "" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 -") printf 'github\nmanual_server\n' ;;
      "python3 - github") echo github >> /tmp/.removed ;;
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
      "hermes mcp test filesystem") exit 0 ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 - filesystem") exit 1 ;;
      "python3 - filesystem stdio npx "*"@modelcontextprotocol/server-filesystem"*) printf '%s\n' "$*" > /tmp/.mcp-add ;;
      *) echo "exec-i-stub: $*" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.mcp-add

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  grep -q -- 'filesystem stdio npx' /tmp/.mcp-add
  grep -q -- '-y @modelcontextprotocol/server-filesystem /home/hermes/projects' /tmp/.mcp-add

  rm -rf /tmp/bin-stub /tmp/.mcp-add
}

@test "setup-mcp.sh registers Google Drive as remote OAuth MCP" {
  sed -i '/^\[google_drive\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  sed -i 's|^GOOGLE_DRIVE_OAUTH_CLIENT_ID=$|GOOGLE_DRIVE_OAUTH_CLIENT_ID=client-id.apps.googleusercontent.com|' "$REPO_ROOT/config/.env"
  sed -i 's|^GOOGLE_DRIVE_OAUTH_CLIENT_SECRET=$|GOOGLE_DRIVE_OAUTH_CLIENT_SECRET=client-secret|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "hermes mcp test google_drive") echo "unexpected smoke test for oauth mcp" >&2; exit 1 ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 - google_drive") exit 1 ;;
      "python3 - google_drive http "*"https://drivemcp.googleapis.com/mcp/v1"*"oauth"*"GOOGLE_DRIVE_OAUTH_CLIENT_ID"*"GOOGLE_DRIVE_OAUTH_CLIENT_SECRET"*)
        printf '%s\n' "$*" > /tmp/.gdrive-mcp-add ;;
      *) echo "exec-i-stub: $*" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.gdrive-mcp-add

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OAuth login required"* ]]
  grep -q -- 'google_drive http' /tmp/.gdrive-mcp-add
  grep -q -- 'https://drivemcp.googleapis.com/mcp/v1' /tmp/.gdrive-mcp-add
  grep -q -- 'oauth GOOGLE_DRIVE_OAUTH_CLIENT_ID GOOGLE_DRIVE_OAUTH_CLIENT_SECRET' /tmp/.gdrive-mcp-add
  grep -q -- 'https://www.googleapis.com/auth/drive.readonly,https://www.googleapis.com/auth/drive.metadata.readonly' /tmp/.gdrive-mcp-add

  rm -rf /tmp/bin-stub /tmp/.gdrive-mcp-add
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
