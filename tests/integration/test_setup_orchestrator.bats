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

@test "setup.sh enables Google Drive MCP when the user opts in" {
  local tmp
  tmp=/tmp/setup-orchestrator-gdrive
  rm -rf "$tmp"
  mkdir -p "$tmp/scripts" "$tmp/config"
  cp "$SCRIPTS/setup.sh" "$tmp/scripts/setup.sh"
  cp -r "$SCRIPTS/lib" "$tmp/scripts/lib"
  cp "$REPO_ROOT/config/mcp.toml.example" "$tmp/config/mcp.toml"
  cp "$REPO_ROOT/config/.env.example" "$tmp/config/.env"
  cp "$REPO_ROOT/config/gateways.toml.example" "$tmp/config/gateways.toml"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$tmp/config/.env"
  sed -i 's|^GOOGLE_DRIVE_OAUTH_CLIENT_ID=|GOOGLE_DRIVE_OAUTH_CLIENT_ID=client-id|' "$tmp/config/.env"
  sed -i 's|^GOOGLE_DRIVE_OAUTH_CLIENT_SECRET=|GOOGLE_DRIVE_OAUTH_CLIENT_SECRET=client-secret|' "$tmp/config/.env"

  for s in setup-hermes.sh setup-mcp.sh setup-gateway.sh; do
    cat >"$tmp/scripts/$s" <<STUB
#!/usr/bin/env bash
echo "[OK] $s ran"
STUB
    chmod +x "$tmp/scripts/$s"
  done

  run env HERMES_ASSUME_YES=1 bash "$tmp/scripts/setup.sh" --skip-google-drive-login
  [ "$status" -eq 0 ]
  sed -n '/^\[google_drive\]/,/^\[/p' "$tmp/config/mcp.toml" | grep -q '^enabled = true$'
  [[ "$output" == *"mcp.google_drive enabled in config/mcp.toml"* ]]
  [[ "$output" == *"setup-mcp.sh ran"* ]]
  [[ "$output" == *"Google Drive OAuth login skipped by --skip-google-drive-login"* ]]

  rm -rf "$tmp"
}

@test "root setup.sh delegates to scripts/setup.sh" {
  run bash -n "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
}

@test "setup.sh triggers Google Drive OAuth through the agent, not mcp login" {
  grep -q 'google_drive MCP' "$SCRIPTS/setup.sh"
  grep -q 'hermes -z "$oauth_prompt" chat' "$SCRIPTS/setup.sh"
  ! grep -q 'hermes mcp login google_drive' "$SCRIPTS/setup.sh"
}
