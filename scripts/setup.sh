#!/usr/bin/env bash
# scripts/setup.sh — One-command Hermes host setup for the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
ENVFILE="$CONFIG_DIR/.env"
MCP_TOML="$CONFIG_DIR/mcp.toml"
GATEWAYS_TOML="$CONFIG_DIR/gateways.toml"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"

PASSTHRU=()
SKIP_GOOGLE_DRIVE_LOGIN=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive)
      export HERMES_NONINTERACTIVE=1
      PASSTHRU+=("$arg")
      ;;
    --skip-google-drive-login)
      SKIP_GOOGLE_DRIVE_LOGIN=1
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

confirm_yes() {
  local p="$1" a
  read -r -p "$p [Y/n]: " a
  [[ ! "$a" =~ ^[Nn] ]]
}

set_toml_value() {
  local file="$1" section="$2" key="$3" value="$4"
  local tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  trap 'rm -f "${tmp:-}"' RETURN

  STV_SECTION="$section" STV_KEY="$key" STV_VALUE="$value" awk '
    BEGIN {
      section = ENVIRON["STV_SECTION"]
      key = ENVIRON["STV_KEY"]
      value = ENVIRON["STV_VALUE"]
      in_section = 0
      wrote = 0
      found_section = 0
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_section && !wrote) {
        print key " = " value
        wrote = 1
      }
      cur = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
      in_section = (cur == section)
      if (in_section) {
        found_section = 1
      }
      print
      next
    }
    {
      if (in_section && $0 ~ /^[[:space:]]*[^#[:space:]][^=]*=/) {
        lhs = $0
        sub(/=.*/, "", lhs)
        gsub(/[[:space:]]/, "", lhs)
        if (lhs == key) {
          print key " = " value
          wrote = 1
          next
        }
      }
      print
    }
    END {
      if (found_section && in_section && !wrote) {
        print key " = " value
      }
      if (!found_section) {
        print ""
        print "[" section "]"
        print key " = " value
      }
    }
  ' "$file" >"$tmp"

  mv -f "$tmp" "$file"
  trap - RETURN
}

google_drive_enabled() {
  [[ -f "$MCP_TOML" ]] && toml_get_bool "$MCP_TOML" google_drive enabled
}

google_drive_creds_present() {
  env_var_set_in_file "$ENVFILE" GOOGLE_DRIVE_OAUTH_CLIENT_ID \
    && env_var_set_in_file "$ENVFILE" GOOGLE_DRIVE_OAUTH_CLIENT_SECRET
}

maybe_configure_google_drive() {
  [[ -f "$MCP_TOML" && -f "$ENVFILE" ]] || return 0

  if ! google_drive_enabled; then
    if ! is_interactive; then
      return 0
    fi
    if confirm "Configure Google Drive MCP now?"; then
      set_toml_value "$MCP_TOML" google_drive enabled true
      log_ok "mcp.google_drive enabled in config/mcp.toml"
    else
      return 0
    fi
  fi

  if ! is_interactive; then
    return 0
  fi

  if ! env_var_set_in_file "$ENVFILE" GOOGLE_DRIVE_OAUTH_CLIENT_ID; then
    local client_id
    client_id=$(prompt_value "Google Drive OAuth Client ID")
    [[ -n "$client_id" ]] || die "empty Google Drive OAuth Client ID"
    set_env_value "$ENVFILE" GOOGLE_DRIVE_OAUTH_CLIENT_ID "$client_id" >/dev/null || true
    log_ok "GOOGLE_DRIVE_OAUTH_CLIENT_ID saved to .env"
  fi

  if ! env_var_set_in_file "$ENVFILE" GOOGLE_DRIVE_OAUTH_CLIENT_SECRET; then
    local client_secret
    client_secret=$(prompt_secret "Google Drive OAuth Client Secret")
    [[ -n "$client_secret" ]] || die "empty Google Drive OAuth Client Secret"
    set_env_value "$ENVFILE" GOOGLE_DRIVE_OAUTH_CLIENT_SECRET "$client_secret" >/dev/null || true
    log_ok "GOOGLE_DRIVE_OAUTH_CLIENT_SECRET saved to .env (${#client_secret} chars)"
  fi
}

google_drive_oauth_login() {
  if (( SKIP_GOOGLE_DRIVE_LOGIN )); then
    log_skip "Google Drive OAuth login skipped by --skip-google-drive-login"
    return 0
  fi
  if ! google_drive_enabled || ! google_drive_creds_present; then
    return 0
  fi
  if ! is_interactive; then
    log_warn "mcp.google_drive: OAuth login skipped in non-interactive mode"
    return 0
  fi
  if ! confirm_yes "Complete Google Drive OAuth login now?"; then
    log_warn "mcp.google_drive: OAuth login skipped — run './setup.sh' again later"
    return 0
  fi

  log_act "starting Google Drive OAuth login"
  log_warn "When Hermes prints an authorization URL, open it in your browser."
  log_warn "After Google redirects to 127.0.0.1, paste the full callback URL here."

  coproc GDRIVE_OAUTH { docker exec -i hermes hermes mcp login google_drive 2>&1; }
  local out_fd="${GDRIVE_OAUTH[0]}" in_fd="${GDRIVE_OAUTH[1]}" pid="$GDRIVE_OAUTH_PID"
  local line ready_for_callback=0 i callback rc

  for i in $(seq 1 60); do
    while IFS= read -r -t 0.2 line <&"$out_fd"; do
      printf '%s\n' "$line"
      if [[ "$line" =~ https?://|callback|redirect|Redirect|Paste|Enter ]]; then
        ready_for_callback=1
      fi
    done
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    (( ready_for_callback )) && break
    sleep 1
  done

  if ! kill -0 "$pid" 2>/dev/null; then
    set +e
    wait "$pid"
    rc=$?
    set -e
    if (( rc == 0 )); then
      log_ok "mcp.google_drive: OAuth login completed"
    else
      log_warn "mcp.google_drive: OAuth login exited before callback input (rc=$rc)"
    fi
    eval "exec ${out_fd}<&-"
    eval "exec ${in_fd}>&-"
    return 0
  fi

  if (( ! ready_for_callback )); then
    log_warn "mcp.google_drive: authorization URL was not detected yet; paste callback only after Google authorization finishes"
  fi

  callback=$(prompt_value "Paste full Google callback URL (blank to skip)")
  if [[ -z "$callback" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    eval "exec ${out_fd}<&-"
    eval "exec ${in_fd}>&-"
    log_warn "mcp.google_drive: OAuth login skipped"
    return 0
  fi

  printf '%s\n' "$callback" >&"$in_fd"
  eval "exec ${in_fd}>&-"

  set +e
  while IFS= read -r -t 1 line <&"$out_fd"; do
    printf '%s\n' "$line"
  done
  wait "$pid"
  rc=$?
  set -e
  eval "exec ${out_fd}<&-"

  case "$rc" in
    0)
      log_ok "mcp.google_drive: OAuth login completed"
      ;;
    *)
      log_warn "mcp.google_drive: OAuth login did not complete (rc=$rc)"
      log_warn "retry by running './setup.sh' again, or inspect: docker exec hermes hermes mcp login google_drive"
      return 0
      ;;
  esac

  if docker exec hermes hermes mcp test google_drive >/dev/null 2>&1; then
    log_ok "mcp.google_drive: smoke-test passed"
  else
    log_warn "mcp.google_drive: smoke-test did not pass; test manually with 'docker exec hermes hermes mcp test google_drive'"
  fi
}

main() {
  [[ $EUID -ne 0 ]] \
    || log_warn "setup.sh is the hermes-side orchestrator — run setup-server.sh as root separately, then re-run this as the 'hermes' user"

  log_act "setting up Hermes"
  bash "$SCRIPT_DIR/setup-hermes.sh" "${PASSTHRU[@]}"

  maybe_configure_google_drive

  log_act "setting up MCP servers"
  bash "$SCRIPT_DIR/setup-mcp.sh" "${PASSTHRU[@]}"

  google_drive_oauth_login

  if [[ -f "$GATEWAYS_TOML" ]]; then
    log_act "setting up gateways"
    bash "$SCRIPT_DIR/setup-gateway.sh" "${PASSTHRU[@]}"
  fi

  log_ok "setup complete"
}

main "$@"
