# shellcheck shell=bash
# Telegram-specific pure helpers (unit-testable, no network).

# telegram_getme_username '<getMe-json>' -> prints the bot username and exits 0
# only when the response has "ok":true AND a non-empty "username" field;
# exits 1 otherwise (so callers can use `u=$(...) || die`).
telegram_getme_username() {
  local json="$1"
  grep -q '"ok":[[:space:]]*true' <<<"$json" || return 1
  local uname
  uname=$(sed -n 's/.*"username":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json")
  [[ -n "$uname" ]] || return 1
  printf '%s\n' "$uname"
}
