#!/usr/bin/env bash
# tests/run-tests.sh — integration tests entrypoint.
# Builds (if needed) and runs the systemd sandbox container, mounts the repo,
# executes bats on tests/integration.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="hermes-setup-test"

if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "[run-tests] building image $IMAGE"
  docker build -t "$IMAGE" -f "$REPO_ROOT/tests/Dockerfile.ubuntu-systemd" "$REPO_ROOT"
fi

CONTAINER="hermes-setup-test-$$"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

docker run -d --rm \
  --name "$CONTAINER" \
  --privileged \
  --tmpfs /tmp \
  --tmpfs /run \
  -v "$REPO_ROOT:/repo" \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  "$IMAGE" >/dev/null

for _ in 1 2 3 4 5; do
  if docker exec "$CONTAINER" systemctl is-system-running --wait 2>/dev/null | \
       grep -qE 'running|degraded'; then
    break
  fi
  sleep 1
done

docker exec "$CONTAINER" bash -c 'cd /repo && bats tests/integration'
