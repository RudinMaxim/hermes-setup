#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/toml.sh"
  TMP=$(mktemp)
  cat >"$TMP" <<'EOF'
# comment
[github]
enabled = true
description = "репозитории, PR, issues"
transport = "stdio"
package = "@modelcontextprotocol/server-github"
requires = ["GITHUB_TOKEN"]

[playwright]
enabled = false
transport = "http"
port = 9001
requires = []
EOF
}

teardown() {
  rm -f "$TMP"
}

@test "toml_sections lists every [section]" {
  run toml_sections "$TMP"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "github" ]]
  [[ "${lines[1]}" == "playwright" ]]
}

@test "toml_get reads string value" {
  run toml_get "$TMP" github transport
  [ "$status" -eq 0 ]
  [[ "$output" == "stdio" ]]
}

@test "toml_get reads quoted string with special chars" {
  run toml_get "$TMP" github package
  [ "$status" -eq 0 ]
  [[ "$output" == "@modelcontextprotocol/server-github" ]]
}

@test "toml_get reads integer" {
  run toml_get "$TMP" playwright port
  [ "$status" -eq 0 ]
  [[ "$output" == "9001" ]]
}

@test "toml_get_bool returns 0 for true" {
  run toml_get_bool "$TMP" github enabled
  [ "$status" -eq 0 ]
}

@test "toml_get_bool returns 1 for false" {
  run toml_get_bool "$TMP" playwright enabled
  [ "$status" -eq 1 ]
}

@test "toml_get_bool returns 1 for missing key (default false)" {
  run toml_get_bool "$TMP" github missing_key
  [ "$status" -eq 1 ]
}

@test "toml_get_array prints list elements one per line" {
  run toml_get_array "$TMP" github requires
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "GITHUB_TOKEN" ]]
}

@test "toml_get_array prints nothing for empty array" {
  run toml_get_array "$TMP" playwright requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "toml_get returns non-zero when key absent" {
  run toml_get "$TMP" github nope
  [ "$status" -ne 0 ]
}
