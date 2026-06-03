#!/usr/bin/env bash
# scripts/setup-skills.sh - Idempotently sync Hermes skills based on config/skills.toml.
# Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
TOML="$CONFIG_DIR/skills.toml"
TOML_EXAMPLE="$CONFIG_DIR/skills.toml.example"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_hermes_running() {
  if ! docker_container_running hermes; then
    die "hermes container is not running - run scripts/setup-hermes.sh first"
  fi
}

require_example() {
  [[ -f "$TOML_EXAMPLE" ]] || die "missing $TOML_EXAMPLE"
}

ensure_config() {
  if [[ -f "$TOML" ]]; then
    return 0
  fi
  cp "$TOML_EXAMPLE" "$TOML"
  log_ok "created config/skills.toml from example"
}

sync_missing_example_sections() {
  local section
  for section in $(toml_sections "$TOML_EXAMPLE"); do
    if toml_sections "$TOML" | grep -qxF -- "$section"; then
      continue
    fi

    {
      printf '\n'
      awk -v sec="$section" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
          cur = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
          if (cur == sec) {
            in_section = 1
            print
            next
          }
          if (in_section) exit
        }
        in_section { print }
      ' "$TOML_EXAMPLE"
    } >>"$TOML"
    log_ok "added skill.$section to config/skills.toml from example"
  done
}

sync_missing_example_keys() {
  local section tmp rc
  for section in $(toml_sections "$TOML_EXAMPLE"); do
    if ! toml_sections "$TOML" | grep -qxF -- "$section"; then
      continue
    fi

    tmp=$(mktemp)
    set +e
    awk -v sec="$section" '
      FNR == NR {
        if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          cur = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
          in_example = (cur == sec)
          next
        }
        if (in_example && $0 ~ /^[[:space:]]*[^#[:space:]][^=]*=/) {
          key = $0
          sub(/=.*/, "", key)
          gsub(/[[:space:]]/, "", key)
          example_count++
          example_keys[example_count] = key
          example_lines[example_count] = $0
        }
        next
      }

      function flush_target(    i, added) {
        if (!in_target) {
          return
        }
        printf "%s", target_buffer
        for (i = 1; i <= example_count; i++) {
          if (!(example_keys[i] in target_keys)) {
            print example_lines[i]
            added = 1
          }
        }
        if (added) {
          changed = 1
        }
        target_buffer = ""
        delete target_keys
        in_target = 0
      }

      {
        if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          cur = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
          if (in_target && cur != sec) {
            flush_target()
          }
          if (cur == sec) {
            in_target = 1
            target_buffer = $0 ORS
            next
          }
        }

        if (in_target) {
          target_buffer = target_buffer $0 ORS
          if ($0 ~ /^[[:space:]]*[^#[:space:]][^=]*=/) {
            key = $0
            sub(/=.*/, "", key)
            gsub(/[[:space:]]/, "", key)
            target_keys[key] = 1
          }
          next
        }

        print
      }

      END {
        flush_target()
        if (changed) {
          exit 42
        }
      }
    ' "$TOML_EXAMPLE" "$TOML" >"$tmp"
    rc=$?
    set -e

    case "$rc" in
      0)
        rm -f "$tmp"
        ;;
      42)
        mv "$tmp" "$TOML"
        log_ok "updated skill.$section in config/skills.toml from example"
        ;;
      *)
        rm -f "$tmp"
        die "failed to sync skill.$section from config/skills.toml.example"
        ;;
    esac
  done
}

main() {
  require_example
  ensure_config
  sync_missing_example_sections
  sync_missing_example_keys
  require_hermes_running
  log_ok "skills sync complete"
}

main "$@"
