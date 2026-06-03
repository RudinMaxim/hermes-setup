#!/usr/bin/env bash
# scripts/add-skill.sh - Create a local Hermes skill and sync it into Hermes.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
TOML="$CONFIG_DIR/skills.toml"
TOML_EXAMPLE="$CONFIG_DIR/skills.toml.example"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/add-skill.sh <skill_name> [description]

Creates skills/<skill_name>/SKILL.md, adds an enabled local section to
config/skills.toml, then runs ./scripts/setup-skills.sh.
EOF
}

require_safe_skill_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]] || \
    die "rejecting unsafe skill name '$name' - must match a-zA-Z0-9_.-"
}

toml_escape() {
  local value="$1"
  [[ "$value" != *$'\n'* ]] || die "description must be a single line"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

ensure_config() {
  if [[ -f "$TOML" ]]; then
    return 0
  fi
  [[ -f "$TOML_EXAMPLE" ]] || die "missing $TOML_EXAMPLE"
  cp "$TOML_EXAMPLE" "$TOML"
  log_ok "created config/skills.toml from example"
}

create_skill_file() {
  local name="$1" description="$2" skill_dir skill_file
  skill_dir="$REPO_ROOT/skills/$name"
  skill_file="$skill_dir/SKILL.md"
  mkdir -p "$skill_dir"
  if [[ -f "$skill_file" ]]; then
    log_skip "skill.$name: SKILL.md already exists"
    return 0
  fi

  cat >"$skill_file" <<EOF
---
name: $name
description: $description
---

# $name

Describe when Hermes should use this skill and the rules it must follow.
EOF
  log_ok "created skill.$name at skills/$name/SKILL.md"
}

ensure_config_section() {
  local name="$1" description="$2" escaped_description
  escaped_description="$(toml_escape "$description")"
  if toml_sections "$TOML" | grep -qxF -- "$name"; then
    log_skip "skill.$name: already present in config/skills.toml"
    return 0
  fi

  {
    printf '\n'
    printf '[%s]\n' "$name"
    printf 'enabled = true\n'
    printf 'type = "local"\n'
    printf 'source = "skills/%s"\n' "$name"
    printf 'description = "%s"\n' "$escaped_description"
  } >>"$TOML"
  log_ok "added skill.$name to config/skills.toml"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
    usage
    [[ $# -ge 1 ]] && [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
    exit 1
  fi

  local name="$1" description="${2:-Local Hermes skill: $1}"
  require_safe_skill_name "$name"
  ensure_config
  create_skill_file "$name" "$description"
  ensure_config_section "$name" "$description"
  bash "$SCRIPT_DIR/setup-skills.sh"
}

main "$@"
