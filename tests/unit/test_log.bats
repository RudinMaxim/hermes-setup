#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
}

@test "log_ok prefixes with [OK]" {
  run log_ok "user created"
  [ "$status" -eq 0 ]
  [[ "$output" == "[OK] user created" ]]
}

@test "log_skip prefixes with [SKIP]" {
  run log_skip "already exists"
  [ "$status" -eq 0 ]
  [[ "$output" == "[SKIP] already exists" ]]
}

@test "log_act prefixes with [ACT]" {
  run log_act "creating user"
  [ "$status" -eq 0 ]
  [[ "$output" == "[ACT] creating user" ]]
}

@test "log_warn prefixes with [WARN] and goes to stderr" {
  run bash -c "source '$LIB/log.sh'; log_warn 'be careful' 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == "[WARN] be careful" ]]
}

@test "die prints [ERR] to stderr and exits 1" {
  run bash -c "source '$LIB/log.sh'; die 'fatal'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERR] fatal"* ]]
}

@test "die accepts custom exit code" {
  run bash -c "source '$LIB/log.sh'; die 'fatal' 42"
  [ "$status" -eq 42 ]
}
