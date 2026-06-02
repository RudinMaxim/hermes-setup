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
recreates the container with the gateway command. The Hermes image already has
`hermes` as its entrypoint, so the compose override must be:

```yaml
command: ["gateway", "run"]
```

Do not use `command: ["hermes", "gateway", "run"]`: that expands to
`hermes hermes gateway run` and the container exits with
`invalid choice: 'hermes'`.

Message your bot to test. Re-running is safe — if nothing changed it only
prints `[SKIP]`.

If the gateway is already running and you changed `config/.env` or Hermes'
`/opt/data/config.yaml`, force it to recreate the gateway container:

```bash
./scripts/setup-gateway.sh --restart
```

Without `--restart`, an already-running gateway prints `[SKIP]`: that only means
the container command is already `gateway run`; it does not force a fresh config
read.

The setup script also checks broken gateway states. If it detects the old
duplicated command (`hermes gateway run`), a stopped container, or a failed
`hermes gateway status`, it recreates the gateway container instead of printing
a misleading `[SKIP]`.

## Google Drive / Workspace from Telegram

### Проверенно рабочая схема

Для Telegram используй встроенный Google Workspace skill, а не remote
`google_drive` MCP. Remote MCP живёт отдельным OAuth и может снова просить
авторизацию, даже если Workspace skill уже читает Drive.

Рабочая схема:

1. Авторизовать Google Workspace один раз через CLI-чат Hermes.
2. Убедиться, что появился `/opt/data/google_token.json`.
3. Запустить стабилизатор:

```bash
./scripts/stabilize-google-workspace.sh
```

После этого в Telegram формулируй запрос явно:

```text
Используй Google Workspace skill. Покажи последние 5 файлов из моего Google Drive.
```

Если контейнер gateway пересоздавался, или Telegram снова просит Google OAuth,
повтори:

```bash
./scripts/stabilize-google-workspace.sh
```

If Google Drive works in `docker exec -it hermes hermes chat`, but the Telegram
bot asks you to authorize again, the usual cause is that two Google integrations
are enabled at once:

- the built-in Google Workspace skill, which already has a token;
- the remote `google_drive` MCP, which has its own separate OAuth flow.

For a stable Telegram setup, use the Workspace skill and disable the remote
`google_drive` MCP. Run:

```bash
./scripts/stabilize-google-workspace.sh
```

The script verifies that the Workspace token exists, links the legacy token
path, disables `mcp_servers.google_drive.enabled`, checks Hermes config, and
restarts the Telegram gateway.

The CLI Google Workspace authorization stores the token here:

```text
/opt/data/google_token.json
```

Some Workspace skill checks still look at the older path:

```text
/home/hermes/.hermes/google_token.json
```

Run the gateway setup once after successful CLI authorization:

```bash
./scripts/setup-gateway.sh
```

If `/opt/data/google_token.json` exists, the script creates this compatibility
symlink inside the container:

```text
/home/hermes/.hermes/google_token.json -> /opt/data/google_token.json
```

Then ask the bot again. If you also changed `config/.env` or
`/opt/data/config.yaml`, use:

```bash
./scripts/setup-gateway.sh --restart
```

Manual checks:

```bash
docker exec hermes sh -lc 'echo HOME=$HOME; echo HERMES_HOME=$HERMES_HOME'
docker exec hermes sh -lc 'ls -l /opt/data/google_token.json /home/hermes/.hermes/google_token.json'
docker exec hermes hermes gateway status
```

To turn it off: set `enabled = false` and re-run — the container returns to
idle/CLI mode.

## Home channel prompt

After the Telegram gateway starts, Hermes may send this message:

```text
No home channel is set for Telegram. A home channel is where Hermes delivers cron job results and cross-platform messages.

Type /sethome to make this chat your home channel, or ignore to skip.
```

This is not an auth error and it is not related to MCP. Hermes is asking which
Telegram chat should receive background messages: cron results, scheduled jobs,
and messages produced outside the current chat.

If this private chat with the bot is where you want those messages, send:

```text
/sethome
```

If you use a group chat, send `/sethome` in that group instead. If you do not
care about background delivery, you can ignore the prompt, but Hermes may remind
you again.

## Privacy mode in groups (manual)

By default a bot in a group only sees messages that start with `/` (Telegram
"privacy mode"). To let it read all group messages: @BotFather → `/setprivacy`
→ select the bot → **Disable**. The numeric allowlist still filters senders the
same way in groups and in direct messages.
