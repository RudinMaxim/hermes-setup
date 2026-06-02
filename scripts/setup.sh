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
  if [[ "${HERMES_ASSUME_YES:-}" == 1 ]]; then
    printf '%s [Y/n]: y\n' "$p"
    return 0
  fi
  read -r -p "$p [Y/n]: " a
  [[ ! "$a" =~ ^[Nn] ]]
}

confirm_optional() {
  local p="$1"
  if [[ "${HERMES_ASSUME_YES:-}" == 1 ]]; then
    printf '%s [y/N]: y\n' "$p"
    return 0
  fi
  confirm "$p"
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
    if ! is_interactive && [[ "${HERMES_ASSUME_YES:-}" != 1 ]]; then
      return 0
    fi
    if confirm_optional "Configure Google Drive MCP now?"; then
      set_toml_value "$MCP_TOML" google_drive enabled true
      google_drive_enabled || die "could not enable mcp.google_drive in config/mcp.toml"
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

  log_act "triggering Google Drive OAuth through Hermes agent"
  log_warn "Hermes 'mcp login' does not complete Google Drive auth reliably, so setup asks the agent to use Google Drive MCP."
  log_warn "When Hermes prints an authorization URL, open it in your browser."
  log_warn "After Google redirects to 127.0.0.1, paste the full callback URL here."

  local fifo log_file line ready_for_callback=0 i callback rc pid fifo_fd printed_lines=0 total_lines
  local oauth_prompt
  oauth_prompt='Use the google_drive MCP now. Search my Google Drive for files named "test". This request is only to trigger Google OAuth authorization during setup. If authorization is required, print the authorization URL and wait for the callback URL.'
  fifo=$(mktemp -u)
  log_file=$(mktemp)
  mkfifo "$fifo"
  exec {fifo_fd}<>"$fifo"

  docker exec -i hermes hermes -z "$oauth_prompt" chat <"$fifo" >"$log_file" 2>&1 &
  pid=$!

  for i in $(seq 1 60); do
    while IFS= read -r line; do
      if [[ "$line" =~ accounts\.google\.com|127\.0\.0\.1|Paste|Enter|redirect[[:space:]]+URL|callback[[:space:]]+URL ]]; then
        ready_for_callback=1
      fi
    done <"$log_file"
    total_lines=$(wc -l <"$log_file" 2>/dev/null || printf '0')
    if (( total_lines > printed_lines )); then
      sed -n "$((printed_lines + 1)),${total_lines}p" "$log_file"
      printed_lines="$total_lines"
    fi
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
    exec {fifo_fd}>&-
    rm -f "$fifo" "$log_file"
    log_warn "mcp.google_drive: agent OAuth trigger exited before callback input (rc=$rc)"
    log_warn "try manually: docker exec -it hermes hermes chat"
    log_warn "then ask: Use Google Drive MCP and search my Drive for files named test."
    return 0
  fi

  if (( ! ready_for_callback )); then
    log_warn "mcp.google_drive: authorization URL was not detected yet; paste callback only after Google authorization finishes"
  fi

  callback=$(prompt_value "Paste full Google callback URL (blank to skip)")
  if [[ -z "$callback" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exec {fifo_fd}>&-
    rm -f "$fifo" "$log_file"
    log_warn "mcp.google_drive: OAuth login skipped"
    return 0
  fi

  printf '%s\n' "$callback" >&"$fifo_fd"
  exec {fifo_fd}>&-
  rm -f "$fifo"

  set +e
  wait "$pid"
  rc=$?
  set -e
  total_lines=$(wc -l <"$log_file" 2>/dev/null || printf '0')
  if (( total_lines > printed_lines )); then
    sed -n "$((printed_lines + 1)),${total_lines}p" "$log_file"
  fi
  rm -f "$log_file"

  case "$rc" in
    0)
      log_ok "mcp.google_drive: OAuth login completed"
      ;;
    *)
      log_warn "mcp.google_drive: OAuth login did not complete (rc=$rc)"
      log_warn "retry by running './setup.sh' again, or use: docker exec -it hermes hermes chat"
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
