#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
  # shellcheck source=/dev/null
  source "$LIB/write_file.sh"
  TMPDIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "write_file_idempotent creates file with mode 0644" {
  local target="$TMPDIR/out.conf"
  run write_file_idempotent "$target" "hello"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [[ "$(cat "$target")" == "hello" ]]
  [[ "$(stat -c '%a' "$target")" == "644" ]]
}

@test "write_file_idempotent skips when content matches" {
  local target="$TMPDIR/out.conf"
  write_file_idempotent "$target" "hello"
  local mtime1; mtime1=$(stat -c '%Y' "$target")
  sleep 1
  run write_file_idempotent "$target" "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SKIP]"* ]]
  local mtime2; mtime2=$(stat -c '%Y' "$target")
  [[ "$mtime1" == "$mtime2" ]]
}

@test "write_file_idempotent overwrites when content differs" {
  local target="$TMPDIR/out.conf"
  write_file_idempotent "$target" "hello"
  run write_file_idempotent "$target" "goodbye"
  [ "$status" -eq 0 ]
  [[ "$(cat "$target")" == "goodbye" ]]
}

@test "write_file_idempotent honors custom mode" {
  # Probe: only run this assertion on filesystems where chmod actually sticks.
  # On Windows Git Bash with NTFS, permission bits are emulated and 0600 ends
  # up reported as 0644. The integration suite (Linux sandbox) is authoritative.
  local probe="$TMPDIR/probe"
  : >"$probe"
  chmod 0600 "$probe"
  [[ "$(stat -c '%a' "$probe")" == "600" ]] || skip "filesystem permission bits not enforced (non-Linux host?)"

  local target="$TMPDIR/secret.conf"
  run write_file_idempotent "$target" "secret-content" 0600
  [ "$status" -eq 0 ]
  [[ "$(stat -c '%a' "$target")" == "600" ]]
}
