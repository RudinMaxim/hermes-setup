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

If the gateway is already running and you changed `config/.env` or Hermes'
`/opt/data/config.yaml`, force it to recreate the gateway container:

```bash
./scripts/setup-gateway.sh --restart
```

Without `--restart`, an already-running gateway prints `[SKIP]`: that only means
the container command is already `gateway run`; it does not force a fresh config
read.

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
