#!/usr/bin/env bash
# scripts/setup-mcp.sh — Idempotently sync MCP servers based on config/mcp.toml.
# Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
TOML="$CONFIG_DIR/mcp.toml"
TOML_EXAMPLE="$CONFIG_DIR/mcp.toml.example"
ENVFILE="$CONFIG_DIR/.env"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

# setup-mcp has no prompts of its own yet; --non-interactive is accepted only so
# the setup.sh orchestrator can pass "$@" through without aborting on it.
for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_hermes_running() {
  if ! docker_container_running hermes; then
    die "hermes container is not running — run scripts/setup-hermes.sh first"
  fi
}

require_files() {
  [[ -f "$TOML" ]] || die "missing $TOML"
  [[ -f "$TOML_EXAMPLE" ]] || die "missing $TOML_EXAMPLE"
  [[ -f "$ENVFILE" ]] || die "missing $ENVFILE"
}

sync_missing_example_sections() {
  local section
  for section in $(toml_sections "$TOML_EXAMPLE"); do
    if toml_sections "$TOML" | grep -qxF -- "$section"; then
      continue
    fi

    {
      printf '\n'
      awk -v sec="$section" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
          cur = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
          if (cur == sec) {
            in_section = 1
            print
            next
          }
          if (in_section) exit
        }
        in_section { print }
      ' "$TOML_EXAMPLE"
    } >>"$TOML"
    log_ok "added mcp.$section to config/mcp.toml from example"
  done
}

sync_missing_example_keys() {
  local section tmp rc
  for section in $(toml_sections "$TOML_EXAMPLE"); do
    if ! toml_sections "$TOML" | grep -qxF -- "$section"; then
      continue
    fi

    tmp=$(mktemp)
    set +e
    awk -v sec="$section" '
      FNR == NR {
        if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          cur = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
          in_example = (cur == sec)
          next
        }
        if (in_example && $0 ~ /^[[:space:]]*[^#[:space:]][^=]*=/) {
          key = $0
          sub(/=.*/, "", key)
          gsub(/[[:space:]]/, "", key)
          example_count++
          example_keys[example_count] = key
          example_lines[example_count] = $0
        }
        next
      }

      function flush_target(    i, added) {
        if (!in_target) {
          return
        }
        printf "%s", target_buffer
        for (i = 1; i <= example_count; i++) {
          if (!(example_keys[i] in target_keys)) {
            print example_lines[i]
            added = 1
          }
        }
        if (added) {
          changed = 1
        }
        target_buffer = ""
        delete target_keys
        in_target = 0
      }

      {
        if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          cur = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
          if (in_target && cur != sec) {
            flush_target()
          }
          if (cur == sec) {
            in_target = 1
            target_buffer = $0 ORS
            next
          }
        }

        if (in_target) {
          target_buffer = target_buffer $0 ORS
          if ($0 ~ /^[[:space:]]*[^#[:space:]][^=]*=/) {
            key = $0
            sub(/=.*/, "", key)
            gsub(/[[:space:]]/, "", key)
            target_keys[key] = 1
          }
          next
        }

        print
      }

      END {
        flush_target()
        if (changed) {
          exit 42
        }
      }
    ' "$TOML_EXAMPLE" "$TOML" >"$tmp"
    rc=$?
    set -e

    case "$rc" in
      0)
        rm -f "$tmp"
        ;;
      42)
        mv "$tmp" "$TOML"
        log_ok "updated mcp.$section in config/mcp.toml from example"
        ;;
      *)
        rm -f "$tmp"
        die "failed to sync mcp.$section from config/mcp.toml.example"
        ;;
    esac
  done
}

enabled_mcps() {
  local s
  for s in $(toml_sections "$TOML"); do
    if toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done
}

configured_mcps_in_hermes() {
  docker exec -i hermes python3 - <<'PY' 2>/dev/null || true
import os
from pathlib import Path

import yaml

_hermes_home = os.environ.get("HERMES_HOME")
path = Path(_hermes_home) / "config.yaml" if _hermes_home else Path("/home/hermes/.hermes/config.yaml")
if not path.exists():
    raise SystemExit(0)
config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
servers = config.get("mcp_servers") or {}
if isinstance(servers, dict):
    for name in servers:
        print(name)
PY
}

disabled_mcps_to_remove() {
  local registered s
  registered=$(configured_mcps_in_hermes) || return 0
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if toml_sections "$TOML" | grep -qxF -- "$s" && ! toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done <<<"$registered"
}

check_required_env() {
  local mcp="$1"
  local missing=()
  local req
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    if ! env_var_set_in_file "$ENVFILE" "$req"; then
      missing+=("$req")
    fi
  done < <(toml_get_array "$TOML" "$mcp" requires)
  if (( ${#missing[@]} )); then
    log_warn "mcp.$mcp: missing ${missing[*]} — see docs/mcp/$mcp.md"
    return 1
  fi
  return 0
}

npm_pkg_installed() {
  # Pass package name as argv so it can't escape into shell parsing; grep -F
  # for literal matching (no regex metacharacters).
  docker exec hermes bash -c \
    'npm list -g --depth=0 2>/dev/null | grep -qF -- "$1"' _ "$1"
}

# Validate package name before we hand it to any shell — only allow npm-safe chars.
require_safe_pkg_name() {
  local pkg="$1"
  [[ "$pkg" =~ ^[@a-zA-Z0-9._/-]+$ ]] || \
    die "rejecting unsafe package name '$pkg' — must match @a-zA-Z0-9._/-"
}

join_csv() {
  local IFS=,
  printf '%s' "$*"
}

write_hermes_mcp_config() {
  local mcp="$1" transport="$2" command="$3" url="$4" env_csv="$5" auth="$6" oauth_client_id_env="$7" oauth_client_secret_env="$8" scopes_csv="$9"
  shift 9
  docker exec -i hermes python3 - "$mcp" "$transport" "$command" "$url" "$env_csv" "$auth" "$oauth_client_id_env" "$oauth_client_secret_env" "$scopes_csv" "$@" <<'PY'
import os
import sys
from pathlib import Path

import yaml

(
    name,
    transport,
    command,
    url,
    env_csv,
    auth,
    oauth_client_id_env,
    oauth_client_secret_env,
    scopes_csv,
    *cmd_args,
) = sys.argv[1:]
_hermes_home = os.environ.get("HERMES_HOME")
path = Path(_hermes_home) / "config.yaml" if _hermes_home else Path("/home/hermes/.hermes/config.yaml")
path.parent.mkdir(parents=True, exist_ok=True)

try:
    config = yaml.safe_load(path.read_text(encoding="utf-8")) if path.exists() else {}
except Exception:
    config = {}

if not isinstance(config, dict):
    config = {}

servers = config.setdefault("mcp_servers", {})
server = {"enabled": True}
if transport == "http":
    server["url"] = url
else:
    server["command"] = command
    server["args"] = cmd_args

if auth:
    server["auth"] = auth
    if auth == "oauth":
        oauth = {}
        if oauth_client_id_env:
            oauth["client_id"] = "${" + oauth_client_id_env + "}"
        if oauth_client_secret_env:
            oauth["client_secret"] = "${" + oauth_client_secret_env + "}"
        scopes = [item for item in scopes_csv.split(",") if item]
        if scopes:
            oauth["scope"] = " ".join(scopes)
        if oauth:
            server["oauth"] = oauth

env_names = [item for item in env_csv.split(",") if item]
if env_names:
    server["env"] = {item: "${" + item + "}" for item in env_names}

if servers.get(name) == server:
    raise SystemExit(2)

servers[name] = server
path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
PY
}

remove_hermes_mcp_config() {
  local mcp="$1"
  docker exec -i hermes python3 - "$mcp" <<'PY'
import os
import sys
from pathlib import Path

import yaml

name = sys.argv[1]
_hermes_home = os.environ.get("HERMES_HOME")
path = Path(_hermes_home) / "config.yaml" if _hermes_home else Path("/home/hermes/.hermes/config.yaml")
if not path.exists():
    raise SystemExit(2)

config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
servers = config.get("mcp_servers") or {}
if name not in servers:
    raise SystemExit(2)

del servers[name]
if servers:
    config["mcp_servers"] = servers
else:
    config.pop("mcp_servers", None)

path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
PY
}

deploy_stdio_mcp() {
  local mcp="$1"
  local pkg
  pkg=$(toml_get "$TOML" "$mcp" package) || die "mcp.$mcp: missing 'package'"
  require_safe_pkg_name "$pkg"

  if npm_pkg_installed "$pkg"; then
    log_skip "mcp.$mcp: $pkg already installed in hermes container"
  else
    log_act "installing $pkg in hermes container"
    docker exec hermes npm install -g "$pkg" >/dev/null
    log_ok "installed $pkg"
  fi

  # Always (re)write the Hermes config entry. write_hermes_mcp_config compares
  # against what is already there: it is a no-op (rc=2) when nothing changed, so
  # this stays idempotent while also self-healing a drifted or stale entry.
  local env_names=() cmd_args=() req env_csv rc
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    env_names+=("$req")
  done < <(toml_get_array "$TOML" "$mcp" requires)
  cmd_args=(-y "$pkg")
  if [[ "$mcp" == "filesystem" ]]; then
    local mount
    mount=$(toml_get "$TOML" "$mcp" mount) || die "mcp.$mcp: missing 'mount'"
    cmd_args+=("$mount")
  fi
  env_csv=$(join_csv "${env_names[@]}")
  set +e
  write_hermes_mcp_config "$mcp" stdio npx "" "$env_csv" "" "" "" "" "${cmd_args[@]}"
  rc=$?
  set -e
  case "$rc" in
    0) log_ok "registered mcp '$mcp'" ;;
    2) log_skip "mcp.$mcp: already up to date in hermes" ;;
    *) die "mcp.$mcp: could not write Hermes MCP config" ;;
  esac
}

deploy_http_mcp() {
  local mcp="$1"
  local url
  url=$(toml_get "$TOML" "$mcp" url 2>/dev/null || true)

  if [[ -z "$url" ]]; then
    local port service
    port=$(toml_get "$TOML" "$mcp" port) || die "mcp.$mcp: missing 'port' or 'url'"
    service="mcp-$mcp"
    url="http://$service:$port"
    if docker_container_running "$service"; then
      log_skip "mcp.$mcp: container $service already running"
    else
      log_act "starting compose service $service (profile $mcp)"
      docker compose -f "$CONFIG_DIR/docker-compose.mcp.yml" --profile "$mcp" up -d "$service" >/dev/null
      log_ok "started $service"
    fi
  fi

  # Always (re)write — idempotent no-op when unchanged, self-healing otherwise.
  local rc auth oauth_client_id_env oauth_client_secret_env scopes=() scope scopes_csv
  auth=$(toml_get "$TOML" "$mcp" auth 2>/dev/null || true)
  oauth_client_id_env=$(toml_get "$TOML" "$mcp" oauth_client_id_env 2>/dev/null || true)
  oauth_client_secret_env=$(toml_get "$TOML" "$mcp" oauth_client_secret_env 2>/dev/null || true)
  while IFS= read -r scope; do
    [[ -z "$scope" ]] && continue
    scopes+=("$scope")
  done < <(toml_get_array "$TOML" "$mcp" scopes 2>/dev/null || true)
  scopes_csv=$(join_csv "${scopes[@]}")
  set +e
  write_hermes_mcp_config "$mcp" http "" "$url" "" "$auth" "$oauth_client_id_env" "$oauth_client_secret_env" "$scopes_csv"
  rc=$?
  set -e
  case "$rc" in
    0) log_ok "registered mcp '$mcp' (http)" ;;
    2) log_skip "mcp.$mcp: already up to date in hermes" ;;
    *) die "mcp.$mcp: could not write Hermes MCP config" ;;
  esac
}

main() {
  require_files
  sync_missing_example_sections
  sync_missing_example_keys
  require_hermes_running

  local mcp
  while IFS= read -r mcp; do
    [[ -z "$mcp" ]] && continue

    if [[ "$mcp" == "docker_mcp" ]]; then
      if ! toml_get_bool "$TOML" docker_mcp acknowledge_socket_risk; then
        log_warn "mcp.docker_mcp: skipped — set acknowledge_socket_risk = true in mcp.toml to opt-in (gives the MCP root-equivalent host access via /var/run/docker.sock)"
        continue
      fi
      # Verify the hermes container actually has /var/run/docker.sock mounted
      # in — otherwise the MCP starts but every call fails with 'no such file'.
      # We don't auto-edit compose because it requires a container recreate;
      # ask the user to do it explicitly.
      if ! docker inspect -f \
          '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' hermes 2>/dev/null \
          | grep -qx '/var/run/docker.sock'; then
        log_warn "mcp.docker_mcp: skipped — /var/run/docker.sock is NOT mounted into the hermes container. Add the following under hermes.volumes in config/docker-compose.yml, then 'docker compose -f config/docker-compose.yml up -d --force-recreate':"
        log_warn "        - /var/run/docker.sock:/var/run/docker.sock"
        continue
      fi
    fi

    if ! check_required_env "$mcp"; then
      continue
    fi

    local transport
    transport=$(toml_get "$TOML" "$mcp" transport) || transport="stdio"
    case "$transport" in
      stdio) deploy_stdio_mcp "$mcp" ;;
      http)  deploy_http_mcp "$mcp" ;;
      *)     log_warn "mcp.$mcp: unknown transport '$transport' — skipping"; continue ;;
    esac

    if [[ "$(toml_get "$TOML" "$mcp" auth 2>/dev/null || true)" == "oauth" ]]; then
      log_warn "mcp.$mcp: OAuth login required — run: docker exec -it hermes hermes mcp login $mcp"
      continue
    fi

    # Smoke-test the registration. Some Hermes builds may not implement
    # `mcp test`; we treat anything other than a non-zero subcommand-missing
    # exit as informational.
    if docker exec hermes hermes mcp test "$mcp" >/dev/null 2>&1; then
      log_ok "mcp.$mcp: smoke-test passed"
    else
      log_warn "mcp.$mcp: smoke-test did not pass (mcp may still work; check 'docker exec hermes hermes mcp test $mcp' manually)"
    fi
  done < <(enabled_mcps)

  local stale rc
  while IFS= read -r stale; do
    [[ -z "$stale" ]] && continue
    log_act "unregistering mcp '$stale' (no longer enabled in mcp.toml)"
    set +e
    remove_hermes_mcp_config "$stale"
    rc=$?
    set -e
    case "$rc" in
      0) log_ok "unregistered mcp '$stale'" ;;
      2) log_skip "mcp.$stale: already absent from Hermes config" ;;
      *) die "mcp.$stale: could not update Hermes MCP config" ;;
    esac
  done < <(disabled_mcps_to_remove)

  log_ok "mcp sync complete"
}

main "$@"
