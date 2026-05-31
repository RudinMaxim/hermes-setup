# Hermes Gateways Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a config-driven Telegram gateway plus an interactive-initialization layer (TTY-gated secret prompts + a thin `setup.sh` orchestrator) to the existing idempotent hermes-setup tool.

**Architecture:** A new `scripts/setup-gateway.sh` (run by the `hermes` user) reads `config/gateways.toml`, validates the Telegram token via `getMe`, and flips the container's PID 1 to `hermes gateway run` through a compose override. New pure helpers (`set_env_value`, `is_numeric_csv`, `read_env_value`, `telegram_getme_username`) are unit-tested on the host. Existing scripts gain TTY-gated prompts that write missing secrets to the gitignored `.env`; a thin `setup.sh` chains the hermes-side scripts. The non-interactive path (current `die` behaviour) is unchanged, so idempotency is preserved — prompts fire only when a value is absent.

**Tech Stack:** Bash (strict mode, `IFS=$'\n\t'`), awk-based parsers, docker compose v2, Bats-core tests (unit on host, integration in a privileged Ubuntu sandbox with PATH-override stubs for `docker`/`curl`).

---

## File Structure

**Create:**
- `scripts/lib/prompt.sh` — interactive primitives + `set_env_value` (idempotent `.env` upsert).
- `scripts/lib/telegram.sh` — `telegram_getme_username` JSON parser.
- `scripts/setup-gateway.sh` — gateway sync script (Telegram phase 1).
- `setup.sh` — thin hermes-side orchestrator (repo root).
- `config/gateways.toml.example` — `[telegram]` + `[webui]` stub.
- `config/docker-compose.gateway.yml` — override: `command = hermes gateway run`.
- `docs/gateways/telegram.md` — manual steps (BotFather, privacy mode, finding user IDs).
- `tests/unit/test_prompt.bats` — `set_env_value`, `is_interactive`.
- `tests/unit/test_telegram.bats` — `telegram_getme_username`, `is_numeric_csv`, `read_env_value`.
- `tests/integration/test_gateway_setup.bats` — up / bad token / non-numeric allowlist / rollback / idempotency with docker+curl stubs.

**Modify:**
- `scripts/lib/checks.sh` — add `is_numeric_csv`, `read_env_value`.
- `scripts/setup-hermes.sh` — add `ENVFILE`, source `prompt.sh`, interactive `ensure_llm_key`, init `gateways.toml`, accept `--non-interactive`.
- `scripts/setup-mcp.sh` — accept (and ignore) `--non-interactive` for orchestrator compatibility.
- `docs/02-hermes-setup.md` — link gateways + interactive mode.
- `README.md` — `./setup.sh` quick path + optional gateways.

---

## Task 1: `is_numeric_csv` + `read_env_value` in checks.sh

**Files:**
- Modify: `scripts/lib/checks.sh` (append at end)
- Test: `tests/unit/test_checks.bats` (append) and new `tests/unit/test_telegram.bats` covers these too; we put the unit tests here in `test_checks.bats` since the functions live in `checks.sh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_checks.bats`:

```bash
@test "is_numeric_csv accepts a single numeric id" {
  run is_numeric_csv "123"
  [ "$status" -eq 0 ]
}

@test "is_numeric_csv accepts comma-separated numeric ids" {
  run is_numeric_csv "123,456,789"
  [ "$status" -eq 0 ]
}

@test "is_numeric_csv rejects non-numeric content" {
  run is_numeric_csv "123,abc"
  [ "$status" -eq 1 ]
}

@test "is_numeric_csv rejects empty string" {
  run is_numeric_csv ""
  [ "$status" -eq 1 ]
}

@test "is_numeric_csv rejects trailing comma" {
  run is_numeric_csv "12,"
  [ "$status" -eq 1 ]
}

@test "read_env_value prints the value for a key" {
  local tmp; tmp=$(mktemp)
  echo "FOO=bar" > "$tmp"
  run read_env_value "$tmp" FOO
  [ "$status" -eq 0 ]
  [ "$output" = "bar" ]
  rm -f "$tmp"
}

@test "read_env_value ignores commented lines" {
  local tmp; tmp=$(mktemp)
  printf '# FOO=commented\nFOO=actual\n' > "$tmp"
  run read_env_value "$tmp" FOO
  [ "$status" -eq 0 ]
  [ "$output" = "actual" ]
  rm -f "$tmp"
}

@test "read_env_value exits 1 when key absent" {
  local tmp; tmp=$(mktemp)
  echo "BAR=baz" > "$tmp"
  run read_env_value "$tmp" FOO
  [ "$status" -eq 1 ]
  rm -f "$tmp"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_checks.bats`
Expected: the 8 new tests FAIL with `command not found: is_numeric_csv` / `read_env_value`.

- [ ] **Step 3: Implement the functions**

Append to `scripts/lib/checks.sh`:

```bash
# is_numeric_csv "123,456" -> 0 ; "123,abc" / "" / "12," -> 1
is_numeric_csv() {
  local v="$1"
  [[ -n "$v" ]] || return 1
  [[ "$v" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

# read_env_value FILE KEY -> prints the value (comments/whitespace stripped),
# exit 1 if the key is absent. Complements env_var_set_in_file (boolean only).
# awk with a literal key match — no regex injection from $key.
read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v k="$key" '
    {
      sub(/^[[:space:]]+/, "")
      if ($0 ~ /^#/) next
      eq = index($0, "=")
      if (eq == 0) next
      lhs = substr($0, 1, eq-1); sub(/[[:space:]]+$/, "", lhs)
      if (lhs != k) next
      rhs = substr($0, eq+1)
      sub(/^[[:space:]]+/, "", rhs); sub(/[[:space:]]+$/, "", rhs)
      print rhs; found = 1; exit
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_checks.bats`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/checks.sh tests/unit/test_checks.bats
git commit -m "feat(checks): add is_numeric_csv and read_env_value helpers"
```

---

## Task 2: `set_env_value` + `is_interactive` in prompt.sh

**Files:**
- Create: `scripts/lib/prompt.sh`
- Test: `tests/unit/test_prompt.bats`

`set_env_value` depends on `read_env_value` (Task 1), so tests source both libs.

- [ ] **Step 1: Write the failing tests**

Create `tests/unit/test_prompt.bats`:

```bash
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
  # shellcheck source=/dev/null
  source "$LIB/checks.sh"
  # shellcheck source=/dev/null
  source "$LIB/prompt.sh"
}

@test "set_env_value appends a new key" {
  local tmp; tmp=$(mktemp)
  echo "EXISTING=1" > "$tmp"
  run set_env_value "$tmp" NEWKEY hello
  [ "$status" -eq 0 ]
  run read_env_value "$tmp" NEWKEY
  [ "$output" = "hello" ]
  rm -f "$tmp"
}

@test "set_env_value replaces an existing key" {
  local tmp; tmp=$(mktemp)
  printf 'FOO=old\nBAR=keep\n' > "$tmp"
  run set_env_value "$tmp" FOO new
  [ "$status" -eq 0 ]
  run read_env_value "$tmp" FOO
  [ "$output" = "new" ]
  run read_env_value "$tmp" BAR
  [ "$output" = "keep" ]
  rm -f "$tmp"
}

@test "set_env_value returns 1 and does not rewrite when value unchanged" {
  local tmp; tmp=$(mktemp)
  echo "FOO=same" > "$tmp"
  local before; before=$(cat "$tmp")
  run set_env_value "$tmp" FOO same
  [ "$status" -eq 1 ]
  [ "$(cat "$tmp")" = "$before" ]
  rm -f "$tmp"
}

@test "set_env_value preserves special characters in the value verbatim" {
  local tmp; tmp=$(mktemp)
  : > "$tmp"
  set_env_value "$tmp" POSTGRES_URL 'postgresql://u:p@h:5432/db?x=1&y=2'
  run read_env_value "$tmp" POSTGRES_URL
  [ "$output" = 'postgresql://u:p@h:5432/db?x=1&y=2' ]
  rm -f "$tmp"
}

@test "set_env_value does not match a commented key (appends instead)" {
  local tmp; tmp=$(mktemp)
  printf '# FOO=commented\n' > "$tmp"
  run set_env_value "$tmp" FOO real
  [ "$status" -eq 0 ]
  run read_env_value "$tmp" FOO
  [ "$output" = "real" ]
  # the comment line is still present
  grep -q '^# FOO=commented$' "$tmp"
  rm -f "$tmp"
}

@test "is_interactive is false when HERMES_NONINTERACTIVE=1" {
  HERMES_NONINTERACTIVE=1 run is_interactive
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_prompt.bats`
Expected: FAIL — `prompt.sh` does not exist / functions undefined.

- [ ] **Step 3: Create `scripts/lib/prompt.sh`**

```bash
# shellcheck shell=bash
# Interactive primitives + idempotent .env upsert.
# Requires log.sh and checks.sh (read_env_value) sourced beforehand.

# is_interactive -> 0 only when both stdin/stdout are TTYs and the caller has
# not forced non-interactive mode. assert_idempotent and the sandbox run with
# HERMES_NONINTERACTIVE=1, so prompts never fire there.
is_interactive() {
  [[ -t 0 && -t 1 && "${HERMES_NONINTERACTIVE:-}" != 1 ]]
}

# prompt_value PROMPT -> echoes a plain (visible) line of input.
prompt_value() {
  local p="$1" out
  read -r -p "$p: " out
  printf '%s' "$out"
}

# prompt_secret PROMPT -> echoes a hidden line of input (no terminal echo).
prompt_secret() {
  local p="$1" out
  read -rs -p "$p: " out
  echo >&2
  printf '%s' "$out"
}

# confirm PROMPT -> 0 on y/Y, 1 otherwise.
confirm() {
  local p="$1" a
  read -r -p "$p [y/N]: " a
  [[ "$a" =~ ^[Yy] ]]
}

# set_env_value FILE KEY VALUE
# Idempotent upsert of a KEY=VALUE line. If KEY already equals VALUE, the file
# is left untouched and the function returns 1 ("no change"). Otherwise the
# first uncommented KEY= line is replaced (or the pair appended) and it returns
# 0. KEY and VALUE are passed via the environment (ENVIRON) so awk performs no
# escape processing — values with =, &, /, ? are stored verbatim.
set_env_value() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" ]] || : >"$file"

  local current
  if current=$(read_env_value "$file" "$key" 2>/dev/null) && [[ "$current" == "$value" ]]; then
    return 1
  fi

  local tmp; tmp=$(mktemp)
  SEV_K="$key" SEV_V="$value" awk '
    BEGIN { k = ENVIRON["SEV_K"]; v = ENVIRON["SEV_V"]; done = 0 }
    {
      line = $0
      probe = line; sub(/^[[:space:]]+/, "", probe)
      if (!done && probe !~ /^#/) {
        eq = index(line, "=")
        if (eq > 0) {
          lhs = substr(line, 1, eq-1)
          sub(/^[[:space:]]+/, "", lhs); sub(/[[:space:]]+$/, "", lhs)
          if (lhs == k) { print k "=" v; done = 1; next }
        }
      }
      print line
    }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"

  # Overwrite contents in place so the existing 0600 perms/owner are preserved.
  cat "$tmp" >"$file"
  rm -f "$tmp"
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_prompt.bats`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/prompt.sh tests/unit/test_prompt.bats
git commit -m "feat(prompt): add is_interactive, prompts, and set_env_value upsert"
```

---

## Task 3: `telegram_getme_username` in telegram.sh

**Files:**
- Create: `scripts/lib/telegram.sh`
- Test: `tests/unit/test_telegram.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/unit/test_telegram.bats`:

```bash
#!/usr/bin/env bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../../scripts/lib"
  # shellcheck source=/dev/null
  source "$LIB/telegram.sh"
}

@test "telegram_getme_username extracts username on ok:true" {
  run telegram_getme_username '{"ok":true,"result":{"id":42,"username":"my_bot"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "my_bot" ]
}

@test "telegram_getme_username handles a space after the colon" {
  run telegram_getme_username '{"ok": true,"result":{"username":"spaced_bot"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "spaced_bot" ]
}

@test "telegram_getme_username fails on ok:false" {
  run telegram_getme_username '{"ok":false,"error_code":401,"description":"Unauthorized"}'
  [ "$status" -eq 1 ]
}

@test "telegram_getme_username fails on garbage" {
  run telegram_getme_username 'not json at all'
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/unit/test_telegram.bats`
Expected: FAIL — `telegram.sh` does not exist.

- [ ] **Step 3: Create `scripts/lib/telegram.sh`**

```bash
# shellcheck shell=bash
# Telegram-specific pure helpers (unit-testable, no network).

# telegram_getme_username '<getMe-json>' -> prints the bot username and exits 0
# when the response has "ok":true; exits 1 otherwise.
telegram_getme_username() {
  local json="$1"
  grep -q '"ok":[[:space:]]*true' <<<"$json" || return 1
  sed -n 's/.*"username":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/unit/test_telegram.bats`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/telegram.sh tests/unit/test_telegram.bats
git commit -m "feat(telegram): add getMe username parser"
```

---

## Task 4: Gateway config files

**Files:**
- Create: `config/gateways.toml.example`
- Create: `config/docker-compose.gateway.yml`

No automated test — these are static config read by later tasks. Verified by a manual `toml_get_bool` check in Step 3.

- [ ] **Step 1: Create `config/gateways.toml.example`**

```toml
# config/gateways.toml.example
# Copy to config/gateways.toml and flip `enabled` for the gateway you want.
# Secrets live in config/.env, NOT here.

[telegram]
# Daily access via a Telegram bot. Requires TELEGRAM_BOT_TOKEN and a numeric,
# comma-separated TELEGRAM_ALLOWED_USERS in config/.env (default-deny).
# See docs/gateways/telegram.md for BotFather setup and how to find your user ID.
enabled = false
requires = ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS"]

[webui]
# Phase 2 — NOT implemented yet. setup-gateway.sh warns and ignores enabled=true.
# domain empty  -> localhost only, reach via `ssh -L 8080:localhost:8080`
# domain set    -> Caddy reverse-proxy with Let's Encrypt HTTPS (needs DNS A record)
enabled = false
domain  = ""
requires = []
```

- [ ] **Step 2: Create `config/docker-compose.gateway.yml`**

```yaml
# config/docker-compose.gateway.yml
# Override merged on top of docker-compose.yml by scripts/setup-gateway.sh when a
# messaging gateway is enabled. Replaces the container command with the
# foreground gateway runner so `hermes gateway run` becomes PID 1.
#
#   docker compose -f config/docker-compose.yml -f config/docker-compose.gateway.yml up -d
#
# TELEGRAM_BOT_TOKEN / TELEGRAM_ALLOWED_USERS are already injected via the base
# compose `env_file: ./.env`, so no extra env wiring is needed here.
services:
  hermes:
    command: ["hermes", "gateway", "run"]
```

- [ ] **Step 3: Verify the toml parses**

Run:
```bash
cp config/gateways.toml.example /tmp/gw.toml
bash -c 'source scripts/lib/toml.sh; toml_get_bool /tmp/gw.toml telegram enabled && echo ENABLED || echo DISABLED'
```
Expected: prints `DISABLED` (enabled = false), exit 0.

- [ ] **Step 4: Commit**

```bash
git add config/gateways.toml.example config/docker-compose.gateway.yml
git commit -m "feat(config): add gateways.toml.example and gateway compose override"
```

---

## Task 5: Interactive `ensure_llm_key` + gateways.toml init in setup-hermes.sh

**Files:**
- Modify: `scripts/setup-hermes.sh`
- Test: `tests/integration/test_hermes_setup.bats` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/integration/test_hermes_setup.bats`:

```bash
@test "setup-hermes.sh creates gateways.toml from the example" {
  rm -f "$REPO_ROOT/config/.env" "$REPO_ROOT/config/mcp.toml" "$REPO_ROOT/config/gateways.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/config/gateways.toml" ]
}

@test "setup-hermes.sh still dies without an LLM key in non-interactive mode" {
  : > "$REPO_ROOT/config/.env"
  run su hermes -c "HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-hermes.sh' --configs-only"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no LLM API key configured"* ]]
}

@test "setup-hermes.sh accepts the --non-interactive flag" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  run su hermes -c "bash '$SCRIPTS/setup-hermes.sh' --configs-only --non-interactive"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/integration/test_hermes_setup.bats` (sandbox only — see tests/README.md)
Expected: the gateways.toml test FAILs (file not created); the `--non-interactive` test FAILs with `unknown argument: --non-interactive`.

- [ ] **Step 3: Apply the modifications**

In `scripts/setup-hermes.sh`, add the `ENVFILE` definition and source `prompt.sh`. Change the `CONFIG_DIR=` line block (lines 11-18) to:

```bash
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
```

Replace the argument-parsing loop (lines 20-26) with one that also accepts `--non-interactive`:

```bash
CONFIGS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --configs-only)    CONFIGS_ONLY=1 ;;
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
```

In `ensure_configs()`, after the `mcp.toml` block (after line 58, before the closing `}`), add gateways.toml init:

```bash
  if [[ ! -f "$CONFIG_DIR/gateways.toml" ]]; then
    log_act "copying gateways.toml.example -> gateways.toml"
    cp "$CONFIG_DIR/gateways.toml.example" "$CONFIG_DIR/gateways.toml"
    log_ok "gateways.toml created"
  else
    log_skip "gateways.toml already exists"
  fi
```

Replace `ensure_llm_key()` (lines 61-68) entirely with the interactive version:

```bash
ensure_llm_key() {
  if env_var_set_in_file "$ENVFILE" OPENAI_API_KEY \
     || env_var_set_in_file "$ENVFILE" ANTHROPIC_API_KEY; then
    log_ok "LLM API key present in .env"
    return 0
  fi
  if is_interactive; then
    local provider var key
    provider=$(prompt_value "LLM provider (openai/anthropic)")
    case "$provider" in
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
  die "no LLM API key configured — set OPENAI_API_KEY or ANTHROPIC_API_KEY in $ENVFILE (see docs/02-hermes-setup.md)"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/integration/test_hermes_setup.bats`
Expected: all tests PASS (existing + 3 new). The existing "fails when no LLM key" test still passes because the sandbox has no TTY (`is_interactive` is false there).

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-hermes.sh tests/integration/test_hermes_setup.bats
git commit -m "feat(hermes): interactive LLM-key prompt, gateways.toml init, --non-interactive"
```

---

## Task 6: `scripts/setup-gateway.sh`

**Files:**
- Create: `scripts/setup-gateway.sh`
- Test: `tests/integration/test_gateway_setup.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/integration/test_gateway_setup.bats`:

```bash
#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

STUB=/tmp/gw-bin-stub
STATE=/tmp/.gw-stub-cmd

setup() {
  id hermes &>/dev/null || useradd -m -s /bin/bash hermes
  mkdir -p "$STUB"
  rm -f "$STATE"

  # docker stub: models PID-1 command via $STATE, reports container running.
  cat >"$STUB/docker" <<'DOCKER'
#!/usr/bin/env bash
STATE=/tmp/.gw-stub-cmd
case "$*" in
  "inspect -f "*"State.Status"*)  echo running ;;
  "inspect -f "*"Config.Cmd"*)    [[ -f "$STATE" ]] && cat "$STATE" || echo hermes ;;
  *"docker-compose.gateway.yml up -d"*) echo "hermes gateway run" >"$STATE"; echo up ;;
  *"up -d --force-recreate"*)     echo "hermes" >"$STATE"; echo recreated ;;
  "exec hermes hermes gateway status"*) exit 0 ;;
  *) echo "stub: $*" ;;
esac
DOCKER
  chmod +x "$STUB/docker"

  # curl stub: returns $GETME_RESPONSE for getMe URLs.
  cat >"$STUB/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
  *getMe*) printf '%s' "${GETME_RESPONSE:-{\"ok\":true,\"result\":{\"username\":\"test_bot\"}}}" ;;
  *) exit 1 ;;
esac
CURL
  chmod +x "$STUB/curl"

  # Fresh gateways.toml + .env owned by hermes.
  cp "$REPO_ROOT/config/gateways.toml.example" "$REPO_ROOT/config/gateways.toml"
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/gateways.toml" "$REPO_ROOT/config/.env"
}

teardown() {
  rm -rf "$STUB" "$STATE"
  rm -f "$REPO_ROOT/config/gateways.toml"
}

enable_telegram() {
  sed -i 's|^enabled = false|enabled = true|' "$REPO_ROOT/config/gateways.toml"
  printf 'TELEGRAM_BOT_TOKEN=123:ABC\nTELEGRAM_ALLOWED_USERS=111,222\n' >> "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/.env" "$REPO_ROOT/config/gateways.toml"
}

@test "setup-gateway.sh brings up the telegram gateway when enabled + valid" {
  enable_telegram
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"telegram gateway is up"* ]]
  grep -q 'gateway run' "$STATE"
}

@test "setup-gateway.sh dies on an invalid token" {
  enable_telegram
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 GETME_RESPONSE='{\"ok\":false}' bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected the token"* ]]
}

@test "setup-gateway.sh dies on a non-numeric allowlist (before any network call)" {
  sed -i 's|^enabled = false|enabled = true|' "$REPO_ROOT/config/gateways.toml"
  printf 'TELEGRAM_BOT_TOKEN=123:ABC\nTELEGRAM_ALLOWED_USERS=abc\n' >> "$REPO_ROOT/config/.env"
  chown hermes "$REPO_ROOT/config/.env" "$REPO_ROOT/config/gateways.toml"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"comma-separated numeric"* ]]
}

@test "setup-gateway.sh is idempotent when telegram stays enabled" {
  enable_telegram
  assert_idempotent su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
}

@test "setup-gateway.sh rolls back to idle when telegram is disabled" {
  enable_telegram
  su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  grep -q 'gateway run' "$STATE"
  # now disable
  sed -i 's|^enabled = true|enabled = false|' "$REPO_ROOT/config/gateways.toml"
  chown hermes "$REPO_ROOT/config/gateways.toml"
  run su hermes -c "PATH=$STUB:\$PATH HERMES_NONINTERACTIVE=1 bash '$SCRIPTS/setup-gateway.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"back to idle"* ]]
  ! grep -q 'gateway run' "$STATE"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/integration/test_gateway_setup.bats`
Expected: FAIL — `setup-gateway.sh` does not exist.

- [ ] **Step 3: Create `scripts/setup-gateway.sh`**

```bash
#!/usr/bin/env bash
# scripts/setup-gateway.sh — Idempotently sync messaging gateways from
# config/gateways.toml. Phase 1: Telegram. Runs as the 'hermes' user.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
GW_TOML="$CONFIG_DIR/gateways.toml"
ENVFILE="$CONFIG_DIR/.env"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/toml.sh
source "$SCRIPT_DIR/lib/toml.sh"
# shellcheck source=lib/telegram.sh
source "$SCRIPT_DIR/lib/telegram.sh"
# shellcheck source=lib/prompt.sh
source "$SCRIPT_DIR/lib/prompt.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_files() {
  [[ -f "$GW_TOML" ]] || die "missing $GW_TOML — run scripts/setup-hermes.sh first"
  [[ -f "$ENVFILE" ]] || die "missing $ENVFILE"
}

require_hermes_running() {
  docker_container_running hermes \
    || die "hermes container is not running — run scripts/setup-hermes.sh first"
}

gateway_enabled() {
  toml_get_bool "$GW_TOML" "$1" enabled
}

# True when PID 1 of the hermes container is `hermes gateway run`.
telegram_gateway_active() {
  docker inspect -f '{{join .Config.Cmd " "}}' hermes 2>/dev/null \
    | grep -q 'gateway run'
}

# Interactive fill: if a required Telegram value is missing and we have a TTY,
# prompt for it and write it to .env. No-op when values present or non-interactive.
maybe_prompt_telegram() {
  is_interactive || return 0
  if ! env_var_set_in_file "$ENVFILE" TELEGRAM_BOT_TOKEN; then
    local token
    token=$(prompt_secret "TELEGRAM_BOT_TOKEN")
    [[ -n "$token" ]] || die "empty token entered — aborting"
    log_act "saving TELEGRAM_BOT_TOKEN to .env"
    set_env_value "$ENVFILE" TELEGRAM_BOT_TOKEN "$token" >/dev/null
    log_ok "TELEGRAM_BOT_TOKEN saved to .env (${#token} chars)"
  fi
  if ! env_var_set_in_file "$ENVFILE" TELEGRAM_ALLOWED_USERS; then
    local allow
    allow=$(prompt_value "TELEGRAM_ALLOWED_USERS (comma-separated numeric user IDs — see docs/gateways/telegram.md)")
    log_act "saving TELEGRAM_ALLOWED_USERS to .env"
    set_env_value "$ENVFILE" TELEGRAM_ALLOWED_USERS "$allow" >/dev/null
    log_ok "TELEGRAM_ALLOWED_USERS saved to .env"
  fi
}

# Read-only validation. getMe is logged as a state check ([SKIP]), never [ACT],
# so the idempotency invariant holds on repeat runs.
validate_telegram() {
  local token allow resp uname count
  token=$(read_env_value "$ENVFILE" TELEGRAM_BOT_TOKEN) \
    || die "TELEGRAM_BOT_TOKEN missing in .env — see docs/gateways/telegram.md"
  allow=$(read_env_value "$ENVFILE" TELEGRAM_ALLOWED_USERS) || allow=""

  is_numeric_csv "$allow" \
    || die "TELEGRAM_ALLOWED_USERS must be comma-separated numeric IDs (got: '$allow') — see docs/gateways/telegram.md"

  resp=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getMe") \
    || die "Telegram getMe request failed — token invalid or no network"
  uname=$(telegram_getme_username "$resp") \
    || die "Telegram rejected the token (ok != true) — check TELEGRAM_BOT_TOKEN"
  count=$(tr ',' '\n' <<<"$allow" | grep -c .)
  log_skip "telegram token valid: bot @${uname}, allowlist has ${count} user(s)"
}

wait_for_gateway() {
  local i
  for i in $(seq 1 30); do
    if docker exec hermes hermes gateway status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log_warn "telegram gateway did not report healthy in 30s — recent logs:"
  docker logs --tail=50 hermes || true
  die "gateway health gate failed"
}

ensure_telegram() {
  maybe_prompt_telegram
  validate_telegram
  if telegram_gateway_active; then
    log_skip "telegram gateway already running (PID1 = hermes gateway run)"
    return 0
  fi
  log_act "starting telegram gateway (recreating container with gateway command)"
  docker compose -f "$CONFIG_DIR/docker-compose.yml" \
                 -f "$CONFIG_DIR/docker-compose.gateway.yml" up -d >/dev/null
  wait_for_gateway
  log_ok "telegram gateway is up — message your bot to test"
}

ensure_telegram_off() {
  if ! telegram_gateway_active; then
    log_skip "telegram gateway not running"
    return 0
  fi
  log_act "disabling telegram gateway (recreating container without gateway command)"
  docker compose -f "$CONFIG_DIR/docker-compose.yml" up -d --force-recreate >/dev/null
  log_ok "telegram gateway stopped; container back to idle/CLI mode"
}

main() {
  require_files
  require_hermes_running

  if gateway_enabled telegram; then
    ensure_telegram
  else
    ensure_telegram_off
  fi

  if gateway_enabled webui; then
    log_warn "webui gateway is Phase 2 — not implemented yet, ignoring [webui] enabled=true"
  fi

  log_ok "gateway sync complete"
}

main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/integration/test_gateway_setup.bats`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-gateway.sh tests/integration/test_gateway_setup.bats
git commit -m "feat(gateway): add config-driven Telegram gateway setup script"
```

---

## Task 7: Thin `setup.sh` orchestrator + setup-mcp.sh flag

**Files:**
- Create: `setup.sh` (repo root)
- Modify: `scripts/setup-mcp.sh`
- Test: `tests/integration/test_gateway_setup.bats` (append one orchestrator smoke test)

- [ ] **Step 1: Write the failing test**

Append to `tests/integration/test_gateway_setup.bats`:

```bash
@test "setup.sh runs the hermes step non-interactively and warns when run as root" {
  cp "$REPO_ROOT/config/.env.example" "$REPO_ROOT/config/.env"
  sed -i 's|^OPENAI_API_KEY=|OPENAI_API_KEY=sk-test|' "$REPO_ROOT/config/.env"
  # Run as root with --non-interactive: should warn about root, run setup-hermes
  # in --configs-only-equivalent path far enough to print the root warning, then
  # stop at the docker steps (no docker stub configured for hermes here).
  run env HERMES_NONINTERACTIVE=1 bash "$REPO_ROOT/setup.sh" --non-interactive --configs-only
  [[ "$output" == *"run setup-server.sh as root separately"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/test_gateway_setup.bats -f "setup.sh runs"`
Expected: FAIL — `setup.sh` does not exist.

- [ ] **Step 3: Create `setup.sh`**

```bash
#!/usr/bin/env bash
# setup.sh — Thin hermes-side orchestrator. Runs the unprivileged setup steps in
# order and (interactively) offers the optional gateway / MCP steps. The server
# step is root-only and one-off, so it is NOT included here — run
# scripts/setup-server.sh as root separately.
#
# Flags are passed through to the child scripts. --non-interactive (or
# HERMES_NONINTERACTIVE=1) disables every prompt.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/scripts/lib/log.sh"
# shellcheck source=scripts/lib/prompt.sh
source "$SCRIPT_DIR/scripts/lib/checks.sh"
# shellcheck source=scripts/lib/prompt.sh
source "$SCRIPT_DIR/scripts/lib/prompt.sh"

for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
  esac
done

main() {
  [[ $EUID -ne 0 ]] \
    || log_warn "setup.sh is the hermes-side orchestrator — run setup-server.sh as root separately, then re-run this as the 'hermes' user"

  log_act "running setup-hermes.sh"
  bash "$SCRIPT_DIR/scripts/setup-hermes.sh" "$@"

  if is_interactive && confirm "Configure a messaging gateway (Telegram) now?"; then
    bash "$SCRIPT_DIR/scripts/setup-gateway.sh" "$@"
  fi

  if is_interactive && confirm "Sync MCP servers from mcp.toml now?"; then
    bash "$SCRIPT_DIR/scripts/setup-mcp.sh" "$@"
  fi

  log_ok "setup complete"
}

main "$@"
```

Note: `setup-hermes.sh` already accepts `--configs-only` and `--non-interactive`; passing `"$@"` through is safe. When invoked non-interactively the two `confirm` blocks are skipped, so `setup.sh` only runs the hermes step (gateway/MCP are then expected to be driven directly or on a later interactive run).

- [ ] **Step 4: Make setup-mcp.sh accept --non-interactive**

In `scripts/setup-mcp.sh`, immediately after the `source` lines (after line 19), insert an argument-parsing loop:

```bash
for arg in "$@"; do
  case "$arg" in
    --non-interactive) export HERMES_NONINTERACTIVE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
```

(`setup-mcp.sh` has no prompts of its own yet; the flag is accepted for orchestrator compatibility so the passthrough `"$@"` does not abort.)

- [ ] **Step 5: Set the executable bit and run the test**

```bash
git update-index --add --chmod=+x setup.sh
chmod +x setup.sh
bats tests/integration/test_gateway_setup.bats -f "setup.sh runs"
```
Expected: PASS — output contains the root warning.

- [ ] **Step 6: Commit**

```bash
git add setup.sh scripts/setup-mcp.sh tests/integration/test_gateway_setup.bats
git commit -m "feat(setup): thin hermes-side orchestrator + setup-mcp --non-interactive"
```

---

## Task 8: Documentation

**Files:**
- Create: `docs/gateways/telegram.md`
- Modify: `docs/02-hermes-setup.md`
- Modify: `README.md`

No automated test. Verify links resolve in Step 4.

- [ ] **Step 1: Create `docs/gateways/telegram.md`**

````markdown
# Telegram gateway

Daily access to Hermes through a Telegram bot. Config-driven via
`config/gateways.toml`; the token and allowlist live in `config/.env`.

## 1. Create the bot (manual, in Telegram)

1. Open a chat with [@BotFather](https://t.me/BotFather).
2. Send `/newbot`, pick a name and a username ending in `bot`.
3. BotFather replies with an **HTTP API token** like `123456789:AAH...`. Keep it secret.

## 2. Find your numeric user ID (manual)

The allowlist is by **numeric user ID**, not @username (default-deny — anyone
not listed is ignored).

1. Open a chat with [@userinfobot](https://t.me/userinfobot) (or @RawDataBot).
2. It replies with your `Id:` — a number like `111222333`.
3. Repeat for every person who should have access; join the IDs with commas.

## 3. Configure

You can let the setup script prompt you (interactive run), or edit files directly.

**Interactive:** run `./setup.sh` (or `./scripts/setup-gateway.sh`) in a terminal
— if the token/allowlist are missing it asks for them and writes `config/.env`
for you (the token is typed hidden, never echoed).

**Manual:** add to `config/.env`:
```
TELEGRAM_BOT_TOKEN=123456789:AAH...
TELEGRAM_ALLOWED_USERS=111222333,444555666
```
and enable the gateway in `config/gateways.toml`:
```toml
[telegram]
enabled = true
```

## 4. Apply

```bash
./scripts/setup-gateway.sh
```
The script validates the token (`getMe`), checks the allowlist is numeric, then
recreates the container with `hermes gateway run` as PID 1. Message your bot to
test. Re-running is safe — if nothing changed it only prints `[SKIP]`.

To turn it off: set `enabled = false` and re-run — the container returns to
idle/CLI mode.

## Privacy mode in groups (manual)

By default a bot in a group only sees messages that start with `/` (Telegram
"privacy mode"). To let it read all group messages: @BotFather → `/setprivacy`
→ select the bot → **Disable**. The numeric allowlist still filters senders the
same way in groups and in direct messages.
````

- [ ] **Step 2: Link from `docs/02-hermes-setup.md`**

Add a section near the end of `docs/02-hermes-setup.md` (after the MCP next-steps reference):

```markdown
## Optional: messaging gateways

For daily use without the CLI, enable a gateway in `config/gateways.toml` and run
`./scripts/setup-gateway.sh`. Phase 1 supports **Telegram** — see
[docs/gateways/telegram.md](gateways/telegram.md) for BotFather setup, finding
your user ID, and privacy mode.

## Interactive setup

Run `./setup.sh` from the repo root (as the `hermes` user) to chain the
hermes-side steps. In a terminal it prompts for any missing secrets (LLM key,
Telegram token) and writes them to `config/.env`; pass `--non-interactive` (or
set `HERMES_NONINTERACTIVE=1`) to disable all prompts for scripted runs.
```

- [ ] **Step 3: Update `README.md`**

Add a short "Quick start (interactive)" note and a gateways bullet. Insert after the existing setup-hermes step:

```markdown
### Quick start (interactive)

After `setup-server.sh` has run (as root), log in as `hermes` and run:

```bash
cd ~/hermes-setup && ./setup.sh
```

It prompts for your LLM API key (and optionally a Telegram bot token), then
brings Hermes up and offers the optional gateway / MCP steps. For scripted,
non-interactive use add `--non-interactive` and pre-fill `config/.env`.

### Optional: Telegram gateway

Enable `[telegram]` in `config/gateways.toml`, then `./scripts/setup-gateway.sh`.
See [docs/gateways/telegram.md](docs/gateways/telegram.md).
```

- [ ] **Step 4: Verify links resolve**

Run:
```bash
test -f docs/gateways/telegram.md && grep -q 'gateways/telegram.md' docs/02-hermes-setup.md README.md && echo OK
```
Expected: prints `OK`.

- [ ] **Step 5: Commit**

```bash
git add docs/gateways/telegram.md docs/02-hermes-setup.md README.md
git commit -m "docs: Telegram gateway guide + interactive setup notes"
```

---

## Task 9: Full regression run

**Files:** none (verification only)

- [ ] **Step 1: Run the unit suite on the host**

Run: `bats tests/unit/`
Expected: all unit tests PASS (existing + `test_prompt.bats` + `test_telegram.bats` + new `test_checks.bats` cases).

- [ ] **Step 2: Run the integration suite in the sandbox**

Run: `bash tests/run-tests.sh` (builds/launches the privileged Ubuntu sandbox; see `tests/README.md`)
Expected: all integration tests PASS, including the new `test_gateway_setup.bats`. If Docker Hub is unreachable on the dev host, run this step on the VPS instead and record the result.

- [ ] **Step 3: Commit any fixes**

If steps 1-2 surfaced issues, fix inline and commit with a descriptive message. Otherwise no commit needed.

---

## Self-Review Notes

- **Spec coverage:** `set_env_value`/`is_interactive`/prompts (Task 2), `is_numeric_csv`/`read_env_value` (Task 1), `telegram_getme_username` (Task 3), `gateways.toml.example` + `docker-compose.gateway.yml` (Task 4), interactive `ensure_llm_key` + gateways.toml init + `--non-interactive` (Task 5), `setup-gateway.sh` with validate/ensure/rollback/wait (Task 6), thin `setup.sh` + setup-mcp flag (Task 7), telegram.md + 02-hermes + README (Task 8), regression (Task 9). Phase 2 WebUI is intentionally out of scope (warned-and-ignored).
- **Idempotency:** every `ensure_*` is state-checked; `validate_telegram` logs `[SKIP]`; integration runs use `HERMES_NONINTERACTIVE=1`; `set_env_value` returns 1 (no write) when unchanged. `assert_idempotent` covers the gateway script.
- **Type/name consistency:** `GW_TOML`, `ENVFILE`, `telegram_gateway_active`, `gateway_enabled`, `set_env_value`, `read_env_value`, `is_numeric_csv`, `telegram_getme_username` are used identically across tasks.
- **Secrets:** tokens read via `prompt_secret` (no echo), logged only as `(N chars)`, written to the gitignored, 0600 `config/.env` (perms preserved by `cat >`).
````
