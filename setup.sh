#!/usr/bin/env bash
# One-command wrapper for the Hermes-side setup flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/scripts/setup.sh" "$@"
