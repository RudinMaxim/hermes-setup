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

## Running tests locally

```bash
# Unit tests (Linux/macOS host with bats installed):
make test-unit

# Integration tests (requires Docker Hub access for jrei/systemd-ubuntu):
make test-integration

# Both:
make test
```

On Windows Git Bash, some unit tests auto-skip when filesystem permission bits aren't enforced (NTFS via the Git Bash unix-emulation layer). The Linux sandbox is authoritative.

## Adding a new MCP

1. Add a section to `config/mcp.toml.example`.
2. Add `docs/mcp/<name>.md` following the template in the others.
3. If new transport semantics are needed, extend `deploy_*_mcp` in `scripts/setup-mcp.sh`.
4. Add an integration test that toggles `[<name>] enabled = true`, runs `setup-mcp.sh` twice, and asserts idempotency.
