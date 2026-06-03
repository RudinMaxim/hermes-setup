#!/usr/bin/env bash
# scripts/setup-skills.sh - Idempotently sync Hermes skills based on config/skills.toml.
# Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
TOML="$CONFIG_DIR/skills.toml"
TOML_EXAMPLE="$CONFIG_DIR/skills.toml.example"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_hermes_running() {
  if ! docker_container_running hermes; then
    die "hermes container is not running - run scripts/setup-hermes.sh first"
  fi
}

require_example() {
  [[ -f "$TOML_EXAMPLE" ]] || die "missing $TOML_EXAMPLE"
}

ensure_config() {
  if [[ -f "$TOML" ]]; then
    return 0
  fi
  cp "$TOML_EXAMPLE" "$TOML"
  log_ok "created config/skills.toml from example"
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
    log_ok "added skill.$section to config/skills.toml from example"
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
        log_ok "updated skill.$section in config/skills.toml from example"
        ;;
      *)
        rm -f "$tmp"
        die "failed to sync skill.$section from config/skills.toml.example"
        ;;
    esac
  done
}

enabled_skills() {
  local s
  for s in $(toml_sections "$TOML"); do
    if toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done
}

require_safe_skill_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]] || \
    die "rejecting unsafe skill name '$name' - must match a-zA-Z0-9_.-"
}

resolve_hermes_home() {
  docker exec hermes printenv HERMES_HOME 2>/dev/null || printf '/home/hermes/.hermes\n'
}

resolve_local_source() {
  local source="$1"
  python3 - "$REPO_ROOT" "$source" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
source_value = sys.argv[2]
source_path = Path(source_value)

if source_path.is_absolute() or ".." in source_path.parts:
    print(f"rejecting unsafe source path '{source_value}'", file=sys.stderr)
    raise SystemExit(10)

src = (repo_root / source_value).resolve()
if repo_root not in src.parents and src != repo_root:
    print(f"source path escapes repository: {source_value}", file=sys.stderr)
    raise SystemExit(11)
if not src.is_dir():
    print(f"source directory not found: {source_value}", file=sys.stderr)
    raise SystemExit(12)
if not (src / "SKILL.md").is_file():
    print("missing SKILL.md", file=sys.stderr)
    raise SystemExit(13)

for path in src.rglob("*"):
    if path.is_symlink():
        resolved = path.resolve()
        if repo_root not in resolved.parents and resolved != repo_root:
            print(f"symlink escapes repository: {path}", file=sys.stderr)
            raise SystemExit(14)

print(src)
PY
}

prepare_container_stage() {
  local hermes_home="$1" skill="$2" staged="$3"
  docker exec -i hermes python3 - "$hermes_home" "$skill" "$staged" <<'PY'
import shutil
import sys
from pathlib import Path

hermes_home = Path(sys.argv[1])
skill = sys.argv[2]
staged = Path(sys.argv[3])
target_root = hermes_home / "skills"

target = target_root / skill
if target_root.resolve() not in target.resolve().parents:
    print(f"skill.{skill}: target escapes skills directory", file=sys.stderr)
    raise SystemExit(15)
if target_root.resolve() not in staged.resolve().parents:
    print(f"skill.{skill}: staged path escapes skills directory", file=sys.stderr)
    raise SystemExit(16)

if staged.exists():
    shutil.rmtree(staged)
staged.mkdir(parents=True)
PY
}

finalize_container_stage() {
  local hermes_home="$1" skill="$2" staged="$3"
  docker exec -i hermes python3 - "$hermes_home" "$skill" "$staged" <<'PY'
import filecmp
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

hermes_home = Path(sys.argv[1])
skill = sys.argv[2]
staged = Path(sys.argv[3])
target_root = hermes_home / "skills"
target = target_root / skill

if target_root.resolve() not in target.resolve().parents:
    print(f"skill.{skill}: target escapes skills directory", file=sys.stderr)
    raise SystemExit(15)
if target_root.resolve() not in staged.resolve().parents:
    print(f"skill.{skill}: staged path escapes skills directory", file=sys.stderr)
    raise SystemExit(16)
if not (staged / "SKILL.md").is_file():
    print(f"skill.{skill}: staged copy missing SKILL.md", file=sys.stderr)
    raise SystemExit(17)

def same_tree(left: Path, right: Path) -> bool:
    if not right.exists():
        return False
    cmp = filecmp.dircmp(left, right)
    if cmp.left_only or cmp.right_only or cmp.funny_files:
        return False
    for name in cmp.common_files:
        if not filecmp.cmp(left / name, right / name, shallow=False):
            return False
    return all(same_tree(left / name, right / name) for name in cmp.common_dirs)

try:
    if same_tree(staged, target):
        shutil.rmtree(staged)
        raise SystemExit(2)

    if target.exists():
        backup_root = hermes_home / "backups" / "skills" / skill
        backup_root.mkdir(parents=True, exist_ok=True)
        backup_name = os.environ.get("HERMES_SKILL_BACKUP_TS") or datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        backup = backup_root / backup_name
        shutil.copytree(target, backup)
        shutil.rmtree(target)

    os.replace(staged, target)
finally:
    if staged.exists():
        shutil.rmtree(staged)
PY
}

deploy_local_skill() {
  local skill="$1" source src hermes_home staged
  require_safe_skill_name "$skill"
  source=$(toml_get "$TOML" "$skill" source) || die "skill.$skill: missing 'source'"
  src=$(resolve_local_source "$source") || return 1
  hermes_home=$(resolve_hermes_home)
  staged="$hermes_home/skills/.$skill.incoming-$$"

  prepare_container_stage "$hermes_home" "$skill" "$staged" || return 1
  docker cp "$src/." "hermes:$staged/" || return 1
  finalize_container_stage "$hermes_home" "$skill" "$staged"
}

main() {
  require_example
  ensure_config
  sync_missing_example_sections
  sync_missing_example_keys
  require_hermes_running

  local skill type rc
  while IFS= read -r skill; do
    [[ -z "$skill" ]] && continue
    type=$(toml_get "$TOML" "$skill" type) || die "skill.$skill: missing 'type'"
    case "$type" in
      local)
        set +e
        deploy_local_skill "$skill"
        rc=$?
        set -e
        case "$rc" in
          0) log_ok "installed skill.$skill" ;;
          2) log_skip "skill.$skill: already up to date" ;;
          *) die "skill.$skill: local install failed" ;;
        esac
        ;;
      builtin)
        log_skip "skill.$skill: builtin handler not implemented yet"
        ;;
      *)
        log_warn "skill.$skill: unknown type '$type' - skipping"
        ;;
    esac
  done < <(enabled_skills)

  log_ok "skills sync complete"
}

main "$@"
