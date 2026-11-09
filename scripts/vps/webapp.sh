#!/usr/bin/env bash
# Open the Hermes Webapp (0.23+) on hermes-vps through an SSH tunnel.
# The Webapp listens on 127.0.0.1:9120 on the server; sign-in is a one-use link valid 60 s.
# Usage: bash scripts/vps/webapp.sh   (keep the window open while you use the Webapp; Ctrl+C closes the tunnel)
set -u
PORT=9120
if ! (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
  ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L $PORT:127.0.0.1:$PORT hermes-vps || { echo "tunnel failed"; exit 1; }
  echo "tunnel up: localhost:$PORT -> hermes-vps:127.0.0.1:$PORT"
fi
link=$(ssh hermes-vps '~/.local/bin/hermes webapp --no-open --skip-build 2>&1' | grep -oE 'http://127\.0\.0\.1:[0-9]+/webapp/launch#ticket=[A-Za-z0-9_-]+' | head -1)
[ -z "$link" ] && { echo "no sign-in link (is webapp.enabled true and gateway running?)"; exit 1; }
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) powershell.exe -NoProfile -Command "Start-Process '$link'" ;;
  Darwin) open "$link" ;;
  *) xdg-open "$link" 2>/dev/null || echo "open: $link" ;;
esac
echo "opened the Webapp sign-in link (valid 60 s). Tunnel stays up in the background; close it with: pkill -f 'L $PORT:127.0.0.1:$PORT'"
