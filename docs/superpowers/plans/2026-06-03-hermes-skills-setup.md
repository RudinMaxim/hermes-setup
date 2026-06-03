# Hermes Skills Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `setup-skills.sh`, config, docs, and tests for idempotent management of local and built-in Hermes skills.

**Architecture:** Follow the existing `setup-mcp.sh` pattern: TOML config is the source of truth, setup scripts sync missing example sections/keys, and Docker stubs drive Bats coverage. Local skills are copied as directories into the Hermes data directory with validation, backups, and no-op behavior when unchanged; built-in skills call named repository stabilization flows.

**Tech Stack:** Bash, existing `scripts/lib/*.sh`, Docker CLI through stubs in tests, Python inside `docker exec` for path-safe file operations, Bats.

---

## File Map

- Create `config/skills.toml.example`: default skill configuration with `google_workspace` enabled and one disabled local example.
- Create `skills/project_memory/SKILL.md`: small local example skill used by docs and tests.
- Create `scripts/setup-skills.sh`: idempotent skills sync entrypoint.
- Modify `scripts/setup.sh`: call `setup-skills.sh` after MCP sync and before gateway sync.
- Modify `scripts/update.sh`: call `setup-skills.sh` during re-sync.
- Create `tests/integration/test_skills_setup.bats`: end-to-end script behavior with `docker` and stabilization stubs.
- Modify `README.md`: mention skills config and command.
- Create `docs/skills/README.md`: user-facing guide for local and built-in skills.

## Task 1: Config And Example Skill

**Files:**
- Create: `config/skills.toml.example`
- Create: `skills/project_memory/SKILL.md`
- Test: `tests/integration/test_skills_setup.bats`

- [ ] **Step 1: Write the failing config creation test**

Create `tests/integration/test_skills_setup.bats`:

```bash
#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  rm -f "$REPO_ROOT/config/skills.toml"
  chown -R hermes:hermes "$REPO_ROOT/config"
}

teardown() {
  rm -f "$REPO_ROOT/config/skills.toml"
  rm -rf /tmp/bin-stub /tmp/hermes-home /tmp/stabilized-google-workspace
}

make_docker_stub() {
  mkdir -p /tmp/bin-stub /tmp/hermes-home
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "printenv HERMES_HOME") echo /tmp/hermes-home ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  "exec -i")
    shift 3
    case "$*" in
      "python3 - "*) python3 - "$@" ;;
      "python3 -") python3 - ;;
      *) echo "exec-i-stub: $*" ;;
    esac ;;
  "cp"*) echo "cp-stub: $*" ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
}

@test "setup-skills.sh creates skills.toml from example when missing" {
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/config/skills.toml" ]
  grep -q '^\[google_workspace\]$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"created config/skills.toml from example"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: FAIL because `scripts/setup-skills.sh` and `config/skills.toml.example` do not exist.

- [ ] **Step 3: Add config and example local skill**

Create `config/skills.toml.example`:

```toml
# config/skills.toml.example
# Copy to config/skills.toml. Built-in Google Workspace stabilization is enabled
# by default because it supports the documented stable Telegram flow.

[google_workspace]
enabled = true
type = "builtin"
description = "Stable Google Drive/Docs skill for Hermes gateway use"
stabilize = true

[project_memory]
enabled = false
type = "local"
source = "skills/project_memory"
description = "Project-specific workflow and memory skill"
```

Create `skills/project_memory/SKILL.md`:

```markdown
---
name: project_memory
description: Project-specific Hermes workflow and memory conventions.
---

# Project Memory

Use this skill to keep Hermes aligned with the local `hermes-setup` repository
workflow. Prefer idempotent scripts, config-as-source, and explicit verification
commands before reporting setup work as complete.
```

- [ ] **Step 4: Add minimal `setup-skills.sh` skeleton**

Create `scripts/setup-skills.sh`:

```bash
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

main() {
  require_example
  ensure_config
  require_hermes_running
  log_ok "skills sync complete"
}

main "$@"
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add config/skills.toml.example skills/project_memory/SKILL.md scripts/setup-skills.sh tests/integration/test_skills_setup.bats
git commit -m "feat(skills): add skills config scaffold"
```

## Task 2: Sync Missing Example Sections And Keys

**Files:**
- Modify: `scripts/setup-skills.sh`
- Test: `tests/integration/test_skills_setup.bats`

- [ ] **Step 1: Add failing tests for section/key sync**

Append to `tests/integration/test_skills_setup.bats`:

```bash
@test "setup-skills.sh adds new example sections to existing skills.toml" {
  cat >"$REPO_ROOT/config/skills.toml" <<'TOML'
[google_workspace]
enabled = true
type = "builtin"
description = "Stable Google Drive/Docs skill for Hermes gateway use"
stabilize = true
TOML
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  grep -q '^\[project_memory\]$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"added skill.project_memory to config/skills.toml from example"* ]]
}

@test "setup-skills.sh fills missing keys without overwriting user values" {
  cat >"$REPO_ROOT/config/skills.toml" <<'TOML'
[project_memory]
enabled = true
type = "local"
TOML
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  grep -q '^source = "skills/project_memory"$' "$REPO_ROOT/config/skills.toml"
  grep -q '^description = "Project-specific workflow and memory skill"$' "$REPO_ROOT/config/skills.toml"
  grep -q '^enabled = true$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"updated skill.project_memory in config/skills.toml from example"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: new tests FAIL because `setup-skills.sh` does not sync sections or keys yet.

- [ ] **Step 3: Implement `sync_missing_example_sections` and `sync_missing_example_keys`**

Add to `scripts/setup-skills.sh` after `ensure_config`:

```bash
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
      0) rm -f "$tmp" ;;
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
```

Update `main()`:

```bash
main() {
  require_example
  ensure_config
  sync_missing_example_sections
  sync_missing_example_keys
  require_hermes_running
  log_ok "skills sync complete"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-skills.sh tests/integration/test_skills_setup.bats
git commit -m "feat(skills): sync skills config from example"
```

## Task 3: Local Skill Validation And Copy

**Files:**
- Modify: `scripts/setup-skills.sh`
- Test: `tests/integration/test_skills_setup.bats`

- [ ] **Step 1: Add failing tests for local skill install, idempotency, and disabled behavior**

Append:

```bash
@test "setup-skills.sh installs enabled local skill into Hermes skills dir" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  [ -f /tmp/hermes-home/skills/project_memory/SKILL.md ]
  [[ "$output" == *"installed skill.project_memory"* ]]
}

@test "setup-skills.sh skips unchanged local skill on second run" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill.project_memory: already up to date"* ]]
}

@test "setup-skills.sh does not install disabled local skill" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/hermes-home/skills/project_memory/SKILL.md ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: local install tests FAIL because local skill deployment is not implemented.

- [ ] **Step 3: Implement enabled skill loop and local deploy**

Add helpers to `scripts/setup-skills.sh`:

```bash
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

deploy_local_skill() {
  local skill="$1" source rel_home
  require_safe_skill_name "$skill"
  source=$(toml_get "$TOML" "$skill" source) || die "skill.$skill: missing 'source'"
  rel_home=$(resolve_hermes_home)

  docker exec -i hermes python3 - "$REPO_ROOT" "$source" "$rel_home" "$skill" <<'PY'
import filecmp
import os
import shutil
import sys
import tempfile
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
source_value = sys.argv[2]
hermes_home = Path(sys.argv[3])
skill = sys.argv[4]

if Path(source_value).is_absolute() or ".." in Path(source_value).parts:
    print(f"rejecting unsafe source path '{source_value}'", file=sys.stderr)
    raise SystemExit(10)

src = (repo_root / source_value).resolve()
if repo_root not in src.parents and src != repo_root:
    print(f"source path escapes repository: {source_value}", file=sys.stderr)
    raise SystemExit(11)
if not src.is_dir():
    print(f"skill.{skill}: source directory not found: {source_value}", file=sys.stderr)
    raise SystemExit(12)
if not (src / "SKILL.md").is_file():
    print(f"skill.{skill}: missing SKILL.md", file=sys.stderr)
    raise SystemExit(13)

for path in src.rglob("*"):
    if path.is_symlink():
      resolved = path.resolve()
      if repo_root not in resolved.parents and resolved != repo_root:
          print(f"skill.{skill}: symlink escapes repository: {path}", file=sys.stderr)
          raise SystemExit(14)

target_root = hermes_home / "skills"
target = target_root / skill
if target_root.resolve() not in target.resolve().parents:
    print(f"skill.{skill}: target escapes skills directory", file=sys.stderr)
    raise SystemExit(15)

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

target_root.mkdir(parents=True, exist_ok=True)
if same_tree(src, target):
    raise SystemExit(2)

tmp_parent = target_root
tmp = Path(tempfile.mkdtemp(prefix=f".{skill}.tmp-", dir=tmp_parent))
staged = tmp / skill
try:
    shutil.copytree(src, staged, symlinks=False)
    if target.exists():
        backup_root = hermes_home / "backups" / "skills" / skill
        backup_root.mkdir(parents=True, exist_ok=True)
        backup = backup_root / os.environ.get("HERMES_SKILL_BACKUP_TS", "")
        if not backup.name:
            from datetime import datetime
            backup = backup_root / datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        shutil.copytree(target, backup)
        shutil.rmtree(target)
    os.replace(staged, target)
finally:
    if tmp.exists():
        shutil.rmtree(tmp)
PY
}
```

Add to `main()` after `require_hermes_running`:

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS for local install/idempotency/disabled tests.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-skills.sh tests/integration/test_skills_setup.bats
git commit -m "feat(skills): install local skills idempotently"
```

## Task 4: Backup And Unsafe Path Rejection

**Files:**
- Modify: `scripts/setup-skills.sh`
- Test: `tests/integration/test_skills_setup.bats`

- [ ] **Step 1: Add failing tests for backup and validation**

Append:

```bash
@test "setup-skills.sh backs up changed local skill before replacing target" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub
  mkdir -p /tmp/hermes-home/skills/project_memory
  printf 'old skill\n' >/tmp/hermes-home/skills/project_memory/SKILL.md

  run su hermes -c "HERMES_SKILL_BACKUP_TS=20260603-120000 PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -eq 0 ]
  [ -f /tmp/hermes-home/backups/skills/project_memory/20260603-120000/SKILL.md ]
  grep -q 'old skill' /tmp/hermes-home/backups/skills/project_memory/20260603-120000/SKILL.md
  grep -q 'Project Memory' /tmp/hermes-home/skills/project_memory/SKILL.md
}

@test "setup-skills.sh rejects unsafe skill name" {
  cat >"$REPO_ROOT/config/skills.toml" <<'TOML'
[../bad]
enabled = true
type = "local"
source = "skills/project_memory"
description = "Bad"
TOML
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejecting unsafe skill name"* ]]
}

@test "setup-skills.sh rejects unsafe source path" {
  cat >"$REPO_ROOT/config/skills.toml" <<'TOML'
[project_memory]
enabled = true
type = "local"
source = "../outside"
description = "Bad"
TOML
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local install failed"* ]]
}

@test "setup-skills.sh rejects local skill without SKILL.md" {
  mkdir -p "$REPO_ROOT/skills/broken"
  cat >"$REPO_ROOT/config/skills.toml" <<'TOML'
[broken]
enabled = true
type = "local"
source = "skills/broken"
description = "Broken"
TOML
  make_docker_stub

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local install failed"* ]]
  rm -rf "$REPO_ROOT/skills/broken"
}
```

- [ ] **Step 2: Run tests**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS if Task 3 implementation already included backup and validation. If any test fails, fix the corresponding branch in `deploy_local_skill`.

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-skills.sh tests/integration/test_skills_setup.bats
git commit -m "test(skills): cover backup and path validation"
```

## Task 5: Built-In Google Workspace Handler

**Files:**
- Modify: `scripts/setup-skills.sh`
- Test: `tests/integration/test_skills_setup.bats`

- [ ] **Step 1: Add failing test for built-in stabilization**

Append:

```bash
@test "setup-skills.sh runs google_workspace stabilization when configured" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  make_docker_stub
  mv "$SCRIPTS/stabilize-google-workspace.sh" "$SCRIPTS/stabilize-google-workspace.sh.real"
  cat >"$SCRIPTS/stabilize-google-workspace.sh" <<'STUB'
#!/usr/bin/env bash
touch /tmp/stabilized-google-workspace
STUB
  chmod +x "$SCRIPTS/stabilize-google-workspace.sh"

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-skills.sh'"
  local rc="$status"
  mv "$SCRIPTS/stabilize-google-workspace.sh.real" "$SCRIPTS/stabilize-google-workspace.sh"
  [ "$rc" -eq 0 ]
  [ -f /tmp/stabilized-google-workspace ]
  [[ "$output" == *"stabilized skill.google_workspace"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: new test FAIL because builtin handler only skips.

- [ ] **Step 3: Implement built-in handler**

Add to `scripts/setup-skills.sh`:

```bash
deploy_builtin_skill() {
  local skill="$1"
  require_safe_skill_name "$skill"
  case "$skill" in
    google_workspace)
      if toml_get_bool "$TOML" "$skill" stabilize; then
        if bash "$SCRIPT_DIR/stabilize-google-workspace.sh"; then
          log_ok "stabilized skill.google_workspace"
        else
          log_warn "skill.google_workspace: stabilization did not complete; run CLI OAuth first if needed"
        fi
      else
        log_skip "skill.google_workspace: stabilize=false"
      fi
      ;;
    *)
      log_warn "skill.$skill: no builtin handler - skipping"
      ;;
  esac
}
```

Replace the builtin case in `main()`:

```bash
      builtin)
        deploy_builtin_skill "$skill"
        ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-skills.sh tests/integration/test_skills_setup.bats
git commit -m "feat(skills): stabilize builtin Google Workspace skill"
```

## Task 6: Orchestrator Integration

**Files:**
- Modify: `scripts/setup.sh`
- Modify: `scripts/update.sh`
- Test: existing integration tests plus direct syntax checks

- [ ] **Step 1: Modify `scripts/setup.sh`**

Insert after MCP sync:

```bash
  log_act "setting up skills"
  bash "$SCRIPT_DIR/setup-skills.sh" "${PASSTHRU[@]}"
```

Keep gateway sync after skills.

- [ ] **Step 2: Modify `scripts/update.sh`**

Insert after MCP re-sync:

```bash
  log_act "re-syncing skills"
  bash "$SCRIPT_DIR/setup-skills.sh" "${PASSTHRU[@]}"
```

Keep gateway re-sync after skills.

- [ ] **Step 3: Run syntax checks**

Run:

```bash
bash -n scripts/setup.sh scripts/update.sh scripts/setup-skills.sh
```

Expected: exit 0.

- [ ] **Step 4: Run relevant tests**

Run:

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup.sh scripts/update.sh scripts/setup-skills.sh
git commit -m "feat(skills): wire skills sync into setup flows"
```

## Task 7: Documentation

**Files:**
- Modify: `README.md`
- Create: `docs/skills/README.md`

- [ ] **Step 1: Update README**

Add to "Что делает репозиторий":

```markdown
- Синхронизирует локальные и встроенные Hermes skills через `config/skills.toml`; внешние skill-источники в v1 не скачиваются.
```

Add to "Частые команды":

```bash
./scripts/setup-skills.sh                 # синхронизировать локальные и встроенные Hermes skills
```

Add to "Документация":

```markdown
- [`docs/skills/README.md`](docs/skills/README.md) — настройка локальных и встроенных Hermes skills.
```

Update "Структура":

```text
skills/    локальные Hermes skills, синхронизируемые через setup-skills.sh
```

- [ ] **Step 2: Create `docs/skills/README.md`**

```markdown
# Hermes Skills

`scripts/setup-skills.sh` синхронизирует skills, описанные в
`config/skills.toml`.

## Типы skills

- `builtin` — навык уже есть внутри Hermes; скрипт только запускает известную
  стабилизацию или проверку.
- `local` — навык лежит в этом репозитории и копируется в Hermes data volume.

Внешние источники GitHub, npm, URL и marketplace в v1 не поддерживаются.

## Локальные skills

Локальный навык должен лежать в директории:

```text
skills/<name>/SKILL.md
```

Пример:

```toml
[project_memory]
enabled = true
type = "local"
source = "skills/project_memory"
description = "Project-specific workflow and memory skill"
```

Повторный запуск `setup-skills.sh` ничего не переписывает, если содержимое уже
совпадает. Если установленный навык отличается, старая версия сохраняется в:

```text
<HERMES_HOME>/backups/skills/<name>/<timestamp>/
```

`enabled = false` означает "не устанавливать и не обновлять". Скрипт не удаляет
уже установленный навык автоматически.

## Google Workspace

`google_workspace` — built-in skill для стабильного доступа к Google Drive/Docs
через Telegram gateway.

```toml
[google_workspace]
enabled = true
type = "builtin"
stabilize = true
```

Когда `stabilize = true`, `setup-skills.sh` запускает
`scripts/stabilize-google-workspace.sh`. Если OAuth ещё не выполнен через Hermes
CLI, скрипт напечатает предупреждение и не будет ломать весь setup.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/skills/README.md
git commit -m "docs(skills): document skills setup"
```

## Task 8: Final Verification

**Files:**
- Verify all changed files

- [ ] **Step 1: Run syntax checks**

```bash
bash -n scripts/setup-skills.sh scripts/setup.sh scripts/update.sh
```

Expected: exit 0.

- [ ] **Step 2: Run focused integration tests**

```bash
bats tests/integration/test_skills_setup.bats
```

Expected: PASS.

- [ ] **Step 3: Run existing MCP integration smoke**

```bash
bats tests/integration/test_mcp_setup.bats
```

Expected: PASS.

- [ ] **Step 4: Check git status**

```bash
git status --short
```

Expected: clean working tree after all task commits.
