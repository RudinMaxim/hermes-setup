#!/usr/bin/env bash
# Install the managed macOS Hermes wrapper without modifying the upstream checkout.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/hermes-wrapper.sh"
TARGET="${HERMES_WRAPPER_TARGET:-$HOME/.local/bin/hermes}"
REAL_HERMES="${HERMES_REAL_BIN:-$HOME/.hermes/hermes-agent/venv/bin/hermes}"

[[ "$(uname -s)" == "Darwin" ]] || {
  printf '[ERR] Hermes wrapper installer only supports macOS\n' >&2
  exit 1
}
[[ -x "$REAL_HERMES" ]] || {
  printf '[ERR] real Hermes binary not found: %s\n' "$REAL_HERMES" >&2
  exit 1
}

mkdir -p "$(dirname "$TARGET")"
if [[ -f "$TARGET" ]] && cmp -s "$SOURCE" "$TARGET"; then
  printf '[SKIP] Hermes safety wrapper is already installed\n'
  exit 0
fi

install -m 0755 "$SOURCE" "$TARGET"
printf '[OK] installed Hermes safety wrapper: %s\n' "$TARGET"
