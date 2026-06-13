#!/usr/bin/env bash
# Check or apply a Hermes update with backup and post-update verification.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENVFILE="${HERMES_MACOS_ENV:-$REPO_ROOT/config/macos.env}"
HERMES_REPO="${HERMES_REPO:-$HOME/.hermes/hermes-agent}"
MODE="${1:-check}"

[[ -f "$ENVFILE" ]] && {
  set -a
  # shellcheck source=/dev/null
  source "$ENVFILE"
  set +a
}

: "${HERMES_UPDATE_BRANCH:=main}"
: "${HERMES_EXPECTED_VERSION:=}"

current_version() {
  hermes --version | sed -n 's/^Hermes Agent v\([^ ]*\).*/\1/p' | head -n 1
}

case "$MODE" in
  check)
    installed=$(current_version)
    printf '[INFO] installed Hermes: %s\n' "${installed:-unknown}"
    if [[ -n "$HERMES_EXPECTED_VERSION" && "$installed" != "$HERMES_EXPECTED_VERSION" ]]; then
      printf '[WARN] expected version is %s\n' "$HERMES_EXPECTED_VERSION"
    fi
    hermes update --check --branch "$HERMES_UPDATE_BRANCH"
    ;;
  apply)
    [[ -d "$HERMES_REPO/.git" ]] || {
      printf '[ERR] Hermes Git checkout not found: %s\n' "$HERMES_REPO" >&2
      exit 1
    }
    [[ -z "$(git -C "$HERMES_REPO" status --porcelain)" ]] || {
      printf '[ERR] Hermes checkout has local changes; update aborted\n' >&2
      exit 1
    }

    previous_commit=$(git -C "$HERMES_REPO" rev-parse HEAD)
    previous_version=$(current_version)
    printf '[INFO] updating Hermes %s from %s\n' \
      "$previous_version" "${previous_commit:0:12}"

    hermes update --backup --yes --branch "$HERMES_UPDATE_BRANCH"
    bash "$SCRIPT_DIR/install-hermes-wrapper.sh"
    hash -r
    hermes gateway restart

    if "$SCRIPT_DIR/health-check.sh" --no-notify --core; then
      new_commit=$(git -C "$HERMES_REPO" rev-parse HEAD)
      printf '[OK] Hermes updated: %s -> %s (%s)\n' \
        "$previous_version" "$(current_version)" "${new_commit:0:12}"
      "$SCRIPT_DIR/health-check.sh" --no-notify \
        || printf '[WARN] update is healthy, but an external integration needs attention\n'
    else
      printf '[ERR] post-update health-check failed\n' >&2
      printf '[ACT] rolling Hermes back to %s\n' "${previous_commit:0:12}" >&2
      git -C "$HERMES_REPO" reset --hard "$previous_commit"
      uv pip install --python "$HERMES_REPO/venv/bin/python" \
        -e "$HERMES_REPO[all]"
      bash "$SCRIPT_DIR/install-hermes-wrapper.sh"
      hash -r
      hermes gateway restart
      printf '[WARN] rollback completed; inspect health-check logs before retrying\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'usage: %s [check|apply]\n' "$0" >&2
    exit 2
    ;;
esac
