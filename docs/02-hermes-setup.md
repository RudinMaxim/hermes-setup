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

## Troubleshooting

| Symptom | Check |
|---|---|
| `current user not in 'docker' group` | After `setup-server.sh` you must log out and back in (group membership is per-session). Or run `newgrp docker`. |
| Image pull fails, falls back to local build, build takes a long time | First build can be 5-10 min. Subsequent runs are cached. |
| Container restarts in a loop | `docker logs --tail=100 hermes`. Common: missing/invalid LLM key (Hermes exits if model can't be initialised). |
| `hermes did not become healthy in 30s` | Check `docker logs hermes` for startup errors. If the network is slow, increase the loop in `scripts/setup-hermes.sh::wait_for_health`. |
