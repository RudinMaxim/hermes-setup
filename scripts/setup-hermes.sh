#!/usr/bin/env bash
# scripts/setup-hermes.sh — Idempotently launch the Hermes container.
# Runs as the unprivileged 'hermes' user (with docker group membership).
# Use --configs-only to bail out before any docker calls (for testing).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/write_file.sh
source "$SCRIPT_DIR/lib/write_file.sh"

CONFIGS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --configs-only) CONFIGS_ONLY=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

DEFAULT_IMAGE="nousresearch/hermes-agent:latest"
LOCAL_IMAGE="hermes-agent:local"
HERMES_IMAGE=""

require_non_root() {
  [[ $EUID -ne 0 ]] || die "do not run as root — use the 'hermes' user"
}

require_docker_group() {
  if ! user_in_group "$(whoami)" docker 2>/dev/null && ! has_command docker; then
    die "current user not in 'docker' group and 'docker' not in PATH — log out and back in after running setup-server.sh, or run: newgrp docker"
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
}

ensure_llm_key() {
  if env_var_set_in_file "$CONFIG_DIR/.env" OPENAI_API_KEY \
     || env_var_set_in_file "$CONFIG_DIR/.env" ANTHROPIC_API_KEY; then
    log_ok "LLM API key present in .env"
    return 0
  fi
  die "no LLM API key configured — set OPENAI_API_KEY or ANTHROPIC_API_KEY in $CONFIG_DIR/.env (see docs/02-hermes-setup.md)"
}

ensure_image() {
  if docker_image_present "$DEFAULT_IMAGE"; then
    log_skip "image $DEFAULT_IMAGE already present"
    HERMES_IMAGE="$DEFAULT_IMAGE"
    return 0
  fi

  if docker_image_present "$LOCAL_IMAGE"; then
    log_skip "image $LOCAL_IMAGE already present (local fallback)"
    HERMES_IMAGE="$LOCAL_IMAGE"
    return 0
  fi

  log_act "pulling $DEFAULT_IMAGE"
  if docker pull "$DEFAULT_IMAGE" >/dev/null 2>&1; then
    log_ok "pulled $DEFAULT_IMAGE"
    HERMES_IMAGE="$DEFAULT_IMAGE"
    return 0
  fi

  log_warn "pull failed for $DEFAULT_IMAGE — falling back to local build"
  log_act "docker build -t $LOCAL_IMAGE -f docker/Dockerfile.hermes ."
  docker build -t "$LOCAL_IMAGE" -f "$REPO_ROOT/docker/Dockerfile.hermes" "$REPO_ROOT" >/dev/null
  log_ok "built $LOCAL_IMAGE"
  HERMES_IMAGE="$LOCAL_IMAGE"
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

ensure_compose_up() {
  if docker_container_running hermes; then
    log_skip "container 'hermes' already running"
    return 0
  fi
  if docker_container_exists hermes; then
    # Container exists but is stopped/exited. `compose up` would fail with
    # 'container name already in use' — start it explicitly instead.
    log_act "starting existing 'hermes' container"
    docker start hermes >/dev/null
    log_ok "container 'hermes' started"
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
  if docker exec hermes hermes config get redact_secrets &>/dev/null; then
    if [[ "$(docker exec hermes hermes config get redact_secrets 2>/dev/null)" == "true" ]]; then
      log_skip "redact_secrets already true"
    else
      log_act "setting redact_secrets=true"
      docker exec hermes hermes config set redact_secrets true >/dev/null
      log_ok "redact_secrets enabled"
    fi
  else
    log_warn "hermes config get redact_secrets not supported — skipping"
  fi
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
  ensure_volume
  ensure_network
  ensure_compose_up
  wait_for_health
  first_run_init
  log_ok "hermes setup complete"
  log_ok "next: edit config/mcp.toml to enable MCP servers, then run ./scripts/setup-mcp.sh"
}

main "$@"
