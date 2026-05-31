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
