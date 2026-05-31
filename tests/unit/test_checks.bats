#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/checks.sh"
}

@test "has_command returns 0 for existing command" {
  run has_command bash
  [ "$status" -eq 0 ]
}

@test "has_command returns 1 for missing command" {
  run has_command definitely-not-a-real-command-xyz
  [ "$status" -eq 1 ]
}

@test "has_user returns 0 for the current user" {
  run has_user "$(id -un)"
  [ "$status" -eq 0 ]
}

@test "has_user returns 1 for missing user" {
  run has_user no-such-user-xyz
  [ "$status" -eq 1 ]
}

@test "user_in_group returns 1 when user not in group" {
  run user_in_group "$(id -un)" no-such-group-xyz-12345
  [ "$status" -eq 1 ]
}

@test "env_var_set_in_file returns 0 when KEY has value" {
  local tmp; tmp=$(mktemp)
  echo "FOO=bar" > "$tmp"
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file returns 1 when KEY empty" {
  local tmp; tmp=$(mktemp)
  echo "FOO=" > "$tmp"
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file returns 1 when KEY absent" {
  local tmp; tmp=$(mktemp)
  echo "BAR=baz" > "$tmp"
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file ignores comments and surrounding whitespace" {
  local tmp; tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
# FOO=commented_out
   FOO=actual
EOF
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file is not vulnerable to regex injection in the key" {
  local tmp; tmp=$(mktemp)
  echo "OTHER=value" > "$tmp"
  # A key like 'FOO|OTHER' must NOT match the OTHER line — historically a
  # naive grep -E "${key}=..." would interpret | as alternation.
  run env_var_set_in_file "$tmp" 'FOO|OTHER'
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}

@test "is_numeric_csv accepts a single numeric id" {
  run is_numeric_csv "123"
  [ "$status" -eq 0 ]
}

@test "is_numeric_csv accepts comma-separated numeric ids" {
  run is_numeric_csv "123,456,789"
  [ "$status" -eq 0 ]
}

@test "is_numeric_csv rejects non-numeric content" {
  run is_numeric_csv "123,abc"
  [ "$status" -eq 1 ]
}

@test "is_numeric_csv rejects empty string" {
  run is_numeric_csv ""
  [ "$status" -eq 1 ]
}

@test "is_numeric_csv rejects trailing comma" {
  run is_numeric_csv "12,"
  [ "$status" -eq 1 ]
}

@test "read_env_value prints the value for a key" {
  local tmp; tmp=$(mktemp)
  echo "FOO=bar" > "$tmp"
  run read_env_value "$tmp" FOO
  [ "$status" -eq 0 ]
  [ "$output" = "bar" ]
  rm -f "$tmp"
}

@test "read_env_value ignores commented lines" {
  local tmp; tmp=$(mktemp)
  printf '# FOO=commented\nFOO=actual\n' > "$tmp"
  run read_env_value "$tmp" FOO
  [ "$status" -eq 0 ]
  [ "$output" = "actual" ]
  rm -f "$tmp"
}

@test "read_env_value exits 1 when key absent" {
  local tmp; tmp=$(mktemp)
  echo "BAR=baz" > "$tmp"
  run read_env_value "$tmp" FOO
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}
