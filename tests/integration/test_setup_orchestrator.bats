#!/usr/bin/env bats

load '../helpers/setup_suite'

@test "setup.sh rejects unknown arguments before doing work" {
  run bash "$SCRIPTS/setup.sh" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument: --bogus"* ]]
}

@test "setup.sh runs hermes, mcp, and gateway setup in non-interactive mode" {
  local tmp
  tmp=/tmp/setup-orchestrator
  rm -rf "$tmp"
  mkdir -p "$tmp/scripts" "$tmp/config"
  cp "$SCRIPTS/setup.sh" "$tmp/scripts/setup.sh"
  cp -r "$SCRIPTS/lib" "$tmp/scripts/lib"
  cp "$REPO_ROOT/config/mcp.toml.example" "$tmp/config/mcp.toml"
  cp "$REPO_ROOT/config/.env.example" "$tmp/config/.env"
  cp "$REPO_ROOT/config/gateways.toml.example" "$tmp/config/gateways.toml"

  for s in setup-hermes.sh setup-mcp.sh setup-gateway.sh; do
    cat >"$tmp/scripts/$s" <<STUB
#!/usr/bin/env bash
echo "[OK] $s ran"
STUB
    chmod +x "$tmp/scripts/$s"
  done

  run bash "$tmp/scripts/setup.sh" --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup-hermes.sh ran"* ]]
  [[ "$output" == *"setup-mcp.sh ran"* ]]
  [[ "$output" == *"setup-gateway.sh ran"* ]]
  [[ "$output" == *"setup complete"* ]]
  [[ "$output" != *"OAuth login required"* ]]

  rm -rf "$tmp"
}

@test "root setup.sh delegates to scripts/setup.sh" {
  run bash -n "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
}
