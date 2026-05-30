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

@test "has_user returns 0 for existing user (root)" {
  run has_user root
  [ "$status" -eq 0 ]
}

@test "has_user returns 1 for missing user" {
  run has_user no-such-user-xyz
  [ "$status" -eq 1 ]
}

@test "user_in_group returns 1 when user not in group" {
  run user_in_group root nobody
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
