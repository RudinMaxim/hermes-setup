#!/usr/bin/env bash
# Configure the native Hermes installation on a dedicated macOS host.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENVFILE="$REPO_ROOT/config/macos.env"
EXAMPLE="$REPO_ROOT/config/macos.env.example"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "setup-macos.sh only supports macOS"
command -v hermes >/dev/null || die "hermes is not installed"
command -v ollama >/dev/null || die "ollama is not installed"
command -v git >/dev/null || die "git is not installed"
command -v brew >/dev/null || die "Homebrew is not installed"
command -v uv >/dev/null || die "uv is not installed"

if [[ ! -f "$ENVFILE" ]]; then
  cp "$EXAMPLE" "$ENVFILE"
  chmod 0600 "$ENVFILE"
  log_ok "created $ENVFILE"
fi

set -a
# shellcheck source=/dev/null
source "$ENVFILE"
set +a

: "${OBSIDIAN_REPO:?set OBSIDIAN_REPO in $ENVFILE}"
: "${OLLAMA_PROFILE:=ollama}"
: "${OLLAMA_MODEL:=gemma4:e2b}"
: "${OLLAMA_BASE_URL:=http://127.0.0.1:11434/v1}"
: "${HERMES_STT_MODEL:=base}"
: "${HERMES_STT_LANGUAGE:=ru}"
: "${HERMES_TTS_VOICE:=Milena}"
: "${HERMES_VISION_MODEL:=google/gemini-3-flash-preview}"

[[ -d "$OBSIDIAN_REPO/.git" ]] || die "Obsidian vault is not a Git repository: $OBSIDIAN_REPO"

hermes_env=$(hermes config env-path)
if grep -q '^OBSIDIAN_VAULT_PATH=' "$hermes_env"; then
  awk -v value="$OBSIDIAN_REPO" '
    /^OBSIDIAN_VAULT_PATH=/ { print "OBSIDIAN_VAULT_PATH=" value; next }
    { print }
  ' "$hermes_env" >"$hermes_env.tmp"
  mv "$hermes_env.tmp" "$hermes_env"
else
  printf '\nOBSIDIAN_VAULT_PATH=%s\n' "$OBSIDIAN_REPO" >>"$hermes_env"
fi
chmod 0600 "$hermes_env"
log_ok "configured Obsidian vault for Hermes"

if ! hermes profile show "$OLLAMA_PROFILE" >/dev/null 2>&1; then
  hermes profile create "$OLLAMA_PROFILE" --clone
fi
hermes profile alias "$OLLAMA_PROFILE" --name "hermes-$OLLAMA_PROFILE" >/dev/null
profile_cmd="$HOME/.local/bin/hermes-$OLLAMA_PROFILE"
"$profile_cmd" config set model.provider custom >/dev/null
"$profile_cmd" config set model.default "$OLLAMA_MODEL" >/dev/null
"$profile_cmd" config set model.base_url "$OLLAMA_BASE_URL" >/dev/null
"$profile_cmd" config set model.api_mode chat_completions >/dev/null
log_ok "configured profile $OLLAMA_PROFILE with $OLLAMA_MODEL"

if ! hermes mcp list 2>/dev/null | grep -qE '^[[:space:]]*obsidian[[:space:]]'; then
  if ! command -v mcp-server-filesystem >/dev/null 2>&1; then
    npm install -g @modelcontextprotocol/server-filesystem
  fi
  printf 'y\n' | hermes mcp add obsidian \
    --command "$(command -v mcp-server-filesystem)" \
    --args "$OBSIDIAN_REPO"
  log_ok "configured scoped Obsidian filesystem MCP"
else
  log_skip "Obsidian MCP is already configured"
fi

if ! hermes mcp list 2>/dev/null | grep -qE '^[[:space:]]*todoist[[:space:]]'; then
  printf 'y\n' | hermes mcp add todoist \
    --url https://ai.todoist.net/mcp \
    --auth oauth
  log_ok "configured official Todoist MCP"
else
  log_skip "Todoist MCP is already configured"
fi

hermes_python="$HOME/.hermes/hermes-agent/venv/bin/python"
[[ -x "$hermes_python" ]] || die "Hermes Python venv not found: $hermes_python"
"$hermes_python" "$SCRIPT_DIR/macos/configure-hermes-rules.py"
log_ok "configured Telegram rules for reliable Todoist recovery"

for formula in ffmpeg portaudio openai-whisper; do
  if brew list --versions "$formula" >/dev/null 2>&1; then
    log_skip "Homebrew formula $formula is already installed"
  else
    brew install "$formula"
    log_ok "installed Homebrew formula $formula"
  fi
done

uv pip install --quiet --python "$hermes_python" sounddevice numpy
"$hermes_python" "$SCRIPT_DIR/macos/configure-multimedia.py" \
  --tts-script "$SCRIPT_DIR/macos/macos-say-tts.sh"
log_ok "configured local Russian STT, native macOS TTS, and multimodal analysis"

if pgrep -f '[o]llama serve' >/dev/null 2>&1; then
  log_skip "Ollama is already running"
else
  open -gj -a Ollama
  log_ok "started Ollama app"
fi

hermes gateway install >/dev/null
hermes gateway restart >/dev/null
log_ok "Hermes Telegram gateway is installed and running"

bash "$SCRIPT_DIR/macos/install-obsidian-sync.sh"
bash "$SCRIPT_DIR/macos/install-runtime-jobs.sh"
bash "$SCRIPT_DIR/macos/check-multimedia.sh" \
  || log_warn "one or more multimedia checks need attention"
log_ok "native macOS setup complete"
