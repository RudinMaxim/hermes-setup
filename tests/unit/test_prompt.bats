#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
  # shellcheck source=/dev/null
  source "$LIB/checks.sh"
  # shellcheck source=/dev/null
  source "$LIB/prompt.sh"
}

@test "set_env_value appends a new key" {
  local tmp; tmp=$(mktemp)
  echo "EXISTING=1" > "$tmp"
  run set_env_value "$tmp" NEWKEY hello
  [ "$status" -eq 0 ]
  run read_env_value "$tmp" NEWKEY
  [ "$output" = "hello" ]
  rm -f "$tmp"
}

@test "set_env_value replaces an existing key" {
  local tmp; tmp=$(mktemp)
  printf 'FOO=old\nBAR=keep\n' > "$tmp"
  run set_env_value "$tmp" FOO new
  [ "$status" -eq 0 ]
  run read_env_value "$tmp" FOO
  [ "$output" = "new" ]
  run read_env_value "$tmp" BAR
  [ "$output" = "keep" ]
  rm -f "$tmp"
}

@test "set_env_value returns 1 and does not rewrite when value unchanged" {
  local tmp; tmp=$(mktemp)
  echo "FOO=same" > "$tmp"
  local before; before=$(cat "$tmp")
  run set_env_value "$tmp" FOO same
  [ "$status" -eq 1 ]
  [ "$(cat "$tmp")" = "$before" ]
  rm -f "$tmp"
}

@test "set_env_value preserves special characters in the value verbatim" {
  local tmp; tmp=$(mktemp)
  : > "$tmp"
  set_env_value "$tmp" POSTGRES_URL 'postgresql://u:p@h:5432/db?x=1&y=2'
  run read_env_value "$tmp" POSTGRES_URL
  [ "$output" = 'postgresql://u:p@h:5432/db?x=1&y=2' ]
  rm -f "$tmp"
}

@test "set_env_value does not match a commented key (appends instead)" {
  local tmp; tmp=$(mktemp)
  printf '# FOO=commented\n' > "$tmp"
  run set_env_value "$tmp" FOO real
  [ "$status" -eq 0 ]
  run read_env_value "$tmp" FOO
  [ "$output" = "real" ]
  grep -q '^# FOO=commented$' "$tmp"
  rm -f "$tmp"
}

@test "is_interactive is false when HERMES_NONINTERACTIVE=1" {
  HERMES_NONINTERACTIVE=1 run is_interactive
  [ "$status" -eq 1 ]
}
