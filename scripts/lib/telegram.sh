# shellcheck shell=bash
# Telegram-specific pure helpers (unit-testable, no network).

# telegram_getme_username '<getMe-json>' -> prints the bot username and exits 0
# when the response has "ok":true; exits 1 otherwise.
telegram_getme_username() {
  local json="$1"
  grep -q '"ok":[[:space:]]*true' <<<"$json" || return 1
  sed -n 's/.*"username":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json"
}
