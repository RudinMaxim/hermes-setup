#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
  # shellcheck source=/dev/null
  source "$LIB/checks.sh"
  # shellcheck source=/dev/null
  source "$LIB/prompt.sh"
  TMPDIR_T="$(mktemp -d)"
  ENVF="$TMPDIR_T/.env"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "set_env_value appends a new key" {
  echo "EXISTING=1" > "$ENVF"
  run set_env_value "$ENVF" NEWKEY hello
  [ "$status" -eq 0 ]
  run read_env_value "$ENVF" NEWKEY
  [ "$output" = "hello" ]
}

@test "set_env_value replaces an existing key" {
  printf 'FOO=old\nBAR=keep\n' > "$ENVF"
  run set_env_value "$ENVF" FOO new
  [ "$status" -eq 0 ]
  run read_env_value "$ENVF" FOO
  [ "$output" = "new" ]
  run read_env_value "$ENVF" BAR
  [ "$output" = "keep" ]
}

@test "set_env_value is safe under nounset" {
  printf 'FOO=old\n' > "$ENVF"
  run bash -u -c 'source "$1/log.sh"; source "$1/checks.sh"; source "$1/prompt.sh"; set_env_value "$2" FOO new; read_env_value "$2" FOO' _ "$LIB" "$ENVF"
  [ "$status" -eq 0 ]
  [ "$output" = "new" ]
}

@test "set_env_value returns 1 and does not rewrite when value unchanged" {
  echo "FOO=same" > "$ENVF"
  local before; before=$(cat "$ENVF")
  run set_env_value "$ENVF" FOO same
  [ "$status" -eq 1 ]
  [ "$(cat "$ENVF")" = "$before" ]
}

@test "set_env_value preserves special characters in the value verbatim" {
  : > "$ENVF"
  run set_env_value "$ENVF" POSTGRES_URL 'postgresql://u:p@h:5432/db?x=1&y=2'
  [ "$status" -eq 0 ]
  run read_env_value "$ENVF" POSTGRES_URL
  [ "$output" = 'postgresql://u:p@h:5432/db?x=1&y=2' ]
}

@test "set_env_value does not match a commented key (appends instead)" {
  printf '# FOO=commented\n' > "$ENVF"
  run set_env_value "$ENVF" FOO real
  [ "$status" -eq 0 ]
  run read_env_value "$ENVF" FOO
  [ "$output" = "real" ]
  grep -q '^# FOO=commented$' "$ENVF"
}

@test "set_env_value handles a file with no trailing newline" {
  printf 'FOO=old' > "$ENVF"   # no trailing newline
  run set_env_value "$ENVF" BAR added
  [ "$status" -eq 0 ]
  run read_env_value "$ENVF" FOO
  [ "$output" = "old" ]
  run read_env_value "$ENVF" BAR
  [ "$output" = "added" ]
}

@test "set_env_value replaces only the first occurrence of a duplicated key" {
  printf 'FOO=first\nFOO=second\n' > "$ENVF"
  run set_env_value "$ENVF" FOO updated
  [ "$status" -eq 0 ]
  # first line replaced, second left untouched
  [ "$(grep -c '^FOO=' "$ENVF")" -eq 2 ]
  grep -q '^FOO=updated$' "$ENVF"
  grep -q '^FOO=second$' "$ENVF"
}

@test "set_env_value creates a missing file with 0600 perms" {
  local f="$TMPDIR_T/new.env"
  run set_env_value "$f" KEY val
  [ "$status" -eq 0 ]
  # 0600 => owner rw only. Accept that some filesystems (e.g. Windows) cannot
  # represent this; skip the perms assertion there but still require the value.
  run read_env_value "$f" KEY
  [ "$output" = "val" ]
  local mode; mode=$(stat -c '%a' "$f" 2>/dev/null || echo "")
  if [ -n "$mode" ] && [ "$mode" != "600" ]; then
    # Only fail on a real POSIX fs that reports a non-600 mode.
    case "$(uname -s)" in
      Linux|Darwin) echo "expected 600, got $mode"; false ;;
      *) skip "filesystem does not enforce POSIX perms ($mode)" ;;
    esac
  fi
}

@test "is_interactive is false when HERMES_NONINTERACTIVE=1" {
  HERMES_NONINTERACTIVE=1 run is_interactive
  [ "$status" -eq 1 ]
}

@test "prompt_value echoes the entered line" {
  run bash -c 'source '"$LIB"'/log.sh; source '"$LIB"'/checks.sh; source '"$LIB"'/prompt.sh; printf "myvalue\n" | { prompt_value "x"; }'
  [ "$status" -eq 0 ]
  [ "$output" = "myvalue" ]
}

@test "confirm returns 0 on y and 1 on n" {
  run bash -c 'source '"$LIB"'/prompt.sh; printf "y\n" | confirm "ok"'
  [ "$status" -eq 0 ]
  run bash -c 'source '"$LIB"'/prompt.sh; printf "n\n" | confirm "ok"'
  [ "$status" -eq 1 ]
}
