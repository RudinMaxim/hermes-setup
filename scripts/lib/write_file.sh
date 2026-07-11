# shellcheck shell=bash
# Requires log.sh sourced beforehand.

write_file_idempotent() {
  local target="$1"
  local content="$2"
  local mode="${3:-0644}"
  local tmp
  tmp=$(mktemp)
  # Always terminate with a newline. Callers build $content via $(cat <<EOF ...),
  # which strips the trailing newline — without this, files like /etc/sudoers.d/hermes
  # end mid-line and `visudo -cf` rejects them ("missing line terminator").
  printf '%s\n' "$content" >"$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log_skip "file $target already up-to-date"
    return 0
  fi
  install -m "$mode" "$tmp" "$target"
  rm -f "$tmp"
  log_ok "wrote $target"
}
