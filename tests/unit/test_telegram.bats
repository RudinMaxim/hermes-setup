#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/telegram.sh"
}

@test "telegram_getme_username extracts username on ok:true" {
  run telegram_getme_username '{"ok":true,"result":{"id":42,"username":"my_bot"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "my_bot" ]
}

@test "telegram_getme_username handles a space after the colon" {
  run telegram_getme_username '{"ok": true,"result":{"username":"spaced_bot"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "spaced_bot" ]
}

@test "telegram_getme_username fails on ok:false" {
  run telegram_getme_username '{"ok":false,"error_code":401,"description":"Unauthorized"}'
  [ "$status" -eq 1 ]
}

@test "telegram_getme_username fails on garbage" {
  run telegram_getme_username 'not json at all'
  [ "$status" -eq 1 ]
}
