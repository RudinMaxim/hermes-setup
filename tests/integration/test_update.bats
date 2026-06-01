#!/usr/bin/env bats

load '../helpers/setup_suite'

@test "update.sh rejects unknown arguments before doing any work" {
  run bash "$SCRIPTS/update.sh" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument: --bogus"* ]]
}

@test "update.sh re-syncs via the setup scripts and reports completion" {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  cp "$REPO_ROOT/config/mcp.toml.example" "$REPO_ROOT/config/mcp.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  chown -R hermes:hermes "$REPO_ROOT/config"

  mkdir -p /tmp/upd-stub
  # Stub the setup scripts update.sh delegates to, so we test the orchestration
  # (not their internals, which have their own tests). Stub docker for the npm
  # MCP update step.
  for s in setup-hermes.sh setup-mcp.sh setup-gateway.sh; do
    cat >"/tmp/upd-stub/$s" <<STUB
#!/usr/bin/env bash
echo "[OK] $s ran"
STUB
    chmod +x "/tmp/upd-stub/$s"
  done
  cat >/tmp/upd-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "inspect -f") echo running ;;
  *) exit 0 ;;
esac
STUB
  chmod +x /tmp/upd-stub/docker

  # Point update.sh at the stubbed setup scripts by shadowing SCRIPT_DIR via a
  # copy that lives next to the stubs.
  cp "$SCRIPTS/update.sh" /tmp/upd-stub/update.sh
  cp -r "$SCRIPTS/lib" /tmp/upd-stub/lib

  run su hermes -c "PATH=/tmp/upd-stub:\$PATH HERMES_NONINTERACTIVE=1 bash /tmp/upd-stub/update.sh --no-pull --no-pkg-update --non-interactive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup-hermes.sh ran"* ]]
  [[ "$output" == *"setup-mcp.sh ran"* ]]
  [[ "$output" == *"update complete"* ]]

  rm -rf /tmp/upd-stub
}
