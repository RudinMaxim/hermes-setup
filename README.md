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

# 2. Clone and run the server preparation (creates 'hermes' user, installs
#    Docker, copies the repo to /home/hermes/hermes-setup, hardens SSH, enables UFW).
git clone https://github.com/RudinMaxim/hermes-setup.git
cd hermes-setup
sudo ./scripts/setup-server.sh

# If root has no SSH key (logged in with password), provide one for hermes:
#   HERMES_SSH_KEY="ssh-ed25519 AAAA... you@host" sudo ./scripts/setup-server.sh

# 3. Verify the new SSH login works from a SECOND terminal before closing root:
#   ssh hermes@<vps-ip>

# 4. Switch to hermes, fill the LLM key, launch Hermes.
su - hermes
cd ~/hermes-setup
nano config/.env          # set OPENAI_API_KEY=... or ANTHROPIC_API_KEY=...
./scripts/setup-hermes.sh

# 5. (Optional) Enable MCP servers:
nano config/mcp.toml      # toggle enabled = true for what you want
./scripts/setup-mcp.sh

# 6. (Optional) Enable a Telegram gateway for daily use:
nano config/gateways.toml # set [telegram] enabled = true
./scripts/setup-gateway.sh
```

`setup-hermes.sh` copies `config/.env.example` → `config/.env` automatically on first run if you skip step 4's `nano`; it will then abort with a clear message asking you to fill the key.

### Quick start (interactive)

Instead of steps 4–6, on the `hermes` user you can run the orchestrator:

```bash
cd ~/hermes-setup && ./setup.sh
```

In a terminal it prompts for your LLM API key (and, if you opt in, a Telegram bot
token), brings Hermes up, then offers the optional gateway / MCP steps. For
scripted, non-interactive use add `--non-interactive` and pre-fill `config/.env`.

## Documentation

- [`docs/01-server-setup.md`](docs/01-server-setup.md) — manual steps that aren't automated (provisioning, DNS, backups).
- [`docs/02-hermes-setup.md`](docs/02-hermes-setup.md) — how to fill in `.env`, troubleshoot, chat with the agent.
- [`docs/mcp/`](docs/mcp/) — one file per MCP server: where to get the token, what the script does for you.
- [`docs/gateways/telegram.md`](docs/gateways/telegram.md) — set up the Telegram gateway (BotFather, user IDs, privacy mode).
- [`docs/superpowers/specs/2026-05-30-hermes-setup-design.md`](docs/superpowers/specs/2026-05-30-hermes-setup-design.md) — full design rationale.

## Testing

```bash
make test-unit         # bats unit tests on host (fast)
make test-integration  # full scripts in systemd-enabled Docker sandbox
make test              # both
```

## Layout

```
setup.sh   thin hermes-side orchestrator (interactive)
scripts/   setup-server.sh, setup-hermes.sh, setup-mcp.sh, setup-gateway.sh + lib/
config/    .env.example, mcp.toml.example, gateways.toml.example, docker-compose*.yml
docker/    Dockerfile.hermes (fallback build)
docs/      manual instructions (incl. gateways/)
tests/     bats unit + integration + sandbox Dockerfile
```
