#!/usr/bin/env bash
# Check native Hermes services and notify Telegram only on state changes.

set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENVFILE="${HERMES_MACOS_ENV:-$REPO_ROOT/config/macos.env}"
HERMES_ENV="${HERMES_ENV:-$HOME/.hermes/.env}"
STATE_DIR="${HERMES_HEALTH_STATE_DIR:-$HOME/Library/Application Support/Hermes}"
STATE_FILE="$STATE_DIR/health-state"
NOTIFY=1
CORE_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --no-notify) NOTIFY=0 ;;
    --core) CORE_ONLY=1 ;;
    *)
      printf 'usage: %s [--no-notify] [--core]\n' "$0" >&2
      exit 2
      ;;
  esac
done

[[ -f "$ENVFILE" ]] && {
  set -a
  # shellcheck source=/dev/null
  source "$ENVFILE"
  set +a
}

read_env_value() {
  local file=$1 key=$2
  awk -v key="$key" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$file"
}

if [[ -f "$HERMES_ENV" ]]; then
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(read_env_value "$HERMES_ENV" TELEGRAM_BOT_TOKEN)}"
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-$(read_env_value "$HERMES_ENV" TELEGRAM_ALLOWED_USERS)}"
  TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-$(read_env_value "$HERMES_ENV" TELEGRAM_HOME_CHANNEL)}"
fi

: "${OLLAMA_MODEL:=gemma4:e2b}"
: "${OBSIDIAN_REPO:=}"
: "${HEALTHCHECK_TELEGRAM_CHAT_ID:=${TELEGRAM_HOME_CHANNEL:-${TELEGRAM_ALLOWED_USERS%%,*}}}"

failures=()
passes=()

pass() {
  passes+=("$1")
}

fail() {
  failures+=("$1")
}

if launchctl print "gui/$(id -u)/ai.hermes.gateway" 2>/dev/null \
  | grep -q 'state = running'; then
  pass "Hermes gateway"
else
  fail "Hermes gateway is not running"
fi

wrapper_source="$SCRIPT_DIR/hermes-wrapper.sh"
wrapper_target="$HOME/.local/bin/hermes"
if [[ -x "$wrapper_target" ]] && cmp -s "$wrapper_source" "$wrapper_target"; then
  pass "Hermes safety wrapper"
else
  fail "Hermes safety wrapper is missing or was replaced"
fi

ollama_json=$(curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null)
if [[ -z "$ollama_json" ]]; then
  fail "Ollama API is unavailable"
elif grep -Fq "$OLLAMA_MODEL" <<<"$ollama_json"; then
  pass "Ollama $OLLAMA_MODEL"
else
  fail "Ollama model $OLLAMA_MODEL is not installed"
fi

if (( ! CORE_ONLY )); then
  if hermes mcp test todoist >/dev/null 2>&1; then
    pass "Todoist MCP"
  else
    fail "Todoist MCP failed"
  fi

  if hermes mcp test obsidian >/dev/null 2>&1; then
    pass "Obsidian MCP"
  else
    fail "Obsidian MCP failed"
  fi

  obsidian_skill_source="$REPO_ROOT/skills/obsidian-para/SKILL.md"
  obsidian_skill_target="$HOME/.hermes/skills/obsidian-para/SKILL.md"
  if [[ -f "$obsidian_skill_target" ]] \
    && cmp -s "$obsidian_skill_source" "$obsidian_skill_target"; then
    pass "Obsidian PARA skill"
  else
    fail "Obsidian PARA skill is missing or outdated"
  fi

  if hermes mcp test playwright >/dev/null 2>&1; then
    pass "Playwright MCP"
  else
    fail "Playwright MCP failed"
  fi

  google_setup="$HOME/.hermes/hermes-agent/skills/productivity/google-workspace/scripts/setup.py"
  hermes_python="$HOME/.hermes/hermes-agent/venv/bin/python"
  if [[ -x "$hermes_python" && -f "$google_setup" ]] \
    && "$hermes_python" "$google_setup" --check-live >/dev/null 2>&1; then
    pass "Google Workspace"
  else
    fail "Google Workspace API failed"
  fi

  if [[ -n "$OBSIDIAN_REPO" && -d "$OBSIDIAN_REPO/.git" ]]; then
    git_dir=$(git -C "$OBSIDIAN_REPO" rev-parse --git-dir 2>/dev/null)
    if [[ -n "$git_dir" && ! -e "$OBSIDIAN_REPO/$git_dir/rebase-merge" \
      && ! -e "$OBSIDIAN_REPO/$git_dir/rebase-apply" \
      && ! -e "$OBSIDIAN_REPO/$git_dir/MERGE_HEAD" ]]; then
      pass "Obsidian Git"
    else
      fail "Obsidian Git has an unfinished operation"
    fi
  else
    fail "Obsidian repository is unavailable"
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] \
    && curl -fsS --max-time 8 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" \
      | grep -q '"ok":true'; then
    pass "Telegram API"
  else
    fail "Telegram API failed"
  fi
fi

mkdir -p "$STATE_DIR"
if (( ${#failures[@]} == 0 )); then
  state="ok"
  message="Hermes health-check: восстановлено. Все ${#passes[@]} проверок работают."
else
  state="fail:$(printf '%s\n' "${failures[@]}" | shasum -a 256 | awk '{print $1}')"
  message="Hermes health-check: обнаружены ошибки:"
  for failure in "${failures[@]}"; do
    message+=$'\n'"- $failure"
  done
fi

previous_state=$(cat "$STATE_FILE" 2>/dev/null || true)

if (( NOTIFY && ! CORE_ONLY )) && [[ "$state" != "$previous_state" ]] \
  && [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "$HEALTHCHECK_TELEGRAM_CHAT_ID" ]]; then
  if [[ "$state" != "ok" || "$previous_state" == fail:* ]]; then
    curl -fsS --max-time 10 \
      --data-urlencode "chat_id=$HEALTHCHECK_TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$message" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      >/dev/null 2>&1 || true
  fi
fi

if (( NOTIFY && ! CORE_ONLY )); then
  printf '%s\n' "$state" >"$STATE_FILE"
fi

printf '[%s] %s\n' "$([[ "$state" == "ok" ]] && printf OK || printf FAIL)" "$message"
[[ "$state" == "ok" ]]
