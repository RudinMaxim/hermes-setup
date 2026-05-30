# Hermes Setup Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three idempotent bash scripts (`setup-server.sh`, `setup-hermes.sh`, `setup-mcp.sh`) that install Hermes Agent on a Linux VPS via Docker plus a dev-stack of MCP servers, with manual instructions for everything that can't be automated. All scripts verified by Bats tests inside a systemd-enabled Docker sandbox.

**Architecture:** State-check idempotency (no marker files — each step queries the real system before acting). Three scripts share a tiny `scripts/lib/` (logging, common state-checks, atomic file writes, minimal TOML parser). Config-driven MCP management via `config/mcp.toml`. Tests run inside `jrei/systemd-ubuntu:22.04` with `--privileged` so systemd/sshd/ufw work.

**Tech Stack:** Bash 5 (strict mode), Docker + Docker Compose v2, Bats-core for tests, awk for TOML parsing, `jrei/systemd-ubuntu` test image.

**Reference spec:** `docs/superpowers/specs/2026-05-30-hermes-setup-design.md`

---

## Task 0: Repository skeleton

**Files:**
- Create: `.gitignore`, `scripts/lib/.gitkeep`, `config/.gitkeep`, `tests/unit/.gitkeep`, `tests/integration/.gitkeep`, `tests/helpers/.gitkeep`, `docker/.gitkeep`, `docs/mcp/.gitkeep`
- Create: `Makefile`

- [ ] **Step 1: Create directory tree and .gitignore**

```bash
mkdir -p scripts/lib config docker tests/unit tests/integration tests/helpers docs/mcp
touch scripts/lib/.gitkeep config/.gitkeep docker/.gitkeep \
      tests/unit/.gitkeep tests/integration/.gitkeep tests/helpers/.gitkeep \
      docs/mcp/.gitkeep
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
# Local secrets / state
config/.env
config/mcp.toml

# Test artifacts
tests/.bats-tmp/
*.log

# Editors
.vscode/
.idea/
```

- [ ] **Step 3: Write `Makefile`**

```makefile
.PHONY: help test test-unit test-integration test-image clean

help:
	@echo "test            - run unit + integration tests"
	@echo "test-unit       - run bats unit tests on host"
	@echo "test-integration - run integration tests in Docker sandbox"
	@echo "test-image      - rebuild the test sandbox image"
	@echo "clean           - remove test artifacts"

test: test-unit test-integration

test-unit:
	bats tests/unit

test-image:
	docker build -t hermes-setup-test -f tests/Dockerfile.ubuntu-systemd .

test-integration: test-image
	bash tests/run-tests.sh

clean:
	rm -rf tests/.bats-tmp
```

- [ ] **Step 4: Verify and commit**

```bash
ls -la scripts/lib config docker tests
git add -A
git commit -m "chore: scaffold hermes-setup repository skeleton

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 1: `lib/log.sh` (logging primitives)

**Files:**
- Create: `scripts/lib/log.sh`
- Test: `tests/unit/test_log.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_log.bats
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
}

@test "log_ok prefixes with [OK]" {
  run log_ok "user created"
  [ "$status" -eq 0 ]
  [[ "$output" == "[OK] user created" ]]
}

@test "log_skip prefixes with [SKIP]" {
  run log_skip "already exists"
  [ "$status" -eq 0 ]
  [[ "$output" == "[SKIP] already exists" ]]
}

@test "log_act prefixes with [ACT]" {
  run log_act "creating user"
  [ "$status" -eq 0 ]
  [[ "$output" == "[ACT] creating user" ]]
}

@test "log_warn prefixes with [WARN] and goes to stderr" {
  run bash -c "source '$LIB/log.sh'; log_warn 'be careful' 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == "[WARN] be careful" ]]
}

@test "die prints [ERR] to stderr and exits 1" {
  run bash -c "source '$LIB/log.sh'; die 'fatal'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERR] fatal"* ]]
}

@test "die accepts custom exit code" {
  run bash -c "source '$LIB/log.sh'; die 'fatal' 42"
  [ "$status" -eq 42 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_log.bats`
Expected: FAIL (file scripts/lib/log.sh does not exist)

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/log.sh
# shellcheck shell=bash

log_ok()   { printf '[OK] %s\n' "$*"; }
log_skip() { printf '[SKIP] %s\n' "$*"; }
log_act()  { printf '[ACT] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }

die() {
  local msg="$1"
  local code="${2:-1}"
  printf '[ERR] %s\n' "$msg" >&2
  exit "$code"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_log.bats`
Expected: 6 passing

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/log.sh tests/unit/test_log.bats
git commit -m "feat(lib): add log.sh primitives (ok/skip/act/warn/die)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `lib/checks.sh` (state-check predicates)

**Files:**
- Create: `scripts/lib/checks.sh`
- Test: `tests/unit/test_checks.bats`

These are pure-bash predicates that wrap common system queries. Each returns 0/1 — no logging, no side effects.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_checks.bats
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/checks.sh"
}

@test "has_command returns 0 for existing command" {
  run has_command bash
  [ "$status" -eq 0 ]
}

@test "has_command returns 1 for missing command" {
  run has_command definitely-not-a-real-command-xyz
  [ "$status" -eq 1 ]
}

@test "has_user returns 0 for existing user (root)" {
  run has_user root
  [ "$status" -eq 0 ]
}

@test "has_user returns 1 for missing user" {
  run has_user no-such-user-xyz
  [ "$status" -eq 1 ]
}

@test "user_in_group returns 1 when user not in group" {
  run user_in_group root nobody
  [ "$status" -eq 1 ]
}

@test "env_var_set_in_file returns 0 when KEY has value" {
  local tmp; tmp=$(mktemp)
  echo "FOO=bar" > "$tmp"
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file returns 1 when KEY empty" {
  local tmp; tmp=$(mktemp)
  echo "FOO=" > "$tmp"
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file returns 1 when KEY absent" {
  local tmp; tmp=$(mktemp)
  echo "BAR=baz" > "$tmp"
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}

@test "env_var_set_in_file ignores comments and surrounding whitespace" {
  local tmp; tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
# FOO=commented_out
   FOO=actual
EOF
  run env_var_set_in_file "$tmp" FOO
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_checks.bats`
Expected: FAIL (scripts/lib/checks.sh does not exist)

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/checks.sh
# shellcheck shell=bash

has_command() {
  command -v "$1" &>/dev/null
}

has_user() {
  id -u "$1" &>/dev/null
}

user_in_group() {
  local user="$1" group="$2"
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"
}

is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

systemd_unit_enabled() {
  systemctl is-enabled "$1" &>/dev/null
}

systemd_unit_active() {
  systemctl is-active "$1" &>/dev/null
}

docker_image_present() {
  docker image inspect "$1" &>/dev/null
}

docker_container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

docker_container_running() {
  [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]
}

docker_volume_present() {
  docker volume inspect "$1" &>/dev/null
}

env_var_set_in_file() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  # Match: optional leading whitespace, KEY=NONEMPTY (not just whitespace)
  grep -qE "^[[:space:]]*${key}=[^[:space:]].*\$" "$file"
}

ufw_rule_present() {
  ufw status verbose 2>/dev/null | grep -qE "$1"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_checks.bats`
Expected: 9 passing

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/checks.sh tests/unit/test_checks.bats
git commit -m "feat(lib): add state-check predicates

Pure-bash predicates wrapping system queries: users, groups, packages,
systemd units, Docker resources, env vars in files, UFW rules. No side
effects — each returns 0/1.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `lib/write_file.sh` (atomic, diff-aware file writes)

**Files:**
- Create: `scripts/lib/write_file.sh`
- Test: `tests/unit/test_write_file.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_write_file.bats
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
  # shellcheck source=/dev/null
  source "$LIB/write_file.sh"
  TMPDIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "write_file_idempotent creates file with mode 0644" {
  local target="$TMPDIR/out.conf"
  run write_file_idempotent "$target" "hello"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [[ "$(cat "$target")" == "hello" ]]
  [[ "$(stat -c '%a' "$target")" == "644" ]]
}

@test "write_file_idempotent skips when content matches" {
  local target="$TMPDIR/out.conf"
  write_file_idempotent "$target" "hello"
  local mtime1; mtime1=$(stat -c '%Y' "$target")
  sleep 1
  run write_file_idempotent "$target" "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SKIP]"* ]]
  local mtime2; mtime2=$(stat -c '%Y' "$target")
  [[ "$mtime1" == "$mtime2" ]]
}

@test "write_file_idempotent overwrites when content differs" {
  local target="$TMPDIR/out.conf"
  write_file_idempotent "$target" "hello"
  run write_file_idempotent "$target" "goodbye"
  [ "$status" -eq 0 ]
  [[ "$(cat "$target")" == "goodbye" ]]
}

@test "write_file_idempotent honors custom mode" {
  local target="$TMPDIR/secret.conf"
  run write_file_idempotent "$target" "secret-content" 0600
  [ "$status" -eq 0 ]
  [[ "$(stat -c '%a' "$target")" == "600" ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_write_file.bats`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/write_file.sh
# shellcheck shell=bash
# Requires log.sh sourced beforehand.

write_file_idempotent() {
  local target="$1"
  local content="$2"
  local mode="${3:-0644}"
  local tmp
  tmp=$(mktemp)
  printf '%s' "$content" >"$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log_skip "file $target already up-to-date"
    return 0
  fi
  install -m "$mode" "$tmp" "$target"
  rm -f "$tmp"
  log_ok "wrote $target"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_write_file.bats`
Expected: 4 passing

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/write_file.sh tests/unit/test_write_file.bats
git commit -m "feat(lib): add write_file_idempotent (atomic + diff-skip)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: `lib/toml.sh` (minimal TOML reader for mcp.toml)

**Files:**
- Create: `scripts/lib/toml.sh`
- Test: `tests/unit/test_toml.bats`

Scope is intentionally narrow: only the subset used by `mcp.toml` — sections, scalar strings, booleans, string-arrays. No nested tables, no inline tables, no datetimes.

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/test_toml.bats
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/toml.sh"
  TMP=$(mktemp)
  cat >"$TMP" <<'EOF'
# comment
[github]
enabled = true
description = "репозитории, PR, issues"
transport = "stdio"
package = "@modelcontextprotocol/server-github"
requires = ["GITHUB_TOKEN"]

[playwright]
enabled = false
transport = "http"
port = 9001
requires = []
EOF
}

teardown() {
  rm -f "$TMP"
}

@test "toml_sections lists every [section]" {
  run toml_sections "$TMP"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "github" ]]
  [[ "${lines[1]}" == "playwright" ]]
}

@test "toml_get reads string value" {
  run toml_get "$TMP" github transport
  [ "$status" -eq 0 ]
  [[ "$output" == "stdio" ]]
}

@test "toml_get reads quoted string with special chars" {
  run toml_get "$TMP" github package
  [ "$status" -eq 0 ]
  [[ "$output" == "@modelcontextprotocol/server-github" ]]
}

@test "toml_get reads integer" {
  run toml_get "$TMP" playwright port
  [ "$status" -eq 0 ]
  [[ "$output" == "9001" ]]
}

@test "toml_get_bool returns 0 for true" {
  run toml_get_bool "$TMP" github enabled
  [ "$status" -eq 0 ]
}

@test "toml_get_bool returns 1 for false" {
  run toml_get_bool "$TMP" playwright enabled
  [ "$status" -eq 1 ]
}

@test "toml_get_bool returns 1 for missing key (default false)" {
  run toml_get_bool "$TMP" github missing_key
  [ "$status" -eq 1 ]
}

@test "toml_get_array prints list elements one per line" {
  run toml_get_array "$TMP" github requires
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "GITHUB_TOKEN" ]]
}

@test "toml_get_array prints nothing for empty array" {
  run toml_get_array "$TMP" playwright requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "toml_get returns non-zero when key absent" {
  run toml_get "$TMP" github nope
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_toml.bats`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/toml.sh
# shellcheck shell=bash
# Minimal TOML reader. Supports: [sections], key = "string" / number / bool,
# key = ["a", "b"] arrays. No nested tables, no inline tables, no multiline.

toml_sections() {
  local file="$1"
  awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
    gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "")
    print
  }' "$file"
}

# Strip surrounding double quotes from a value if present.
_toml_strip_quotes() {
  local v="$1"
  # leading/trailing whitespace
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" == \"*\" ]]; then
    v="${v#\"}"; v="${v%\"}"
  fi
  printf '%s' "$v"
}

# toml_get FILE SECTION KEY -> prints value to stdout, exits 1 if missing.
toml_get() {
  local file="$1" section="$2" key="$3"
  local raw
  raw=$(awk -v sec="$section" -v k="$key" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      cur=$0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
      next
    }
    cur == sec && /=/ {
      split($0, p, "=")
      lhs=p[1]; gsub(/[[:space:]]/, "", lhs)
      if (lhs == k) {
        # rhs = everything after the first =
        rhs=$0
        sub(/^[^=]*=/, "", rhs)
        # strip inline comments (# outside of quotes) — naive but good enough
        sub(/[[:space:]]+#.*$/, "", rhs)
        print rhs
        exit
      }
    }
  ' "$file")
  [[ -z "$raw" ]] && return 1
  _toml_strip_quotes "$raw"
}

# toml_get_bool FILE SECTION KEY -> exit 0 if true, 1 otherwise (incl. missing).
toml_get_bool() {
  local v
  v=$(toml_get "$1" "$2" "$3") || return 1
  [[ "$v" == "true" ]]
}

# toml_get_array FILE SECTION KEY -> prints each element on a line.
toml_get_array() {
  local file="$1" section="$2" key="$3"
  local raw
  raw=$(toml_get "$file" "$section" "$key") || return 1
  # strip [ ] and split on commas
  raw="${raw#[}"; raw="${raw%]}"
  [[ -z "$raw" ]] && return 0
  local IFS=','
  local item
  for item in $raw; do
    # trim + strip quotes
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    item="${item#\"}"; item="${item%\"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_toml.bats`
Expected: 10 passing

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/toml.sh tests/unit/test_toml.bats
git commit -m "feat(lib): add minimal awk-based TOML reader

Supports sections, scalar strings/numbers/booleans, and string arrays.
Scope is the subset used by config/mcp.toml — no nested tables, no
datetimes, no multiline values.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Test sandbox image and runner

**Files:**
- Create: `tests/Dockerfile.ubuntu-systemd`
- Create: `tests/run-tests.sh`
- Create: `tests/helpers/setup_suite.bash`
- Create: `tests/helpers/assertions.bash`

- [ ] **Step 1: Write `tests/Dockerfile.ubuntu-systemd`**

```dockerfile
FROM jrei/systemd-ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      bats \
      curl \
      ca-certificates \
      sudo \
      iproute2 \
      gnupg \
      git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

# systemd is the entrypoint (inherited from base image)
```

- [ ] **Step 2: Write `tests/helpers/setup_suite.bash`**

```bash
# tests/helpers/setup_suite.bash
# shellcheck shell=bash

# Resolve repo root regardless of where bats is invoked from.
export REPO_ROOT
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# Make scripts/lib functions importable.
export LIB="$REPO_ROOT/scripts/lib"
export SCRIPTS="$REPO_ROOT/scripts"
```

- [ ] **Step 3: Write `tests/helpers/assertions.bash`**

```bash
# tests/helpers/assertions.bash
# shellcheck shell=bash

# assert_idempotent CMD [ARGS...]
# Runs the command twice, expects success both times. Second run must have NO
# [ACT] or [OK] lines — every step must report [SKIP].
assert_idempotent() {
  run "$@"
  [ "$status" -eq 0 ] || {
    echo "first run failed (status=$status):"
    echo "$output"
    return 1
  }

  run "$@"
  [ "$status" -eq 0 ] || {
    echo "second run failed (status=$status):"
    echo "$output"
    return 1
  }
  if grep -qE '^\[(ACT|OK)\]' <<<"$output"; then
    echo "second run was not a no-op (found [ACT]/[OK] lines):"
    echo "$output"
    return 1
  fi
  if ! grep -qE '^\[SKIP\]' <<<"$output"; then
    echo "second run did not emit any [SKIP] lines (script may be silent):"
    echo "$output"
    return 1
  fi
}
```

- [ ] **Step 4: Write `tests/run-tests.sh`**

```bash
#!/usr/bin/env bash
# tests/run-tests.sh — integration tests entrypoint.
# Builds (if needed) and runs the systemd sandbox container, mounts the repo,
# executes bats on tests/integration.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="hermes-setup-test"

if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "[run-tests] building image $IMAGE"
  docker build -t "$IMAGE" -f "$REPO_ROOT/tests/Dockerfile.ubuntu-systemd" "$REPO_ROOT"
fi

CONTAINER="hermes-setup-test-$$"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

docker run -d --rm \
  --name "$CONTAINER" \
  --privileged \
  --tmpfs /tmp \
  --tmpfs /run \
  -v "$REPO_ROOT:/repo" \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  "$IMAGE" >/dev/null

# Give systemd a moment to boot.
for _ in 1 2 3 4 5; do
  if docker exec "$CONTAINER" systemctl is-system-running --wait 2>/dev/null | \
       grep -qE 'running|degraded'; then
    break
  fi
  sleep 1
done

docker exec "$CONTAINER" bash -c 'cd /repo && bats tests/integration'
```

- [ ] **Step 5: Make executable and verify image builds**

```bash
chmod +x tests/run-tests.sh
make test-image
```

Expected: image builds successfully.

- [ ] **Step 6: Commit**

```bash
git add tests/Dockerfile.ubuntu-systemd tests/run-tests.sh tests/helpers/
git commit -m "test: add systemd-enabled Docker sandbox + helpers

Sandbox image based on jrei/systemd-ubuntu:22.04 + bats. Helper
assert_idempotent enforces the project-wide invariant that a second
run of any setup script emits only [SKIP] lines.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: `setup-server.sh` — scaffold and pre-flight guards

**Files:**
- Create: `scripts/setup-server.sh`
- Test: `tests/integration/test_server_setup.bats`

- [ ] **Step 1: Write the failing integration test (scaffold-only)**

```bash
# tests/integration/test_server_setup.bats
#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

@test "setup-server.sh refuses to run as non-root" {
  run sudo -u nobody bash "$SCRIPTS/setup-server.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must run as root"* ]]
}

@test "setup-server.sh refuses to run on non-Debian OS" {
  # Fake /etc/os-release for this test.
  run bash -c "OS_RELEASE_FILE=/dev/null '$SCRIPTS/setup-server.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Debian/Ubuntu only"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-integration` (or `bats tests/integration/test_server_setup.bats` inside the container)
Expected: FAIL (script does not exist).

- [ ] **Step 3: Write minimal scaffold**

```bash
#!/usr/bin/env bash
# scripts/setup-server.sh — Idempotent VPS preparation for Hermes.
# Runs as root on Debian/Ubuntu 22.04+. Re-runs are safe.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/write_file.sh
source "$SCRIPT_DIR/lib/write_file.sh"

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"
}

require_debian_family() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "Debian/Ubuntu only (no $OS_RELEASE_FILE)"
  if ! grep -qE '^(ID|ID_LIKE)=.*debian' "$OS_RELEASE_FILE" && \
     ! grep -qE '^(ID|ID_LIKE)=.*ubuntu' "$OS_RELEASE_FILE"; then
    die "Debian/Ubuntu only (found $(grep ^ID= "$OS_RELEASE_FILE" || echo unknown))"
  fi
}

main() {
  require_root
  require_debian_family
  log_ok "pre-flight checks passed"
}

main "$@"
```

- [ ] **Step 4: Make executable and run the integration tests**

```bash
chmod +x scripts/setup-server.sh
make test-integration
```

Expected: both scaffold tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-server.sh tests/integration/test_server_setup.bats
git commit -m "feat(server): scaffold setup-server.sh with pre-flight guards

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: `setup-server.sh` — packages, hermes user, sudoers

**Files:**
- Modify: `scripts/setup-server.sh`
- Modify: `tests/integration/test_server_setup.bats`

- [ ] **Step 1: Extend the integration test**

Append to `tests/integration/test_server_setup.bats`:

```bash
@test "setup-server.sh installs base packages and creates hermes user" {
  bash "$SCRIPTS/setup-server.sh"
  run dpkg-query -W -f='${Status}' ufw
  [[ "$output" == *"ok installed"* ]]
  run id -u hermes
  [ "$status" -eq 0 ]
}

@test "setup-server.sh is idempotent through packages+user steps" {
  bash "$SCRIPTS/setup-server.sh"      # warm-up
  run bash "$SCRIPTS/setup-server.sh"  # second run
  [ "$status" -eq 0 ]
  # The base-packages and user-creation steps must report [SKIP].
  [[ "$output" == *"[SKIP] user 'hermes' already exists"* ]]
}

@test "setup-server.sh creates sudoers drop-in for hermes" {
  bash "$SCRIPTS/setup-server.sh"
  [ -f /etc/sudoers.d/hermes ]
  run visudo -cf /etc/sudoers.d/hermes
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify the new ones fail**

Run inside container: `bats tests/integration/test_server_setup.bats`
Expected: first two scaffold tests still pass; new tests FAIL.

- [ ] **Step 3: Extend `setup-server.sh`**

Replace the body of `main()` and add new `ensure_*` functions:

```bash
# --- helpers ---------------------------------------------------------------

ensure_apt_cache_fresh() {
  local cache=/var/cache/apt/pkgcache.bin
  if [[ -f "$cache" ]] && find "$cache" -mmin -60 -print -quit | grep -q .; then
    log_skip "apt cache fresh (<60 min old)"
    return 0
  fi
  log_act "apt-get update"
  apt-get update -qq
  log_ok "apt cache refreshed"
}

ensure_pkgs() {
  local pkgs=(ca-certificates curl gnupg ufw fail2ban unattended-upgrades htop git)
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
    if is_pkg_installed "$p"; then
      log_skip "package $p already installed"
    else
      missing+=("$p")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  log_act "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  log_ok "installed: ${missing[*]}"
}

ensure_hermes_user() {
  if has_user hermes; then
    log_skip "user 'hermes' already exists"
  else
    log_act "creating user 'hermes'"
    useradd -m -s /bin/bash hermes
    log_ok "user 'hermes' created"
  fi

  # Copy root's authorized_keys to hermes if root has them and hermes doesn't.
  local rk=/root/.ssh/authorized_keys
  local hk_dir=/home/hermes/.ssh
  local hk=$hk_dir/authorized_keys
  if [[ -s "$rk" && ! -s "$hk" ]]; then
    log_act "copying root's authorized_keys to hermes"
    install -d -m 0700 -o hermes -g hermes "$hk_dir"
    install -m 0600 -o hermes -g hermes "$rk" "$hk"
    log_ok "copied authorized_keys for hermes"
  else
    log_skip "authorized_keys for hermes (already present or no root keys)"
  fi
}

ensure_sudoers() {
  local target=/etc/sudoers.d/hermes
  local content
  content=$(cat <<'EOF'
# Managed by hermes-setup. Allows the 'hermes' user to manage the Hermes service
# without a password — no other privileges.
hermes ALL=(root) NOPASSWD: /bin/systemctl restart hermes
hermes ALL=(root) NOPASSWD: /bin/systemctl status hermes
hermes ALL=(root) NOPASSWD: /bin/journalctl -u hermes *
EOF
)
  write_file_idempotent "$target" "$content" 0440
  # visudo -c fails -> remove the file we just wrote and die
  if ! visudo -cf "$target" >/dev/null; then
    rm -f "$target"
    die "invalid sudoers file written to $target — removed"
  fi
}

# --- main ------------------------------------------------------------------

main() {
  require_root
  require_debian_family
  log_ok "pre-flight checks passed"

  ensure_apt_cache_fresh
  ensure_pkgs
  ensure_hermes_user
  ensure_sudoers

  log_ok "server setup complete (packages, user, sudoers)"
}

main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-integration`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-server.sh tests/integration/test_server_setup.bats
git commit -m "feat(server): install base packages, create hermes user + sudoers

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: `setup-server.sh` — SSH hardening with self-lockout guard

**Files:**
- Modify: `scripts/setup-server.sh`
- Modify: `tests/integration/test_server_setup.bats`

- [ ] **Step 1: Add tests**

Append to `tests/integration/test_server_setup.bats`:

```bash
@test "setup-server.sh aborts SSH hardening when hermes has no authorized_keys" {
  # Wipe authorized_keys to trigger the self-lockout guard.
  rm -f /home/hermes/.ssh/authorized_keys /root/.ssh/authorized_keys
  run bash "$SCRIPTS/setup-server.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"self-lockout"* || "$output" == *"no SSH keys"* ]]
}

@test "setup-server.sh hardens SSH when hermes has authorized_keys" {
  install -d -m 0700 -o hermes -g hermes /home/hermes/.ssh
  echo "ssh-ed25519 AAAA fake@test" > /home/hermes/.ssh/authorized_keys
  chown hermes:hermes /home/hermes/.ssh/authorized_keys
  chmod 0600 /home/hermes/.ssh/authorized_keys

  bash "$SCRIPTS/setup-server.sh"
  [ -f /etc/ssh/sshd_config.d/99-hermes.conf ]
  run grep -E '^PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hermes.conf
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-integration`
Expected: new tests FAIL.

- [ ] **Step 3: Add SSH-hardening step**

Add to `setup-server.sh` (before `main()`):

```bash
ensure_ssh_hardening() {
  local hk=/home/hermes/.ssh/authorized_keys
  if [[ ! -s "$hk" ]]; then
    die "refusing to harden SSH: hermes has no SSH keys ($hk empty/missing) — would cause self-lockout"
  fi

  local target=/etc/ssh/sshd_config.d/99-hermes.conf
  local content
  content=$(cat <<'EOF'
# Managed by hermes-setup.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers hermes
EOF
)
  local tmp; tmp=$(mktemp)
  printf '%s' "$content" >"$tmp"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log_skip "sshd_config.d/99-hermes.conf already up-to-date"
    return 0
  fi

  # Validate by piping through sshd -t with a temp main config that includes us.
  if ! sshd -t -f /etc/ssh/sshd_config -o "Include $tmp"; then
    rm -f "$tmp"
    die "sshd -t failed for proposed config — aborting"
  fi
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
  log_ok "wrote $target"

  log_act "reloading ssh service"
  systemctl reload ssh
  log_ok "ssh reloaded"
}
```

Add `ensure_ssh_hardening` call to `main()` after `ensure_sudoers`.

- [ ] **Step 4: Run tests to verify**

Run: `make test-integration`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-server.sh tests/integration/test_server_setup.bats
git commit -m "feat(server): SSH hardening with self-lockout guard

Writes /etc/ssh/sshd_config.d/99-hermes.conf disabling root login and
password auth. Aborts if hermes has no authorized_keys (would lock the
admin out). Validates via sshd -t before reloading.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: `setup-server.sh` — UFW, fail2ban, unattended-upgrades

**Files:**
- Modify: `scripts/setup-server.sh`
- Modify: `tests/integration/test_server_setup.bats`

- [ ] **Step 1: Add tests**

```bash
@test "setup-server.sh enables UFW with required rules" {
  bash "$SCRIPTS/setup-server.sh"
  run ufw status verbose
  [[ "$output" == *"Status: active"* ]]
  [[ "$output" == *"22/tcp"* ]]
  [[ "$output" == *"80/tcp"* ]]
  [[ "$output" == *"443/tcp"* ]]
}

@test "setup-server.sh enables fail2ban service" {
  bash "$SCRIPTS/setup-server.sh"
  run systemctl is-enabled fail2ban
  [[ "$output" == "enabled" ]]
}

@test "setup-server.sh writes /etc/apt/apt.conf.d/20auto-upgrades" {
  bash "$SCRIPTS/setup-server.sh"
  [ -f /etc/apt/apt.conf.d/20auto-upgrades ]
  run grep -E 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Verify they fail**

Expected: 3 new failures.

- [ ] **Step 3: Add functions**

```bash
ensure_ufw() {
  # Defaults
  if ufw status verbose 2>/dev/null | grep -qE 'Default:.*deny \(incoming\)'; then
    log_skip "ufw default deny incoming already set"
  else
    log_act "ufw default deny incoming / allow outgoing"
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    log_ok "ufw defaults set"
  fi

  _ensure_ufw_rule "limit 22/tcp"  '22/tcp[[:space:]]+LIMIT'
  _ensure_ufw_rule "allow 80/tcp"  '80/tcp[[:space:]]+ALLOW'
  _ensure_ufw_rule "allow 443/tcp" '443/tcp[[:space:]]+ALLOW'

  if ufw status 2>/dev/null | grep -qE '^Status:[[:space:]]+active'; then
    log_skip "ufw already active"
  else
    log_act "enabling ufw"
    ufw --force enable >/dev/null
    log_ok "ufw enabled"
  fi
}

_ensure_ufw_rule() {
  local rule="$1" pattern="$2"
  if ufw_rule_present "$pattern"; then
    log_skip "ufw rule '$rule' already present"
    return 0
  fi
  log_act "ufw $rule"
  # shellcheck disable=SC2086
  ufw $rule >/dev/null
  log_ok "ufw rule added: $rule"
}

ensure_fail2ban() {
  if systemd_unit_enabled fail2ban; then
    log_skip "fail2ban already enabled"
  else
    log_act "enabling fail2ban"
    systemctl enable fail2ban >/dev/null
    log_ok "fail2ban enabled"
  fi
  if systemd_unit_active fail2ban; then
    log_skip "fail2ban already running"
  else
    log_act "starting fail2ban"
    systemctl start fail2ban
    log_ok "fail2ban started"
  fi
}

ensure_unattended_upgrades() {
  local target=/etc/apt/apt.conf.d/20auto-upgrades
  local content
  content=$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
)
  write_file_idempotent "$target" "$content" 0644
}
```

Add the three calls to `main()` after `ensure_ssh_hardening`.

- [ ] **Step 4: Verify tests pass**

Run: `make test-integration`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-server.sh tests/integration/test_server_setup.bats
git commit -m "feat(server): UFW, fail2ban, unattended-upgrades

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: `setup-server.sh` — Docker + idempotency invariant test

**Files:**
- Modify: `scripts/setup-server.sh`
- Modify: `tests/integration/test_server_setup.bats`

- [ ] **Step 1: Add idempotency invariant test**

```bash
@test "setup-server.sh installs Docker and adds hermes to docker group" {
  bash "$SCRIPTS/setup-server.sh"
  run command -v docker
  [ "$status" -eq 0 ]
  run id -nG hermes
  [[ "$output" == *"docker"* ]]
}

@test "setup-server.sh is fully idempotent (second run = only [SKIP])" {
  bash "$SCRIPTS/setup-server.sh"
  run bash "$SCRIPTS/setup-server.sh"
  [ "$status" -eq 0 ]
  ! grep -qE '^\[(ACT|OK)\]' <<<"$output" || {
    echo "second run was not idempotent:"
    echo "$output"
    false
  }
  grep -qE '^\[SKIP\]' <<<"$output"
}
```

- [ ] **Step 2: Verify they fail**

Expected: Docker test fails. Idempotency test will pass once Docker step is also idempotent.

- [ ] **Step 3: Add Docker step**

```bash
ensure_docker() {
  if has_command docker; then
    log_skip "docker already installed ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    log_act "installing docker via get.docker.com"
    curl -fsSL https://get.docker.com | sh >/dev/null
    log_ok "docker installed"
  fi

  if user_in_group hermes docker; then
    log_skip "hermes already in docker group"
  else
    log_act "adding hermes to docker group"
    usermod -aG docker hermes
    log_ok "hermes added to docker group (requires relogin to take effect)"
  fi

  if systemd_unit_enabled docker; then
    log_skip "docker.service already enabled"
  else
    log_act "enabling docker.service"
    systemctl enable docker >/dev/null
    log_ok "docker.service enabled"
  fi

  if systemd_unit_active docker; then
    log_skip "docker.service already running"
  else
    log_act "starting docker.service"
    systemctl start docker
    log_ok "docker.service started"
  fi
}
```

Add `ensure_docker` call at end of `main()` (before the final log_ok).

- [ ] **Step 4: Verify**

Run: `make test-integration`
Expected: all server tests pass including idempotency invariant.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-server.sh tests/integration/test_server_setup.bats
git commit -m "feat(server): install Docker + enforce full-script idempotency

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: Config templates (`.env.example`, `mcp.toml.example`, `docker-compose.yml`)

**Files:**
- Create: `config/.env.example`
- Create: `config/mcp.toml.example`
- Create: `config/docker-compose.yml`
- Create: `docker/Dockerfile.hermes`

- [ ] **Step 1: Write `config/.env.example`**

```ini
# config/.env.example
# Copy to config/.env and fill in values. NEVER commit config/.env (gitignored).

# ── LLM provider (at least one is required) ───────────────────────────────
# https://platform.openai.com/api-keys
OPENAI_API_KEY=
# https://console.anthropic.com/settings/keys
ANTHROPIC_API_KEY=

# ── MCP secrets — fill only for MCPs you enable in config/mcp.toml ────────
# docs/mcp/github.md
GITHUB_TOKEN=
# docs/mcp/context7.md (optional — anonymous tier works without it)
CONTEXT7_API_KEY=
# docs/mcp/postgresql.md   format: postgresql://user:pass@host:5432/db
POSTGRES_URL=
```

- [ ] **Step 2: Write `config/mcp.toml.example`**

```toml
# config/mcp.toml.example
# Copy to config/mcp.toml. Toggle enabled = true after filling required env
# vars in config/.env. See docs/mcp/<name>.md for instructions.

[filesystem]
enabled = false
description = "local filesystem access (mounted from host)"
transport = "stdio"
package = "@modelcontextprotocol/server-filesystem"
requires = []
mount = "/home/hermes/projects"

[github]
enabled = false
description = "repos, PRs, issues"
transport = "stdio"
package = "@modelcontextprotocol/server-github"
requires = ["GITHUB_TOKEN"]

[context7]
enabled = false
description = "up-to-date library docs"
transport = "stdio"
package = "@upstash/context7-mcp"
requires = []

[memory]
enabled = false
description = "long-term agent memory (SQLite in volume)"
transport = "stdio"
package = "@modelcontextprotocol/server-memory"
requires = []

[playwright]
enabled = false
description = "browser automation for E2E / scraping"
transport = "http"
image = "mcr.microsoft.com/playwright/mcp:latest"
port = 9001
requires = []

[postgres]
enabled = false
description = "execute SQL, inspect schema"
transport = "stdio"
package = "@modelcontextprotocol/server-postgres"
requires = ["POSTGRES_URL"]

[docker_mcp]
enabled = false
description = "inspect host containers and logs"
transport = "stdio"
package = "@modelcontextprotocol/server-docker"
requires = []
# Mounting /var/run/docker.sock grants root-equivalent access to the host.
# Set this to true to acknowledge the risk — required to enable docker_mcp.
acknowledge_socket_risk = false
```

- [ ] **Step 3: Write `config/docker-compose.yml`**

```yaml
# config/docker-compose.yml
# Run from the repo root: docker compose -f config/docker-compose.yml up -d

services:
  hermes:
    image: ${HERMES_IMAGE:-nousresearch/hermes-agent:latest}
    container_name: hermes
    restart: unless-stopped
    env_file: ./.env
    volumes:
      - hermes_data:/home/hermes/.hermes
    networks: [hermes_net]
    healthcheck:
      test: ["CMD-SHELL", "hermes --version >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    stdin_open: true
    tty: true

volumes:
  hermes_data:
    name: hermes_data

networks:
  hermes_net:
    name: hermes_net
```

- [ ] **Step 4: Write `docker/Dockerfile.hermes` (fallback build)**

```dockerfile
# docker/Dockerfile.hermes
# Fallback image — used when `docker pull nousresearch/hermes-agent` fails.
# Installs Hermes via the official curl script.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/hermes \
    PATH=/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 python3-pip python3-venv \
      ripgrep ffmpeg sudo \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash hermes

USER hermes
WORKDIR /home/hermes

RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
    | bash

ENTRYPOINT ["hermes"]
CMD ["gateway", "start"]
```

- [ ] **Step 5: Commit**

```bash
git add config/.env.example config/mcp.toml.example config/docker-compose.yml docker/Dockerfile.hermes
git commit -m "feat(config): add .env / mcp.toml / docker-compose / Dockerfile templates

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: `setup-hermes.sh` — scaffold, configs, required-env check

**Files:**
- Create: `scripts/setup-hermes.sh`
- Create: `tests/integration/test_hermes_setup.bats`

- [ ] **Step 1: Write failing test**

```bash
# tests/integration/test_hermes_setup.bats
#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

setup() {
  # Run inside container as non-root user; mock docker group membership.
  # The integration sandbox runs as root by default — we test setup-hermes by
  # creating the hermes user and `su` into it.
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  usermod -aG docker hermes 2>/dev/null || true
}

@test "setup-hermes.sh refuses to run as root" {
  run bash "$SCRIPTS/setup-hermes.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not run as root"* ]]
}

@test "setup-hermes.sh copies example configs on first run" {
  rm -f "$REPO_ROOT/config/.env" "$REPO_ROOT/config/mcp.toml"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -ne 0 ]   # exits 1 because .env has no LLM key
  [ -f "$REPO_ROOT/config/.env" ]
  [ -f "$REPO_ROOT/config/mcp.toml" ]
}

@test "setup-hermes.sh fails when no LLM key is configured" {
  : > "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no LLM API key configured"* ]]
}

@test "setup-hermes.sh accepts OPENAI_API_KEY alone" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Verify failures**

Expected: tests fail (script missing).

- [ ] **Step 3: Write scaffold**

```bash
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

main() {
  require_non_root
  ensure_configs
  ensure_llm_key
  if (( CONFIGS_ONLY )); then
    log_ok "configs-only mode: stopping before docker steps"
    return 0
  fi
  require_docker_group
  log_ok "(docker steps will be added in next tasks)"
}

main "$@"
```

- [ ] **Step 4: Make executable and run tests**

```bash
chmod +x scripts/setup-hermes.sh
make test-integration
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-hermes.sh tests/integration/test_hermes_setup.bats
git commit -m "feat(hermes): scaffold setup-hermes.sh + config init + LLM key gate

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 13: `setup-hermes.sh` — image pull with fallback build

**Files:**
- Modify: `scripts/setup-hermes.sh`
- Modify: `tests/integration/test_hermes_setup.bats`

- [ ] **Step 1: Add test**

```bash
@test "setup-hermes.sh creates the data volume and network" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  # Stub `docker pull` to always fail so we exercise the fallback path.
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1" in
  pull) echo "stub: pull failed" >&2; exit 1 ;;
  build) echo "stub: built"; exit 0 ;;
  *) exec /usr/bin/docker "$@" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH HERMES_NO_COMPOSE=1 bash '$SCRIPTS/setup-hermes.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to local build"* ]]

  rm -rf /tmp/bin-stub
}
```

- [ ] **Step 2: Verify it fails**

- [ ] **Step 3: Extend `setup-hermes.sh`**

Add new functions:

```bash
DEFAULT_IMAGE="nousresearch/hermes-agent:latest"
LOCAL_IMAGE="hermes-agent:local"

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
```

In `main()`, replace the placeholder `log_ok "(docker steps will be added…)"` with:

```bash
  ensure_image
  if [[ -n "${HERMES_NO_COMPOSE:-}" ]]; then
    log_ok "HERMES_NO_COMPOSE set: stopping before compose up"
    return 0
  fi
  log_ok "(compose steps added in next task)"
```

- [ ] **Step 4: Verify**

Run: `make test-integration`
Expected: passes (fallback path exercised).

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-hermes.sh tests/integration/test_hermes_setup.bats
git commit -m "feat(hermes): image acquisition with pull-or-build fallback

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 14: `setup-hermes.sh` — compose up + health gate

**Files:**
- Modify: `scripts/setup-hermes.sh`
- Modify: `tests/integration/test_hermes_setup.bats`

- [ ] **Step 1: Add test**

```bash
@test "setup-hermes.sh is idempotent across full run" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  # Mock docker fully — compose up + ps + inspect must succeed.
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
STATE_FILE=/tmp/.docker-stub-state
case "$*" in
  "image inspect "*) test -f "$STATE_FILE" ;;
  "pull "*) touch "$STATE_FILE"; echo pulled ;;
  "volume inspect "*) [[ "${DOCKER_HAS_VOL:-0}" == "1" ]] ;;
  "volume create "*) export DOCKER_HAS_VOL=1; echo created ;;
  "network create "*) echo created ;;
  "compose "*"up -d") echo "up"; touch /tmp/.docker-stub-container ;;
  "ps -a --format "*) [[ -f /tmp/.docker-stub-container ]] && echo hermes ;;
  "inspect -f "*) echo running ;;
  "exec "*) echo "hermes 0.1.0" ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  PATH=/tmp/bin-stub:$PATH bash "$SCRIPTS/setup-hermes.sh"
  run env PATH=/tmp/bin-stub:$PATH bash "$SCRIPTS/setup-hermes.sh"
  [ "$status" -eq 0 ]
  ! grep -qE '^\[(ACT|OK)\]' <<<"$output" || {
    echo "$output"; false
  }

  rm -rf /tmp/bin-stub /tmp/.docker-stub-state /tmp/.docker-stub-container
}
```

- [ ] **Step 2: Verify it fails**

- [ ] **Step 3: Extend the script**

Add functions:

```bash
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
  if docker_container_exists hermes && docker_container_running hermes; then
    log_skip "container 'hermes' already running"
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
```

Replace the placeholder near the end of `main()`:

```bash
  ensure_volume
  ensure_network
  ensure_compose_up
  wait_for_health
  first_run_init
  log_ok "hermes setup complete"
  log_ok "next: edit config/mcp.toml to enable MCP servers, then run ./scripts/setup-mcp.sh"
```

- [ ] **Step 4: Run tests**

Run: `make test-integration`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-hermes.sh tests/integration/test_hermes_setup.bats
git commit -m "feat(hermes): compose up + health gate + full idempotency

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 15: `setup-mcp.sh` — scaffold, toml parsing, env-check loop

**Files:**
- Create: `scripts/setup-mcp.sh`
- Create: `tests/integration/test_mcp_setup.bats`

- [ ] **Step 1: Write failing test**

```bash
# tests/integration/test_mcp_setup.bats
#!/usr/bin/env bats

load '../helpers/setup_suite'

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  cp "$REPO_ROOT/config/mcp.toml.example" "$REPO_ROOT/config/mcp.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  chown -R hermes:hermes "$REPO_ROOT/config"
}

teardown() {
  cp "$REPO_ROOT/config/mcp.toml.example" "$REPO_ROOT/config/mcp.toml"
}

@test "setup-mcp.sh refuses to run when hermes container is missing" {
  # No docker container stub -> hermes container absent.
  run su hermes -c "bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hermes container is not running"* ]]
}

@test "setup-mcp.sh reports missing required env for enabled github" {
  sed -i 's|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  # Stub docker so hermes container 'exists and runs'.
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ps -a --format "*) echo hermes ;;
  "inspect -f "*) echo running ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [[ "$output" == *"mcp.github: missing GITHUB_TOKEN"* ]]
  rm -rf /tmp/bin-stub
}
```

- [ ] **Step 2: Verify failures**

- [ ] **Step 3: Write scaffold**

```bash
#!/usr/bin/env bash
# scripts/setup-mcp.sh — Idempotently sync MCP servers based on config/mcp.toml.
# Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
TOML="$CONFIG_DIR/mcp.toml"
ENVFILE="$CONFIG_DIR/.env"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"

require_hermes_running() {
  if ! docker_container_running hermes; then
    die "hermes container is not running — run scripts/setup-hermes.sh first"
  fi
}

require_files() {
  [[ -f "$TOML" ]] || die "missing $TOML"
  [[ -f "$ENVFILE" ]] || die "missing $ENVFILE"
}

# echoes section names that are enabled=true
enabled_mcps() {
  local s
  for s in $(toml_sections "$TOML"); do
    if toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done
}

# echoes section names that are enabled=false but currently registered in hermes
disabled_mcps_to_remove() {
  local registered s
  registered=$(docker exec hermes hermes mcp list --quiet 2>/dev/null | awk 'NF{print $1}') || return 0
  for s in $registered; do
    if ! toml_get_bool "$TOML" "$s" enabled; then
      printf '%s\n' "$s"
    fi
  done
}

# Returns 0 if all required env vars are non-empty in .env; otherwise prints
# missing keys and returns 1.
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

main() {
  require_files
  require_hermes_running

  local mcp
  while IFS= read -r mcp; do
    [[ -z "$mcp" ]] && continue
    if ! check_required_env "$mcp"; then
      continue
    fi
    log_ok "mcp.$mcp: env OK (deployment in next task)"
  done < <(enabled_mcps)

  log_ok "mcp scan complete"
}

main "$@"
```

- [ ] **Step 4: Make executable and run tests**

```bash
chmod +x scripts/setup-mcp.sh
make test-integration
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-mcp.sh tests/integration/test_mcp_setup.bats
git commit -m "feat(mcp): scaffold setup-mcp.sh + per-MCP required-env check

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 16: `setup-mcp.sh` — stdio-MCP install + register

**Files:**
- Modify: `scripts/setup-mcp.sh`
- Modify: `tests/integration/test_mcp_setup.bats`

- [ ] **Step 1: Add test**

```bash
@test "setup-mcp.sh installs npm package + registers stdio MCP" {
  sed -i 's|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  sed -i 's|^GITHUB_TOKEN=$|GITHUB_TOKEN=ghp_test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "npm list -g --depth=0") echo "" ;;          # nothing installed
      "npm install -g "*) echo "installed" ;;
      "hermes mcp list"*|"hermes mcp list --quiet") echo "" ;;
      "hermes mcp add"*) echo "added: $*" ;;
      "hermes mcp test"*) echo "ok" ;;
      *) echo "exec-stub: $*" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installing @modelcontextprotocol/server-github"* ]]
  [[ "$output" == *"registering mcp 'github'"* ]]

  rm -rf /tmp/bin-stub
}

@test "setup-mcp.sh is idempotent" {
  sed -i 's|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"
  sed -i 's|^GITHUB_TOKEN=$|GITHUB_TOKEN=ghp_test|' "$REPO_ROOT/config/.env"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
STATE=/tmp/.mcp-stub-installed
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "npm list -g --depth=0") cat "$STATE" 2>/dev/null ;;
      "npm install -g "*)
        pkg="${*##* }"
        echo "$pkg" >> "$STATE"
        echo "installed $pkg" ;;
      "hermes mcp list --quiet")
        # echo each installed mcp section name (very rough)
        if grep -q server-github "$STATE" 2>/dev/null; then echo "github"; fi ;;
      "hermes mcp add"*) echo "added" ;;
      "hermes mcp test"*) echo "ok" ;;
      *) echo "" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  : > /tmp/.mcp-stub-installed

  PATH=/tmp/bin-stub:$PATH bash "$SCRIPTS/setup-mcp.sh"
  run env PATH=/tmp/bin-stub:$PATH bash "$SCRIPTS/setup-mcp.sh"
  [ "$status" -eq 0 ]
  ! grep -qE '^\[(ACT|OK)\] (installing|registering)' <<<"$output" || {
    echo "$output"; false
  }
  grep -qE '^\[SKIP\]' <<<"$output"

  rm -rf /tmp/bin-stub /tmp/.mcp-stub-installed
}
```

- [ ] **Step 2: Verify failures**

- [ ] **Step 3: Add deployment helpers**

```bash
# True if `hermes mcp list` contains a row beginning with $1.
mcp_registered_in_hermes() {
  docker exec hermes hermes mcp list --quiet 2>/dev/null \
    | awk 'NF{print $1}' \
    | grep -qx "$1"
}

# True if the npm package is installed globally inside the hermes container.
npm_pkg_installed() {
  docker exec hermes bash -c "npm list -g --depth=0 2>/dev/null | grep -q '$1'"
}

deploy_stdio_mcp() {
  local mcp="$1"
  local pkg
  pkg=$(toml_get "$TOML" "$mcp" package) || die "mcp.$mcp: missing 'package'"

  if npm_pkg_installed "$pkg"; then
    log_skip "mcp.$mcp: $pkg already installed in hermes container"
  else
    log_act "installing $pkg in hermes container"
    docker exec hermes npm install -g "$pkg" >/dev/null
    log_ok "installed $pkg"
  fi

  if mcp_registered_in_hermes "$mcp"; then
    log_skip "mcp.$mcp: already registered in hermes"
  else
    log_act "registering mcp '$mcp'"
    # Pass through env vars from .env that the MCP requires.
    local env_args=() req
    while IFS= read -r req; do
      [[ -z "$req" ]] && continue
      env_args+=(--env "$req")
    done < <(toml_get_array "$TOML" "$mcp" requires)
    docker exec hermes hermes mcp add "$mcp" \
      --transport stdio --command "$pkg" "${env_args[@]}" >/dev/null
    log_ok "registered mcp '$mcp'"
  fi
}
```

In `main()`, replace the placeholder `log_ok "mcp.$mcp: env OK …"` line with:

```bash
    local transport
    transport=$(toml_get "$TOML" "$mcp" transport) || transport="stdio"
    case "$transport" in
      stdio) deploy_stdio_mcp "$mcp" ;;
      http)  log_warn "mcp.$mcp: http transport added in next task — skipping" ;;
      *)     log_warn "mcp.$mcp: unknown transport '$transport' — skipping" ;;
    esac
```

- [ ] **Step 4: Verify tests pass**

Run: `make test-integration`

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-mcp.sh tests/integration/test_mcp_setup.bats
git commit -m "feat(mcp): deploy stdio MCPs via npm + register with hermes

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 17: `setup-mcp.sh` — http-MCP via separate compose service

**Files:**
- Modify: `scripts/setup-mcp.sh`
- Create: `config/docker-compose.mcp.yml`

- [ ] **Step 1: Write `config/docker-compose.mcp.yml`**

```yaml
# config/docker-compose.mcp.yml
# Auxiliary compose file — only used by setup-mcp.sh for http-transport MCPs.
# The set of active services here mirrors enabled = true in mcp.toml.

services:
  mcp-playwright:
    image: mcr.microsoft.com/playwright/mcp:latest
    container_name: mcp-playwright
    restart: unless-stopped
    networks: [hermes_net]
    profiles: [playwright]
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost:9001/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3

networks:
  hermes_net:
    external: true
    name: hermes_net
```

- [ ] **Step 2: Extend `setup-mcp.sh`**

Add helpers:

```bash
deploy_http_mcp() {
  local mcp="$1"
  local port
  port=$(toml_get "$TOML" "$mcp" port) || die "mcp.$mcp: missing 'port'"

  local service="mcp-$mcp"
  if docker_container_running "$service"; then
    log_skip "mcp.$mcp: container $service already running"
  else
    log_act "starting compose service $service (profile $mcp)"
    docker compose -f "$CONFIG_DIR/docker-compose.mcp.yml" --profile "$mcp" up -d "$service" >/dev/null
    log_ok "started $service"
  fi

  if mcp_registered_in_hermes "$mcp"; then
    log_skip "mcp.$mcp: already registered in hermes"
  else
    log_act "registering mcp '$mcp' (http)"
    docker exec hermes hermes mcp add "$mcp" \
      --transport http --url "http://$service:$port" >/dev/null
    log_ok "registered mcp '$mcp'"
  fi
}
```

Replace the `case "$transport"` block:

```bash
    case "$transport" in
      stdio) deploy_stdio_mcp "$mcp" ;;
      http)  deploy_http_mcp "$mcp" ;;
      *)     log_warn "mcp.$mcp: unknown transport '$transport' — skipping" ;;
    esac
```

- [ ] **Step 3: Run integration tests**

(The existing tests still pass; http path is exercised by a manual smoke once Playwright image is desired.)

Run: `make test-integration`

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-mcp.sh config/docker-compose.mcp.yml
git commit -m "feat(mcp): deploy http-transport MCPs via auxiliary compose file

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 18: `setup-mcp.sh` — remove disabled MCPs + docker_mcp socket guard

**Files:**
- Modify: `scripts/setup-mcp.sh`
- Modify: `tests/integration/test_mcp_setup.bats`

- [ ] **Step 1: Add tests**

```bash
@test "setup-mcp.sh removes MCPs that were disabled in toml" {
  # Pretend 'github' is registered but toml says enabled=false.
  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  "exec hermes")
    shift 2
    case "$*" in
      "hermes mcp list --quiet") echo github ;;
      "hermes mcp remove "*) echo "removed"; touch /tmp/.removed ;;
      *) echo "" ;;
    esac ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker
  rm -f /tmp/.removed

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [ "$status" -eq 0 ]
  [ -f /tmp/.removed ]
  [[ "$output" == *"unregistering mcp 'github'"* ]]

  rm -rf /tmp/bin-stub /tmp/.removed
}

@test "setup-mcp.sh refuses docker_mcp without acknowledge_socket_risk" {
  sed -i '/^\[docker_mcp\]/,/^$/ s|^enabled = false$|enabled = true|' "$REPO_ROOT/config/mcp.toml"

  mkdir -p /tmp/bin-stub
  cat >/tmp/bin-stub/docker <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -a") echo hermes ;;
  "inspect -f") echo running ;;
  *) echo "stub: $*" ;;
esac
STUB
  chmod +x /tmp/bin-stub/docker

  run su hermes -c "PATH=/tmp/bin-stub:$PATH bash '$SCRIPTS/setup-mcp.sh'"
  [[ "$output" == *"acknowledge_socket_risk"* ]]
  rm -rf /tmp/bin-stub
}
```

- [ ] **Step 2: Verify failures**

- [ ] **Step 3: Extend `setup-mcp.sh`**

Add socket-risk guard at the top of `main()`'s per-MCP loop (before the env check):

```bash
    if [[ "$mcp" == "docker_mcp" ]]; then
      if ! toml_get_bool "$TOML" docker_mcp acknowledge_socket_risk; then
        log_warn "mcp.docker_mcp: skipped — set acknowledge_socket_risk = true in mcp.toml to opt-in (mounts /var/run/docker.sock which is root-equivalent)"
        continue
      fi
    fi
```

Add removal loop after the install loop in `main()`:

```bash
  local stale
  while IFS= read -r stale; do
    [[ -z "$stale" ]] && continue
    log_act "unregistering mcp '$stale' (no longer enabled in mcp.toml)"
    docker exec hermes hermes mcp remove "$stale" >/dev/null
    log_ok "unregistered mcp '$stale'"
  done < <(disabled_mcps_to_remove)
```

- [ ] **Step 4: Verify**

Run: `make test-integration`

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-mcp.sh tests/integration/test_mcp_setup.bats
git commit -m "feat(mcp): remove stale MCPs + docker_mcp socket-risk guard

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 19: Top-level `README.md` (quick start)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md`**

```markdown
# hermes-setup

Idempotent bash installer for [Hermes Agent](https://hermes-agent.nousresearch.com) on a Linux VPS, running in Docker, with a curated developer-stack of MCP servers.

## What it gives you

- A hardened Debian/Ubuntu VPS: dedicated `hermes` user, SSH key-only login, UFW, fail2ban, unattended-upgrades.
- Hermes Agent running in a Docker container (`docker exec -it hermes hermes chat`).
- An opt-in set of MCP servers (Filesystem, GitHub, Context7, Memory, Playwright, Postgres, Docker) toggled via `config/mcp.toml`.
- Every script is idempotent — re-running is safe and reports only `[SKIP]` lines.

## Quick start (on a fresh VPS)

```bash
# 1. Provision a Debian 12 or Ubuntu 22.04 VPS, add your SSH key, log in as root.
ssh root@<vps-ip>

# 2. Clone this repo.
git clone <repo-url> hermes-setup
cd hermes-setup

# 3. Run the server preparation. Creates the 'hermes' user, installs Docker,
#    hardens SSH (require key auth), enables UFW.
sudo ./scripts/setup-server.sh

# 4. Switch to the hermes user (or log out and back in as hermes).
su - hermes
cd ~/hermes-setup

# 5. Fill in at least one LLM key in config/.env (see docs/02-hermes-setup.md).
cp config/.env.example config/.env
nano config/.env

# 6. Launch Hermes.
./scripts/setup-hermes.sh

# 7. (Optional) Enable MCP servers by editing config/mcp.toml, then run:
./scripts/setup-mcp.sh
```

## Documentation

- [`docs/01-server-setup.md`](docs/01-server-setup.md) — manual steps that aren't automated (provisioning, DNS, backups).
- [`docs/02-hermes-setup.md`](docs/02-hermes-setup.md) — how to fill in `.env`, troubleshoot, chat with the agent.
- [`docs/mcp/`](docs/mcp/) — one file per MCP server: where to get the token, what the script does for you.
- [`docs/superpowers/specs/2026-05-30-hermes-setup-design.md`](docs/superpowers/specs/2026-05-30-hermes-setup-design.md) — full design rationale.

## Testing

```bash
make test-unit         # bats unit tests on host (fast)
make test-integration  # full scripts in systemd-enabled Docker sandbox
make test              # both
```

## Layout

```
scripts/   setup-server.sh, setup-hermes.sh, setup-mcp.sh + lib/
config/    .env.example, mcp.toml.example, docker-compose*.yml
docker/    Dockerfile.hermes (fallback build)
docs/      manual instructions
tests/     bats unit + integration + sandbox Dockerfile
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README quick start

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 20: `docs/01-server-setup.md` (manual VPS preparation)

**Files:**
- Create: `docs/01-server-setup.md`

- [ ] **Step 1: Write the doc**

```markdown
# 01 — Manual VPS preparation

`scripts/setup-server.sh` does most of the work. This document covers everything that has to be done by hand (or that you should know before/after running it).

## Before running setup-server.sh

### Provider and image
- Any Debian 12 or Ubuntu 22.04 VPS (Hetzner, DigitalOcean, Linode, Vultr, Scaleway — all fine).
- Minimum: 1 vCPU, 2 GB RAM, 20 GB disk. Hermes itself is small; Playwright MCP image is ~1 GB so plan accordingly.
- Region: pick the one closest to your LLM provider's API endpoint to minimise latency.

### SSH key
1. Generate locally if you don't have one:
   ```bash
   ssh-keygen -t ed25519 -C "hermes-setup@<your-email>"
   ```
2. Paste the public key (`~/.ssh/id_ed25519.pub`) into your VPS provider's web UI **before** booting the server. Most providers inject it into `/root/.ssh/authorized_keys` automatically.
3. Test login: `ssh root@<vps-ip>`. If this works, `setup-server.sh` will be able to copy the key over to the `hermes` user.

### DNS (only if you plan to expose a gateway later)
- For Telegram webhooks or a WebUI, you need a domain pointing at the VPS — add an A record `hermes.example.com → <vps-ip>`.
- Not needed for CLI-only or polling-based Telegram.

## After running setup-server.sh

### Verify SSH still works
**Do not close the existing root SSH session** until you've confirmed the new setup works:
```bash
# In a NEW terminal:
ssh hermes@<vps-ip>
```
If this fails, fix the issue from your existing session before closing it. Recovery: revert `/etc/ssh/sshd_config.d/99-hermes.conf` and `systemctl reload ssh`.

### Confirm firewall rules
```bash
sudo ufw status verbose
```
Expected: `Status: active`, default `deny (incoming)` / `allow (outgoing)`, rules for 22/tcp (LIMIT), 80/tcp, 443/tcp.

### Backups
The script does NOT configure backups. Pick one:
- **Provider snapshot**: most providers offer scheduled snapshots ($1-3/month) — easiest.
- **Restic to external storage**: write your own systemd timer.

What to back up at minimum: `/home/hermes/.hermes` (inside the `hermes_data` Docker volume) — it contains config, skills, memory.

### Optional hardening (not done by the script)
- Move SSH off port 22 (edit `/etc/ssh/sshd_config.d/99-hermes.conf`, update UFW rule).
- Install `endlessh` as a tarpit on port 22.
- Add `wireguard` or `tailscale` and require SSH only via VPN.

## Troubleshooting

| Symptom | Check |
|---|---|
| Script aborts: `Debian/Ubuntu only` | `cat /etc/os-release` — only `ID=debian` or `ID=ubuntu` is supported. |
| Script aborts: `refusing to harden SSH: no SSH keys` | Provider didn't inject your key, or hermes user wasn't created from a sudo-with-keys session. Add the key manually to `/home/hermes/.ssh/authorized_keys` before re-running. |
| Can't log in as hermes after script | Did the script complete `[OK] copied authorized_keys for hermes`? If not, copy it manually: `cp /root/.ssh/authorized_keys /home/hermes/.ssh/authorized_keys && chown hermes:hermes ...` |
```

- [ ] **Step 2: Commit**

```bash
git add docs/01-server-setup.md
git commit -m "docs: manual VPS preparation (01-server-setup)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 21: `docs/02-hermes-setup.md` (filling .env, first chat)

**Files:**
- Create: `docs/02-hermes-setup.md`

- [ ] **Step 1: Write the doc**

```markdown
# 02 — Filling in .env and first chat

After `setup-server.sh`, switch to the `hermes` user:
```bash
su - hermes
cd ~/hermes-setup
```

## Required: at least one LLM key in config/.env

The script aborts unless either `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` is set and non-empty in `config/.env`.

### OpenAI
1. https://platform.openai.com/api-keys → **Create new secret key**.
2. Copy the `sk-…` value.
3. Edit `config/.env`:
   ```
   OPENAI_API_KEY=sk-yourkeyhere
   ```

### Anthropic
1. https://console.anthropic.com/settings/keys → **Create Key**.
2. Copy the `sk-ant-…` value.
3. Edit `config/.env`:
   ```
   ANTHROPIC_API_KEY=sk-ant-yourkeyhere
   ```

## Run setup-hermes.sh

```bash
./scripts/setup-hermes.sh
```

Expected output (first run):
```
[OK] LLM API key present in .env
[ACT] pulling nousresearch/hermes-agent:latest
[OK] pulled nousresearch/hermes-agent:latest
[ACT] creating volume hermes_data
[OK] volume hermes_data created
[ACT] creating network hermes_net
[OK] network hermes_net created
[ACT] docker compose up -d hermes
[OK] container 'hermes' started
[OK] hermes responsive (hermes 0.x.y)
[OK] hermes setup complete
```

Second run: every line should start with `[SKIP]`.

## Chat with Hermes

```bash
docker exec -it hermes hermes chat
```

Quick checks inside the chat:
- `/help` — list commands.
- `/model` — verify which model is configured.

## Customise the SOUL (system prompt)

Hermes uses `~/.hermes/SOUL.md` (inside the volume) as its personality. To edit:
```bash
docker exec -it hermes bash -c 'nano /home/hermes/.hermes/SOUL.md'
docker exec hermes hermes config reload
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `current user not in 'docker' group` | After `setup-server.sh` you must log out and back in (group membership is per-session). Or run `newgrp docker`. |
| Image pull fails, falls back to local build, build takes a long time | First build can be 5-10 min. Subsequent runs are cached. |
| Container restarts in a loop | `docker logs --tail=100 hermes`. Common: missing/invalid LLM key (Hermes exits if model can't be initialised). |
| `hermes did not become healthy in 30s` | Check `docker logs hermes` for startup errors. If the network is slow, increase the loop in `scripts/setup-hermes.sh::wait_for_health`. |
```

- [ ] **Step 2: Commit**

```bash
git add docs/02-hermes-setup.md
git commit -m "docs: filling .env and first chat (02-hermes-setup)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 22: Per-MCP manual instructions

**Files:**
- Create: `docs/mcp/filesystem.md`, `docs/mcp/github.md`, `docs/mcp/context7.md`, `docs/mcp/memory.md`, `docs/mcp/playwright.md`, `docs/mcp/postgresql.md`, `docs/mcp/docker_mcp.md`

Each file follows the same skeleton. Below is the full content for each.

- [ ] **Step 1: `docs/mcp/filesystem.md`**

```markdown
# Filesystem MCP

Read/write access to a host directory mounted into the Hermes container.

## What you need to do by hand
1. Decide which host directory to expose (default: `/home/hermes/projects`).
2. Make sure it exists:
   ```bash
   mkdir -p ~/projects
   ```
3. In `config/mcp.toml`, set:
   ```toml
   [filesystem]
   enabled = true
   mount = "/home/hermes/projects"
   ```
4. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-filesystem` inside the hermes container.
- Registers it with Hermes pointing at the `mount` path.

## Verify
```bash
docker exec hermes hermes mcp test filesystem
```
Expected: `ok`.
```

- [ ] **Step 2: `docs/mcp/github.md`**

```markdown
# GitHub MCP

Read repos, manage issues and pull requests.

## What you need to do by hand
1. Open https://github.com/settings/personal-access-tokens/new (fine-grained PAT).
2. **Token name:** `hermes-mcp`
3. **Repository access:** "All repositories" (or "Only select repositories" — list the ones you want).
4. **Permissions:**
   - Contents: **Read**
   - Issues: **Read and write**
   - Pull requests: **Read and write**
   - Metadata: **Read** (auto-included)
5. **Generate token** → copy the `ghp_…` value.
6. In `config/.env`:
   ```
   GITHUB_TOKEN=ghp_yourtokenhere
   ```
7. In `config/mcp.toml`:
   ```toml
   [github]
   enabled = true
   ```
8. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-github` inside the hermes container.
- Registers it with Hermes, passing `GITHUB_TOKEN` through.

## Verify
```bash
docker exec hermes hermes mcp test github
```

## Troubleshooting
- `401 Unauthorized` — token expired (fine-grained PATs default to 30 days). Re-issue.
- Cannot see private repos — verify token has access to those specific repos.
```

- [ ] **Step 3: `docs/mcp/context7.md`**

```markdown
# Context7 MCP

Up-to-date library/framework documentation lookup.

## What you need to do by hand
The anonymous tier works without any token; rate-limited but enough for personal use. If you hit limits:

1. Sign up at https://context7.com → API keys → create a key.
2. In `config/.env`:
   ```
   CONTEXT7_API_KEY=ctx7_yourkeyhere
   ```
3. In `config/mcp.toml`:
   ```toml
   [context7]
   enabled = true
   ```
4. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@upstash/context7-mcp` inside the hermes container.
- Registers it with Hermes (key passed through if set).

## Verify
Ask Hermes: "Show me the latest Next.js app-router docs for layouts." It should call the `context7` tool.
```

- [ ] **Step 4: `docs/mcp/memory.md`**

```markdown
# Memory MCP

Long-term agent memory backed by a SQLite file in the `hermes_data` volume. No external service.

## What you need to do by hand
1. In `config/mcp.toml`:
   ```toml
   [memory]
   enabled = true
   ```
2. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-memory` inside the hermes container.
- Registers it with Hermes; storage lives at `/home/hermes/.hermes/memory.db` (persisted in the volume).

## Verify
Tell Hermes: "Remember that I prefer Go over Rust." Then start a new chat and ask: "What languages do I prefer?"
```

- [ ] **Step 5: `docs/mcp/playwright.md`**

```markdown
# Playwright MCP

Headless browser automation. Runs as a separate Docker container (the image is ~1 GB).

## What you need to do by hand
1. In `config/mcp.toml`:
   ```toml
   [playwright]
   enabled = true
   ```
2. Run: `./scripts/setup-mcp.sh`

## What the script does
- Pulls `mcr.microsoft.com/playwright/mcp:latest` and starts `mcp-playwright` on the `hermes_net` Docker network.
- Registers it with Hermes via HTTP transport on port 9001.

## Verify
```bash
docker exec hermes hermes mcp test playwright
```
Or ask Hermes: "Open https://example.com and tell me the page title."

## Disable / remove
Set `enabled = false` in `mcp.toml` and run `./scripts/setup-mcp.sh` again — the script will un-register the MCP and the container will be stopped on the next `docker compose down`.
```

- [ ] **Step 6: `docs/mcp/postgresql.md`**

```markdown
# PostgreSQL MCP

Run SQL queries and introspect schemas against your databases.

## What you need to do by hand
1. Obtain a read-only PostgreSQL user for the database you want to expose. Example DDL:
   ```sql
   CREATE USER hermes_ro WITH PASSWORD 'strong-random';
   GRANT CONNECT ON DATABASE mydb TO hermes_ro;
   GRANT USAGE ON SCHEMA public TO hermes_ro;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO hermes_ro;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO hermes_ro;
   ```
2. Build the connection URL: `postgresql://hermes_ro:strong-random@db-host:5432/mydb`.
3. In `config/.env`:
   ```
   POSTGRES_URL=postgresql://hermes_ro:strong-random@db-host:5432/mydb
   ```
4. In `config/mcp.toml`:
   ```toml
   [postgres]
   enabled = true
   ```
5. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-postgres` inside the hermes container.
- Registers it with Hermes; `POSTGRES_URL` is passed through.

## Verify
```bash
docker exec hermes hermes mcp test postgres
```

## Security notes
- Always use a read-only DB user unless you specifically want the agent to modify data.
- Hermes will see *any* data the DB user can read — don't grant SELECT on tables containing secrets, PII, or unencrypted credentials.
```

- [ ] **Step 7: `docs/mcp/docker_mcp.md`**

```markdown
# Docker MCP — ⚠️ host-level access

Inspect host containers and read logs.

## Risk
This MCP mounts `/var/run/docker.sock` into the hermes container. Anyone who can talk to the Docker daemon can effectively become root on the host. The script refuses to enable this MCP unless you explicitly acknowledge.

## What you need to do by hand
1. Read the risk section above. Understand that enabling this gives the agent (and anyone who can prompt-inject it) root-equivalent access to the VPS.
2. In `config/mcp.toml`:
   ```toml
   [docker_mcp]
   enabled = true
   acknowledge_socket_risk = true
   ```
3. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-docker` inside the hermes container.
- Registers it with Hermes; the daemon socket is mounted via the compose volume (added by the script if needed).

## Verify
```bash
docker exec hermes hermes mcp test docker_mcp
```

## Disable
Set both `enabled = false` and `acknowledge_socket_risk = false`, then re-run `./scripts/setup-mcp.sh`. The script un-registers the MCP.
```

- [ ] **Step 8: Commit**

```bash
git add docs/mcp/
git commit -m "docs: per-MCP token instructions for all 7 dev-stack MCPs

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 23: Final smoke + tests README

**Files:**
- Create: `tests/README.md`

- [ ] **Step 1: Write `tests/README.md`**

```markdown
# Tests

## Layout

- `unit/` — pure-bash tests for `scripts/lib/` (log, checks, write_file, toml). Run with `bats tests/unit` on the host.
- `integration/` — full setup scripts inside the systemd-enabled Docker sandbox. Run with `make test-integration`.
- `helpers/` — bats helpers (`setup_suite`, `assertions`).
- `Dockerfile.ubuntu-systemd` — sandbox image (based on `jrei/systemd-ubuntu:22.04`).
- `run-tests.sh` — entrypoint that builds the image (if missing), starts the container, mounts the repo, runs bats.

## Idempotency invariant

The whole project is built around one rule: every script's **second consecutive run** must:
- exit 0
- emit only `[SKIP]` lines
- emit zero `[ACT]` or `[OK]` lines

The `assert_idempotent` helper enforces this. If you add a new step to any script, add a test that runs the script twice and asserts the invariant — otherwise you'll silently regress idempotency.

## Known limitations of the sandbox

- **UFW**: rules are added to the container's network namespace, not the host's. We test that `ufw status` reports the rules — not that the kernel actually blocks traffic. That's an acceptable trade-off; the production verification is "after `setup-server.sh` on a real VPS, port 23 should be unreachable from the internet".
- **Docker-in-Docker**: the sandbox uses the host's Docker daemon via socket-mount in some tests; in others, we mock `docker` entirely via a stub on `$PATH`. Avoid running tests that mutate the host Docker state — they should always use the stub.
- **fail2ban**: starts inside the container but can't actually ban IPs (no real attack traffic). We only check `systemctl is-active`.
- **Hermes image pull**: the upstream image may not exist; tests stub `docker pull` to force the fallback path.

## Adding a new MCP

1. Add a section to `config/mcp.toml.example`.
2. Add `docs/mcp/<name>.md` following the template in the others.
3. If new transport semantics are needed, extend `deploy_*_mcp` in `scripts/setup-mcp.sh`.
4. Add an integration test that toggles `[<name>] enabled = true`, runs `setup-mcp.sh` twice, and asserts idempotency.
```

- [ ] **Step 2: Final full test run**

```bash
make test
```

Expected: all unit + integration tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/README.md
git commit -m "docs: tests README with idempotency invariant + sandbox limitations

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Done

After all 23 tasks:
- `scripts/setup-server.sh`, `scripts/setup-hermes.sh`, `scripts/setup-mcp.sh` — three idempotent scripts.
- `scripts/lib/{log,checks,write_file,toml}.sh` — small shared library, unit-tested.
- `config/{mcp.toml.example,.env.example,docker-compose.yml,docker-compose.mcp.yml}` — config templates.
- `docker/Dockerfile.hermes` — fallback image build.
- `docs/{01-server-setup,02-hermes-setup}.md` + `docs/mcp/*.md` — manual instructions for every step that can't be automated.
- `tests/` — bats unit tests + Docker-sandboxed integration tests, enforcing the idempotency invariant on every script.

### Manual smoke (after first successful CI run)

1. Spin up a real Debian 12 VPS at any provider, paste your SSH key.
2. `ssh root@<ip>`, clone the repo, `sudo ./scripts/setup-server.sh`.
3. Open a SECOND ssh session as `hermes` to confirm SSH hardening didn't lock you out.
4. As `hermes`: edit `config/.env` (one LLM key), run `./scripts/setup-hermes.sh`.
5. `docker exec -it hermes hermes chat` — confirm a model response.
6. Run each script a second time — should only emit `[SKIP]`.
