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
git clone https://github.com/RudinMaxim/hermes-setup.git hermes-setup
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
