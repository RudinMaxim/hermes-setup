#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  rm -f "$REPO_ROOT/config/skills.toml"
  rm -rf "$REPO_ROOT/skills/auto_demo" "$REPO_ROOT/skills/existing_skill"
}

teardown() {
  rm -f "$REPO_ROOT/config/skills.toml"
  rm -rf "$REPO_ROOT/skills/auto_demo" "$REPO_ROOT/skills/existing_skill"
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
      "python3 - "*) "$@" ;;
      "python3 -") "$@" ;;
      *) echo "exec-i-stub: $*" ;;
    esac ;;
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

@test "add-skill.sh creates local skill config and syncs it into Hermes" {
  make_docker_stub

  run env HERMES_GOOGLE_WORKSPACE_STABILIZE_SCRIPT=/tmp/missing-stabilize PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/add-skill.sh" auto_demo "Auto demo skill"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/skills/auto_demo/SKILL.md" ]
  grep -q '^name: auto_demo$' "$REPO_ROOT/skills/auto_demo/SKILL.md"
  grep -q '^\[auto_demo\]$' "$REPO_ROOT/config/skills.toml"
  grep -q '^enabled = true$' "$REPO_ROOT/config/skills.toml"
  grep -q '^type = "local"$' "$REPO_ROOT/config/skills.toml"
  grep -q '^source = "skills/auto_demo"$' "$REPO_ROOT/config/skills.toml"
  [ -f /tmp/hermes-home/skills/auto_demo/SKILL.md ]
  [[ "$output" == *"created skill.auto_demo"* ]]
  [[ "$output" == *"installed skill.auto_demo"* ]]
}

@test "add-skill.sh rejects unsafe skill name" {
  make_docker_stub

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/add-skill.sh" "../bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejecting unsafe skill name"* ]]
  [ ! -e "$REPO_ROOT/skills/../bad" ]
}

@test "add-skill.sh does not overwrite an existing SKILL.md" {
  make_docker_stub
  mkdir -p "$REPO_ROOT/skills/existing_skill"
  printf 'keep me\n' >"$REPO_ROOT/skills/existing_skill/SKILL.md"

  run env HERMES_GOOGLE_WORKSPACE_STABILIZE_SCRIPT=/tmp/missing-stabilize PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/add-skill.sh" existing_skill "Existing skill"
  [ "$status" -eq 0 ]
  grep -qx 'keep me' "$REPO_ROOT/skills/existing_skill/SKILL.md"
  grep -q '^\[existing_skill\]$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"skill.existing_skill: SKILL.md already exists"* ]]
}
