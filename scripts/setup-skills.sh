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

main() {
  require_example
  ensure_config
  require_hermes_running
  log_ok "skills sync complete"
}

main "$@"
