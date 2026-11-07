#!/usr/bin/env bash
# ssh to hermes-vps with retries on flaky connections. Usage: sshr.sh '<remote command>'
# Output is buffered: nothing is printed until the remote command finishes.
for i in 1 2 3 4 5 6; do
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=25 hermes-vps "$1" 2>&1); rc=$?
  if ! grep -qE "banner exchange|Connection timed out|Connection reset|Connection closed by" <<<"$out"; then
    printf '%s\n' "$out"; exit $rc
  fi
  sleep 4
done
echo "SSH unreachable after retries"; exit 255
