#!/usr/bin/env bash
# Install/update the per-user launchd job for Obsidian Git synchronization.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENVFILE="${HERMES_MACOS_ENV:-$REPO_ROOT/config/macos.env}"

[[ "$(uname -s)" == "Darwin" ]] || {
  printf '[ERR] this installer only supports macOS\n' >&2
  exit 1
}
[[ -f "$ENVFILE" ]] || {
  printf '[ERR] missing %s\n' "$ENVFILE" >&2
  exit 1
}

set -a
# shellcheck source=/dev/null
source "$ENVFILE"
set +a

: "${OBSIDIAN_REPO:?set OBSIDIAN_REPO in $ENVFILE}"
: "${OBSIDIAN_REMOTE:=origin}"
: "${OBSIDIAN_BRANCH:=main}"
: "${OBSIDIAN_SYNC_INTERVAL:=300}"

label="ai.hermes.obsidian-sync"
plist="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/hermes"
uid=$(id -u)

mkdir -p "$(dirname "$plist")" "$log_dir"

xml_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

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
    <string>$(xml_escape "$SCRIPT_DIR/sync-obsidian.sh")</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$OBSIDIAN_REPO")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>OBSIDIAN_REPO</key>
    <string>$(xml_escape "$OBSIDIAN_REPO")</string>
    <key>OBSIDIAN_REMOTE</key>
    <string>$(xml_escape "$OBSIDIAN_REMOTE")</string>
    <key>OBSIDIAN_BRANCH</key>
    <string>$(xml_escape "$OBSIDIAN_BRANCH")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$OBSIDIAN_SYNC_INTERVAL</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$log_dir/obsidian-sync.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$log_dir/obsidian-sync.error.log")</string>
</dict>
</plist>
EOF

plutil -lint "$plist" >/dev/null
launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$plist"
launchctl kickstart -k "gui/$uid/$label"

printf '[OK] installed %s (every %ss)\n' "$plist" "$OBSIDIAN_SYNC_INTERVAL"
