# shellcheck shell=bash
# Interactive primitives + idempotent .env upsert.
# Requires log.sh and checks.sh (read_env_value) sourced beforehand.

# is_interactive -> 0 only when both stdin/stdout are TTYs and the caller has
# not forced non-interactive mode. assert_idempotent and the sandbox run with
# HERMES_NONINTERACTIVE=1, so prompts never fire there.
is_interactive() {
  [[ -t 0 && -t 1 && "${HERMES_NONINTERACTIVE:-}" != 1 ]]
}

# prompt_value PROMPT -> echoes a plain (visible) line of input.
prompt_value() {
  local p="$1" out
  read -r -p "$p: " out
  printf '%s' "$out"
}

# prompt_secret PROMPT -> echoes a hidden line of input (no terminal echo).
prompt_secret() {
  local p="$1" out
  read -rs -p "$p: " out
  echo >&2
  printf '%s' "$out"
}

# confirm PROMPT -> 0 on y/Y, 1 otherwise.
confirm() {
  local p="$1" a
  read -r -p "$p [y/N]: " a
  [[ "$a" =~ ^[Yy] ]]
}

# set_env_value FILE KEY VALUE
# Idempotent upsert of a KEY=VALUE line. If KEY already equals VALUE, the file
# is left untouched and the function returns 1 ("no change"). Otherwise the
# FIRST uncommented KEY= line is replaced (later duplicates are left as-is) or
# the pair is appended, and it returns 0. KEY and VALUE are passed via the
# environment (ENVIRON) so awk performs no escape processing — values with
# =, &, /, ?, backslashes are stored verbatim. The replacement is written to a
# temp file in the same directory and moved into place with an atomic rename so
# a crash mid-write cannot leave the secrets file truncated; perms are preserved
# (and a freshly created file is 0600).
set_env_value() {
  local file="$1" key="$2" value="$3"
  # Ensure the target exists with secure perms before we read/write secrets.
  [[ -f "$file" ]] || install -m 0600 /dev/null "$file"

  local current
  if current=$(read_env_value "$file" "$key" 2>/dev/null) && [[ "$current" == "$value" ]]; then
    return 1
  fi

  local tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  trap 'rm -f "${tmp:-}"' RETURN
  # Match the original file's mode on the replacement (mktemp starts at 0600).
  chmod --reference="$file" "$tmp" 2>/dev/null || true

  SEV_K="$key" SEV_V="$value" awk '
    BEGIN { k = ENVIRON["SEV_K"]; v = ENVIRON["SEV_V"]; done = 0 }
    {
      line = $0
      probe = line; sub(/^[[:space:]]+/, "", probe)
      if (!done && probe !~ /^#/) {
        eq = index(line, "=")
        if (eq > 0) {
          lhs = substr(line, 1, eq-1)
          sub(/^[[:space:]]+/, "", lhs); sub(/[[:space:]]+$/, "", lhs)
          if (lhs == k) { print k "=" v; done = 1; next }
        }
      }
      print line
    }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"

  mv -f "$tmp" "$file"   # atomic rename within the same directory
  trap - RETURN
  return 0
}
