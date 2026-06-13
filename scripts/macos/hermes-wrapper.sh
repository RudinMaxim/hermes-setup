#!/usr/bin/env bash
# Managed Hermes wrapper for macOS reliability fixes.

set -uo pipefail

unset PYTHONPATH
unset PYTHONHOME

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
REAL_HERMES="${HERMES_REAL_BIN:-$HERMES_HOME/hermes-agent/venv/bin/hermes}"

[[ -x "$REAL_HERMES" ]] || {
  printf 'hermes wrapper: real binary not found: %s\n' "$REAL_HERMES" >&2
  exit 127
}

safe_server_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

restore_oauth_state() {
  local backup_dir=$1 token_dir=$2 server=$3
  local suffix marker source target

  for suffix in ".json" ".client.json" ".meta.json"; do
    marker="$backup_dir/had${suffix}"
    source="$backup_dir/state${suffix}"
    target="$token_dir/${server}${suffix}"
    if [[ -f "$marker" ]]; then
      mkdir -p "$token_dir"
      cp "$source" "$target"
      chmod 0600 "$target"
    else
      rm -f "$target"
    fi
  done
}

safe_oauth_login() {
  local server=${3:-}
  local force=0 arg token_dir token_file backup_dir output_file rc suffix

  safe_server_name "$server" || {
    printf 'hermes wrapper: invalid MCP server name: %s\n' "$server" >&2
    return 2
  }

  for arg in "${@:4}"; do
    [[ "$arg" == "--force" ]] && force=1
  done

  token_dir="$HERMES_HOME/mcp-tokens"
  token_file="$token_dir/$server.json"

  if (( ! force )) && [[ -f "$token_file" ]]; then
    printf '[INFO] Cached OAuth state found; verifying and refreshing it without deleting credentials.\n'
    "$REAL_HERMES" mcp test "$server"
    rc=$?
    if (( rc != 0 )); then
      printf '[WARN] OAuth verification failed. Retry transient errors first; use --force only for invalid_grant, needs_reauth, or an account/scope change.\n' >&2
    fi
    return "$rc"
  fi

  if (( ! force )); then
    exec "$REAL_HERMES" "$@"
  fi

  backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/hermes-oauth.XXXXXX")
  output_file="$backup_dir/output"
  trap 'rm -rf "$backup_dir"' RETURN

  for suffix in ".json" ".client.json" ".meta.json"; do
    if [[ -f "$token_dir/${server}${suffix}" ]]; then
      cp "$token_dir/${server}${suffix}" "$backup_dir/state${suffix}"
      : >"$backup_dir/had${suffix}"
    fi
  done

  set +e
  "$REAL_HERMES" "$@" 2>&1 | tee "$output_file"
  rc=${PIPESTATUS[0]}
  set -e

  if (( rc == 0 )) \
    && [[ -s "$token_file" ]] \
    && ! grep -Eqi 'authentication failed|no OAuth token was obtained|authorization did not complete' "$output_file"; then
    return 0
  fi

  restore_oauth_state "$backup_dir" "$token_dir" "$server"
  printf '[WARN] New OAuth authorization did not complete; previous credentials were restored.\n' >&2
  (( rc == 0 )) && rc=1
  return "$rc"
}

correct_gateway_status() {
  local output_file rc launchd_target
  output_file=$(mktemp "${TMPDIR:-/tmp}/hermes-gateway-status.XXXXXX")
  trap 'rm -f "$output_file"' RETURN

  set +e
  "$REAL_HERMES" "$@" >"$output_file" 2>&1
  rc=$?
  set -e

  launchd_target="gui/$(id -u)/ai.hermes.gateway"
  if grep -q 'Gateway service is not loaded' "$output_file" \
    && launchctl print "$launchd_target" >/dev/null 2>&1; then
    awk '
      /Gateway service is not loaded/ { skip = 2; next }
      skip > 0 { skip--; next }
      { print }
    ' "$output_file"
    printf '✓ Gateway service is loaded\n'
    launchctl print "$launchd_target"
    return 0
  fi

  cat "$output_file"
  return "$rc"
}

if [[ "${1:-}" == "mcp" && "${2:-}" == "login" ]]; then
  safe_oauth_login "$@"
  exit $?
fi

if [[ "$(uname -s)" == "Darwin" \
  && "${1:-}" == "gateway" && "${2:-}" == "status" ]]; then
  correct_gateway_status "$@"
  exit $?
fi

exec "$REAL_HERMES" "$@"
