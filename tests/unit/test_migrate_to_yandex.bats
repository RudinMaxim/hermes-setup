#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  TEST_BIN="$TEST_ROOT/bin"
  mkdir -p "$TEST_HOME" "$TEST_BIN" "$TEST_ROOT/config" "$TEST_ROOT/scripts"
  printf 'OPENROUTER_API_KEY=legacy-key\nHERMES_MODEL_PROVIDER=openrouter\nHERMES_MODEL=legacy/model\n' > "$TEST_ROOT/config/.env"
  printf '[telegram]\nenabled = true\n' > "$TEST_ROOT/config/gateways.toml"

  cat > "$TEST_ROOT/scripts/setup-hermes.sh" <<'STUB'
#!/usr/bin/env bash
touch "$HERMES_MIGRATION_ROOT/setup-hermes.called"
STUB
  cat > "$TEST_ROOT/scripts/setup-gateway.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HERMES_MIGRATION_ROOT/setup-gateway.called"
STUB
  chmod +x "$TEST_ROOT/scripts/setup-hermes.sh" "$TEST_ROOT/scripts/setup-gateway.sh"

  cat > "$TEST_BIN/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "cp" && "$2" == "hermes:/opt/data/config.yaml" ]]; then
  printf 'model:\n  provider: openrouter\n' > "$3"
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  exit 0
fi
exit 0
STUB
  cat > "$TEST_BIN/curl" <<'STUB'
#!/usr/bin/env bash
[[ "${CURL_FAIL:-0}" == "1" ]] && exit 22
output=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" || "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
printf '{"choices":[{"message":{"content":"ok"}}]}' > "$output"
STUB
  chmod +x "$TEST_BIN/docker" "$TEST_BIN/curl"

  export HERMES_MIGRATION_ROOT="$TEST_ROOT"
  export HERMES_MIGRATION_ALLOW_ROOT=1
  export HOME="$TEST_HOME"
  export PATH="$TEST_BIN:$PATH"
  unset YANDEX_API_KEY YANDEX_FOLDER_ID HERMES_MODEL HERMES_NONINTERACTIVE
  SCRIPT="$SCRIPTS/migrate-to-yandex.sh"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "interactive migration stores Yandex values, creates backups, and restarts gateway" {
  run bash -c "printf 'test-secret-key\nb1gtestfolder\n\n' | bash '$SCRIPT'"

  if [ "$status" -ne 0 ]; then
    printf 'migration status=%s\n%s\n' "$status" "$output"
    false
  fi
  grep -qx 'YANDEX_API_KEY=test-secret-key' "$TEST_ROOT/config/.env"
  grep -qx 'YANDEX_FOLDER_ID=b1gtestfolder' "$TEST_ROOT/config/.env"
  grep -qx 'HERMES_MODEL_PROVIDER=custom:yandex' "$TEST_ROOT/config/.env"
  grep -qx 'HERMES_MODEL=gpt://b1gtestfolder/aliceai-llm' "$TEST_ROOT/config/.env"
  grep -qx 'HERMES_STT_PROVIDER=yandex' "$TEST_ROOT/config/.env"
  [ -f "$TEST_ROOT/setup-hermes.called" ]
  grep -qx -- '--restart' "$TEST_ROOT/setup-gateway.called"
  [ "$(find "$TEST_HOME/.hermes-yandex-migration-backups" -name config.env -type f | wc -l)" -eq 1 ]
  [ "$(find "$TEST_HOME/.hermes-yandex-migration-backups" -name config.yaml -type f | wc -l)" -eq 1 ]
  [[ "$output" != *"test-secret-key"* ]]
  [[ "$output" == *"Migration complete"* ]]
}

@test "non-interactive migration fails before changes when credentials are absent" {
  before="$(cat "$TEST_ROOT/config/.env")"

  run env HERMES_NONINTERACTIVE=1 bash "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"YANDEX_API_KEY"* ]]
  [ "$(cat "$TEST_ROOT/config/.env")" = "$before" ]
  [ ! -e "$TEST_ROOT/setup-hermes.called" ]
}

@test "failed Yandex API validation leaves configuration unchanged" {
  before="$(cat "$TEST_ROOT/config/.env")"

  run env CURL_FAIL=1 YANDEX_API_KEY=test-secret-key YANDEX_FOLDER_ID=b1gtestfolder bash "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"YandexGPT API validation failed"* ]]
  [[ "$output" != *"test-secret-key"* ]]
  [ "$(cat "$TEST_ROOT/config/.env")" = "$before" ]
  [ ! -e "$TEST_ROOT/setup-hermes.called" ]
}
