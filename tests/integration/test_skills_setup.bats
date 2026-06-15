#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  rm -f "$REPO_ROOT/config/skills.toml"
}

teardown() {
  rm -f "$REPO_ROOT/config/skills.toml"
  rm -rf "$REPO_ROOT/skills/broken"
  rm -rf /tmp/bin-stub /tmp/hermes-home /tmp/stabilized-google-workspace
  rm -f /tmp/.skills-root-exec
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
      "python3 - "*) "$@" ;;
      "python3 -") "$@" ;;
      *) echo "exec-i-stub: $*" ;;
    esac ;;
  "exec -u")
    shift 4
    printf '%s\n' "$*" >>/tmp/.skills-root-exec
    ;;
  "cp"*)
    src="$2"
    dest="$3"
    dest="${dest#hermes:}"
    mkdir -p "$dest"
    cp -a "${src%/.}/." "$dest/"
    ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
}

@test "setup-skills.sh creates skills.toml from example when missing" {
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/config/skills.toml" ]
  grep -q '^\[google_workspace\]$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"created config/skills.toml from example"* ]]
}

@test "setup-skills.sh adds new example sections to existing skills.toml" {
  cat >"$REPO_ROOT/config/skills.toml" <<'TOML'
[google_workspace]
enabled = true
type = "builtin"
description = "Stable Google Drive/Docs skill for Hermes gateway use"
stabilize = true
TOML
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
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

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  grep -q '^source = "skills/project_memory"$' "$REPO_ROOT/config/skills.toml"
  grep -q '^description = "Project-specific workflow and memory skill"$' "$REPO_ROOT/config/skills.toml"
  grep -q '^enabled = true$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"updated skill.project_memory in config/skills.toml from example"* ]]
}

@test "setup-skills.sh installs enabled local skill into Hermes skills dir" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  [ -f /tmp/hermes-home/skills/project_memory/SKILL.md ]
  [[ "$output" == *"installed skill.project_memory"* ]]
}

@test "setup-skills.sh normalizes staged ownership after docker copy" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"

  [ "$status" -eq 0 ]
  grep -q 'chown -R hermes:hermes /tmp/hermes-home/skills/.project_memory.incoming-' /tmp/.skills-root-exec
}

@test "setup-skills.sh skips unchanged local skill on second run" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill.project_memory: already up to date"* ]]
}

@test "setup-skills.sh does not install disabled local skill" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/hermes-home/skills/project_memory/SKILL.md ]
}

@test "setup-skills.sh backs up changed local skill before replacing target" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  sed -i '/^\[project_memory\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/skills.toml"
  make_docker_stub
  mkdir -p /tmp/hermes-home/skills/project_memory
  printf 'old skill\n' >/tmp/hermes-home/skills/project_memory/SKILL.md

  run env HERMES_SKILL_BACKUP_TS=20260603-120000 PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
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

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
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

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
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

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local install failed"* ]]
}

@test "setup-skills.sh runs google_workspace stabilization when configured" {
  cp "$REPO_ROOT/config/skills.toml.example" "$REPO_ROOT/config/skills.toml"
  make_docker_stub
  cat >/tmp/stabilize-google-workspace-stub.sh <<'STUB'
#!/usr/bin/env bash
touch /tmp/stabilized-google-workspace
STUB
  chmod +x /tmp/stabilize-google-workspace-stub.sh

  run env HERMES_GOOGLE_WORKSPACE_STABILIZE_SCRIPT=/tmp/stabilize-google-workspace-stub.sh PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  [ -f /tmp/stabilized-google-workspace ]
  [[ "$output" == *"stabilized skill.google_workspace"* ]]
}
