#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  TEST_ROOT="$BATS_TEST_TMPDIR/hermes-wrapper"
  rm -rf "$TEST_ROOT"
  mkdir -p "$TEST_ROOT/home/.hermes/mcp-tokens" "$TEST_ROOT/bin"
  WRAPPER="$SCRIPTS/macos/hermes-wrapper.sh"
  REAL="$TEST_ROOT/bin/hermes-real"

  cat >"$REAL" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS_FILE"
case "$*" in
  "mcp test todoist") exit "${TEST_RESULT:-0}" ;;
  "mcp login todoist --force")
    rm -f "$HOME/.hermes/mcp-tokens/todoist.json"
    printf 'Authentication failed: timeout\n'
    exit 0
    ;;
  "mcp login success --force")
    printf '{"access_token":"new"}\n' >"$HOME/.hermes/mcp-tokens/success.json"
    printf 'Authenticated\n'
    exit 0
    ;;
  "gateway status")
    printf 'Launchd plist: test\n'
    printf '✗ Gateway service is not loaded\n'
    printf '  Service definition exists locally but launchd has not loaded it.\n'
    printf '  Run: hermes gateway start\n'
    exit 0
    ;;
esac
STUB
  chmod +x "$REAL"

  cat >"$TEST_ROOT/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf 'Darwin\n'
STUB
  cat >"$TEST_ROOT/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
printf 'gui/501/ai.hermes.gateway = {\n\tstate = running\n\tpid = 42\n}\n'
STUB
  cat >"$TEST_ROOT/bin/id" <<'STUB'
#!/usr/bin/env bash
printf '501\n'
STUB
  chmod +x "$TEST_ROOT/bin/uname" "$TEST_ROOT/bin/launchctl" "$TEST_ROOT/bin/id"

  export HOME="$TEST_ROOT/home"
  export HERMES_REAL_BIN="$REAL"
  export CALLS_FILE="$TEST_ROOT/calls"
  export PATH="$TEST_ROOT/bin:$PATH"
}

@test "cached OAuth login verifies without deleting credentials" {
  printf '{"access_token":"old"}\n' >"$HOME/.hermes/mcp-tokens/todoist.json"

  run "$WRAPPER" mcp login todoist

  [ "$status" -eq 0 ]
  grep -q '"old"' "$HOME/.hermes/mcp-tokens/todoist.json"
  grep -qx 'mcp test todoist' "$CALLS_FILE"
}

@test "forced OAuth failure restores previous credentials" {
  printf '{"access_token":"old"}\n' >"$HOME/.hermes/mcp-tokens/todoist.json"
  printf '{"client_id":"old"}\n' >"$HOME/.hermes/mcp-tokens/todoist.client.json"

  run "$WRAPPER" mcp login todoist --force

  [ "$status" -ne 0 ]
  grep -q '"old"' "$HOME/.hermes/mcp-tokens/todoist.json"
  grep -q '"old"' "$HOME/.hermes/mcp-tokens/todoist.client.json"
  [[ "$output" == *"previous credentials were restored"* ]]
}

@test "successful forced OAuth keeps new credentials" {
  printf '{"access_token":"old"}\n' >"$HOME/.hermes/mcp-tokens/success.json"

  run "$WRAPPER" mcp login success --force

  [ "$status" -eq 0 ]
  grep -q '"new"' "$HOME/.hermes/mcp-tokens/success.json"
}

@test "gateway status corrects legacy launchctl false negative" {
  run "$WRAPPER" gateway status

  [ "$status" -eq 0 ]
  [[ "$output" == *"Gateway service is loaded"* ]]
  [[ "$output" == *"state = running"* ]]
  [[ "$output" != *"Gateway service is not loaded"* ]]
}
