#!/usr/bin/env bats

load '../helpers/setup_suite'

STUB=/tmp/gw-stabilize-bin

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  mkdir -p "$STUB"
  rm -f /tmp/.gw-stabilize-link /tmp/.gw-stabilize-config /tmp/.gw-stabilize-restart

  cat >"$STUB/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ps -a --format {{.Names}}") echo hermes ;;
  "inspect -f {{.State.Status}} hermes") echo running ;;
  "exec hermes sh -lc test -f /opt/data/google_token.json") exit 0 ;;
  "exec -u root hermes sh -lc mkdir -p /home/hermes/.hermes && ln -sf /opt/data/google_token.json /home/hermes/.hermes/google_token.json && chown -h hermes:hermes /home/hermes/.hermes/google_token.json") echo linked > /tmp/.gw-stabilize-link ;;
  "exec -i hermes python3 -") cat >/tmp/.gw-stabilize-config; echo disabled ;;
  "exec hermes hermes config check") echo checked ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x "$STUB/docker"

  cat >"$STUB/setup-gateway.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > /tmp/.gw-stabilize-restart
echo restarted
STUB
  chmod +x "$STUB/setup-gateway.sh"
}

teardown() {
  rm -rf "$STUB" /tmp/.gw-stabilize-link /tmp/.gw-stabilize-config /tmp/.gw-stabilize-restart
}

@test "stabilize-google-workspace links token, disables remote MCP, and restarts gateway" {
  run su hermes -c "PATH=$STUB:\$PATH bash '$SCRIPTS/stabilize-google-workspace.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"google workspace token link is ready"* ]]
  [[ "$output" == *"disabled remote MCP google_drive"* ]]
  [[ "$output" == *"telegram gateway restarted"* ]]
  [ "$(cat /tmp/.gw-stabilize-link)" = "linked" ]
  grep -q 'google_drive' /tmp/.gw-stabilize-config
  [ "$(cat /tmp/.gw-stabilize-restart)" = "--restart" ]
}

@test "stabilize-google-workspace refuses to run before Workspace OAuth" {
  cat >"$STUB/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ps -a --format {{.Names}}") echo hermes ;;
  "inspect -f {{.State.Status}} hermes") echo running ;;
  "exec hermes sh -lc test -f /opt/data/google_token.json") exit 1 ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x "$STUB/docker"

  run su hermes -c "PATH=$STUB:\$PATH bash '$SCRIPTS/stabilize-google-workspace.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Google Workspace token is missing"* ]]
}
