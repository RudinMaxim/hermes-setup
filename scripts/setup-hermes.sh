#!/usr/bin/env bash
# scripts/setup-hermes.sh — Idempotently launch the Hermes container.
# Runs as the unprivileged 'hermes' user (with docker group membership).
# Use --configs-only to bail out before any docker calls (for testing).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
ENVFILE="$CONFIG_DIR/.env"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/write_file.sh
source "$SCRIPT_DIR/lib/write_file.sh"
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"

CONFIGS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --configs-only)    CONFIGS_ONLY=1 ;;
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

DEFAULT_IMAGE="nousresearch/hermes-agent:latest"
LOCAL_IMAGE="hermes-agent:local"
DEFAULT_FALLBACK_BASE_IMAGE="public.ecr.aws/docker/library/ubuntu:26.04"
DEFAULT_MODEL_PROVIDER="openrouter"
DEFAULT_MODEL="openai/gpt-5.4-mini"
HERMES_IMAGE=""

require_non_root() {
  [[ $EUID -ne 0 ]] || die "do not run as root — use the 'hermes' user"
}

require_docker_group() {
  if ! has_command docker; then
    die "docker is not in PATH — run setup-server.sh first"
  fi
  if ! docker info >/dev/null 2>&1; then
    if ! user_in_group "$(whoami)" docker 2>/dev/null; then
      die "cannot access Docker daemon — current user is not in the 'docker' group; log out and back in after running setup-server.sh, or run: newgrp docker"
    fi
    die "cannot access Docker daemon — if setup-server.sh just added the docker group, log out and back in or run: newgrp docker"
  fi
}

ensure_configs() {
  if [[ ! -f "$CONFIG_DIR/.env" ]]; then
    log_act "copying .env.example -> .env"
    cp "$CONFIG_DIR/.env.example" "$CONFIG_DIR/.env"
    chmod 0600 "$CONFIG_DIR/.env"
    log_ok ".env created"
  else
    log_skip ".env already exists"
  fi

  if [[ ! -f "$CONFIG_DIR/mcp.toml" ]]; then
    log_act "copying mcp.toml.example -> mcp.toml"
    cp "$CONFIG_DIR/mcp.toml.example" "$CONFIG_DIR/mcp.toml"
    log_ok "mcp.toml created"
  else
    log_skip "mcp.toml already exists"
  fi

  if [[ ! -f "$CONFIG_DIR/gateways.toml" ]]; then
    log_act "copying gateways.toml.example -> gateways.toml"
    cp "$CONFIG_DIR/gateways.toml.example" "$CONFIG_DIR/gateways.toml"
    log_ok "gateways.toml created"
  else
    log_skip "gateways.toml already exists"
  fi
}

ensure_llm_key() {
  if env_var_set_in_file "$ENVFILE" OPENROUTER_API_KEY \
     || env_var_set_in_file "$ENVFILE" OPENAI_API_KEY \
     || env_var_set_in_file "$ENVFILE" ANTHROPIC_API_KEY; then
    log_ok "LLM API key present in .env"
    return 0
  fi
  if is_interactive; then
    local provider var key
    provider=$(prompt_value "LLM provider (openrouter/openai/anthropic)")
    case "$provider" in
      openrouter|OpenRouter|OPENROUTER) var=OPENROUTER_API_KEY ;;
      anthropic|Anthropic|ANTHROPIC) var=ANTHROPIC_API_KEY ;;
      *)                             var=OPENAI_API_KEY ;;
    esac
    key=$(prompt_secret "$var")
    [[ -n "$key" ]] || die "empty API key entered — aborting"
    log_act "saving $var to .env"
    set_env_value "$ENVFILE" "$var" "$key" >/dev/null
    log_ok "$var saved to .env (${#key} chars)"
    return 0
  fi
  die "no LLM API key configured — set OPENROUTER_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY in $ENVFILE (see docs/02-hermes-setup.md)"
}

run_fallback_build() {
  local fallback_base_image="$1"
  local build_log
  build_log=$(mktemp)

  if docker build --build-arg "BASE_IMAGE=$fallback_base_image" -t "$LOCAL_IMAGE" -f "$REPO_ROOT/docker/Dockerfile.hermes" "$REPO_ROOT" >"$build_log" 2>&1; then
    rm -f "$build_log"
    return 0
  fi

  if grep -qiE 'toomanyrequests|Too Many Requests|pull rate limit' "$build_log"; then
    log_warn "Docker Hub anonymous pull rate limit hit during fallback build"
    log_warn "current fallback base image: $fallback_base_image"
    log_warn "use a non-Docker-Hub mirror in $ENVFILE, for example:"
    log_warn "  HERMES_FALLBACK_BASE_IMAGE=$DEFAULT_FALLBACK_BASE_IMAGE"
  else
    log_warn "fallback docker build failed; recent Docker output:"
  fi

  tail -n 40 "$build_log" >&2 || true
  rm -f "$build_log"
  die "could not build $LOCAL_IMAGE"
}

ensure_image() {
  if docker_image_present "$DEFAULT_IMAGE"; then
    log_skip "image $DEFAULT_IMAGE already present"
    HERMES_IMAGE="$DEFAULT_IMAGE"
    set_env_value "$ENVFILE" HERMES_IMAGE "$HERMES_IMAGE" >/dev/null || true
    return 0
  fi

  if docker_image_present "$LOCAL_IMAGE"; then
    log_skip "image $LOCAL_IMAGE already present (local fallback)"
    HERMES_IMAGE="$LOCAL_IMAGE"
    set_env_value "$ENVFILE" HERMES_IMAGE "$HERMES_IMAGE" >/dev/null || true
    return 0
  fi

  log_act "pulling $DEFAULT_IMAGE"
  if docker pull "$DEFAULT_IMAGE" >/dev/null 2>&1; then
    log_ok "pulled $DEFAULT_IMAGE"
    HERMES_IMAGE="$DEFAULT_IMAGE"
    set_env_value "$ENVFILE" HERMES_IMAGE "$HERMES_IMAGE" >/dev/null || true
    return 0
  fi

  log_warn "pull failed for $DEFAULT_IMAGE — falling back to local build"
  local fallback_base_image
  fallback_base_image="${HERMES_FALLBACK_BASE_IMAGE:-$(read_env_value "$ENVFILE" HERMES_FALLBACK_BASE_IMAGE 2>/dev/null || printf '%s' "$DEFAULT_FALLBACK_BASE_IMAGE")}"
  log_act "docker build --build-arg BASE_IMAGE=$fallback_base_image -t $LOCAL_IMAGE -f docker/Dockerfile.hermes ."
  run_fallback_build "$fallback_base_image"
  log_ok "built $LOCAL_IMAGE"
  HERMES_IMAGE="$LOCAL_IMAGE"
  set_env_value "$ENVFILE" HERMES_IMAGE "$HERMES_IMAGE" >/dev/null || true
}

load_compose_env() {
  HERMES_IMAGE=$(read_env_value "$ENVFILE" HERMES_IMAGE 2>/dev/null || printf '%s' "$DEFAULT_IMAGE")
  export HERMES_IMAGE
  HERMES_PROJECTS_DIR=$(read_env_value "$ENVFILE" HERMES_PROJECTS_DIR 2>/dev/null || printf '%s' "/home/hermes/projects")
  export HERMES_PROJECTS_DIR
}

ensure_projects_dir() {
  local dir
  dir=$(read_env_value "$ENVFILE" HERMES_PROJECTS_DIR 2>/dev/null || printf '%s' "/home/hermes/projects")
  if [[ -d "$dir" ]]; then
    log_skip "projects directory $dir already exists"
    return 0
  fi
  log_act "creating projects directory $dir"
  mkdir -p "$dir" || die "cannot create projects directory $dir"
  log_ok "projects directory $dir created"
}

ensure_volume() {
  if docker_volume_present hermes_data; then
    log_skip "volume hermes_data already exists"
  else
    log_act "creating volume hermes_data"
    docker volume create hermes_data >/dev/null
    log_ok "volume hermes_data created"
  fi
}

ensure_network() {
  if docker network inspect hermes_net &>/dev/null; then
    log_skip "network hermes_net already exists"
  else
    log_act "creating network hermes_net"
    docker network create hermes_net >/dev/null
    log_ok "network hermes_net created"
  fi
}

container_has_mount() {
  local container="$1" dest="$2"
  docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$container" 2>/dev/null \
    | grep -qxF -- "$dest"
}

ensure_compose_up() {
  if docker_container_running hermes; then
    if container_has_mount hermes /home/hermes/projects; then
      log_skip "container 'hermes' already running"
    else
      log_act "recreating container 'hermes' to apply compose mounts"
      HERMES_IMAGE="$HERMES_IMAGE" docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d --force-recreate >/dev/null
      log_ok "container 'hermes' recreated"
    fi
    return 0
  fi
  if docker_container_exists hermes; then
    # Container exists but is stopped/exited. `compose up` would fail with
    # 'container name already in use' — start it explicitly instead.
    if container_has_mount hermes /home/hermes/projects; then
      log_act "starting existing 'hermes' container"
      docker start hermes >/dev/null
      log_ok "container 'hermes' started"
    else
      log_act "recreating existing 'hermes' container to apply compose mounts"
      HERMES_IMAGE="$HERMES_IMAGE" docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d --force-recreate >/dev/null
      log_ok "container 'hermes' recreated"
    fi
    return 0
  fi
  log_act "docker compose up -d hermes"
  HERMES_IMAGE="$HERMES_IMAGE" docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d >/dev/null
  log_ok "container 'hermes' started"
}

wait_for_health() {
  local i
  for i in $(seq 1 30); do
    if docker exec hermes hermes --version &>/dev/null; then
      log_ok "hermes responsive ($(docker exec hermes hermes --version 2>/dev/null))"
      return 0
    fi
    sleep 1
  done
  log_warn "hermes did not become healthy in 30s — recent logs:"
  docker logs --tail=50 hermes || true
  die "health gate failed"
}

# Best-effort: run `hermes setup --non-interactive` once on first start and
# enable redact_secrets. If the subcommand isn't supported by this Hermes
# build, we log a warning and continue — the container is already usable.
first_run_init() {
  if docker exec hermes test -f /home/hermes/.hermes/config.yaml; then
    log_skip "hermes config.yaml already exists (first-run init done)"
    return 0
  fi
  if docker exec hermes hermes setup --help 2>/dev/null | grep -q -- '--non-interactive'; then
    log_act "running hermes setup --non-interactive"
    docker exec hermes hermes setup --non-interactive >/dev/null || \
      log_warn "hermes setup --non-interactive exited non-zero — continuing"
    log_ok "hermes setup completed"
  else
    log_warn "hermes setup --non-interactive not supported by this build — skipping first-run init"
  fi
  # hermes has no `config get` subcommand — read via `config show` and parse.
  # Match a line like "redact_secrets: true" (YAML-ish output).
  if docker exec hermes hermes config show 2>/dev/null \
       | grep -qE '^[[:space:]]*redact_secrets:[[:space:]]*true([[:space:]]|$)'; then
    log_skip "redact_secrets already true"
  else
    log_act "setting redact_secrets=true"
    if docker exec hermes hermes config set redact_secrets true >/dev/null 2>&1; then
      log_ok "redact_secrets enabled"
    else
      log_warn "could not set redact_secrets (check 'docker exec hermes hermes config set redact_secrets true')"
    fi
  fi
}

ensure_model_config() {
  local provider model
  provider="${HERMES_MODEL_PROVIDER:-$(read_env_value "$ENVFILE" HERMES_MODEL_PROVIDER 2>/dev/null || printf '%s' "$DEFAULT_MODEL_PROVIDER")}"
  model="${HERMES_MODEL:-$(read_env_value "$ENVFILE" HERMES_MODEL 2>/dev/null || printf '%s' "$DEFAULT_MODEL")}"

  log_act "setting Hermes model default to $provider/$model"
  local rc
  set +e
  docker exec -i hermes python3 - "$provider" "$model" <<'PY'
import os
import sys
from pathlib import Path

import yaml

provider, model = sys.argv[1:3]
path = Path("/home/hermes/.hermes/config.yaml")
path.parent.mkdir(parents=True, exist_ok=True)

try:
    config = yaml.safe_load(path.read_text(encoding="utf-8")) if path.exists() else {}
except Exception:
    config = {}

if not isinstance(config, dict):
    config = {}

current = config.get("model")
desired = {"provider": provider, "default": model}
if current == desired:
    raise SystemExit(2)

config["model"] = desired
path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
PY
  rc=$?
  set -e
  case "$rc" in
    0) log_ok "Hermes model default set to $provider/$model" ;;
    2) log_skip "Hermes model default already $provider/$model" ;;
    *) die "could not update Hermes model config" ;;
  esac
}

main() {
  require_non_root
  ensure_configs
  ensure_llm_key
  if (( CONFIGS_ONLY )); then
    log_ok "configs-only mode: stopping before docker steps"
    return 0
  fi
  require_docker_group
  ensure_image
  if [[ -n "${HERMES_NO_COMPOSE:-}" ]]; then
    log_ok "HERMES_NO_COMPOSE set: stopping before compose up"
    return 0
  fi
  load_compose_env
  ensure_projects_dir
  ensure_volume
  ensure_network
  ensure_compose_up
  wait_for_health
  first_run_init
  ensure_model_config
  log_ok "hermes setup complete"
  log_ok "next: edit config/mcp.toml to enable MCP servers, then run ./scripts/setup-mcp.sh"
}

main "$@"
