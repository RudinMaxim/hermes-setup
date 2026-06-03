#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  rm -f "$REPO_ROOT/config/skills.toml"
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

  run env PATH="/tmp/bin-stub:$PATH" bash "$SCRIPTS/setup-skills.sh"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/config/skills.toml" ]
  grep -q '^\[google_workspace\]$' "$REPO_ROOT/config/skills.toml"
  [[ "$output" == *"created config/skills.toml from example"* ]]
}
