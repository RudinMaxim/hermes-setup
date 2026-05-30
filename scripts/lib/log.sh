# shellcheck shell=bash

log_ok()   { printf '[OK] %s\n' "$*"; }
log_skip() { printf '[SKIP] %s\n' "$*"; }
log_act()  { printf '[ACT] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }

die() {
  local msg="$1"
  local code="${2:-1}"
  printf '[ERR] %s\n' "$msg" >&2
  exit "$code"
}
