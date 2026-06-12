#!/usr/bin/env bash
# Install launchd jobs for Ollama watchdog and Hermes health checks.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENVFILE="${HERMES_MACOS_ENV:-$REPO_ROOT/config/macos.env}"

[[ "$(uname -s)" == "Darwin" ]] || {
  printf '[ERR] this installer only supports macOS\n' >&2
  exit 1
}

[[ -f "$ENVFILE" ]] && {
  set -a
  # shellcheck source=/dev/null
  source "$ENVFILE"
  set +a
}

: "${OLLAMA_WATCH_INTERVAL:=60}"
: "${HERMES_HEALTH_INTERVAL:=900}"

launch_agents="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/hermes"
uid=$(id -u)
mkdir -p "$launch_agents" "$log_dir"

xml_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

install_job() {
  local label=$1 script=$2 interval=$3
  local plist="$launch_agents/$label.plist"

  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$script")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/Users/$(id -un)/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HERMES_MACOS_ENV</key>
    <string>$(xml_escape "$ENVFILE")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$interval</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$log_dir/${label#ai.hermes.}.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$log_dir/${label#ai.hermes.}.error.log")</string>
</dict>
</plist>
EOF

  plutil -lint "$plist" >/dev/null
  launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$uid" "$plist"
  launchctl kickstart -k "gui/$uid/$label"
  printf '[OK] installed %s (every %ss)\n' "$label" "$interval"
}

install_job "ai.hermes.ollama-watchdog" \
  "$SCRIPT_DIR/ensure-ollama.sh" "$OLLAMA_WATCH_INTERVAL"
install_job "ai.hermes.health-check" \
  "$SCRIPT_DIR/health-check.sh" "$HERMES_HEALTH_INTERVAL"
