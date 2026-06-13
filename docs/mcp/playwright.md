# Playwright MCP

Browser automation through the official Microsoft Playwright MCP.

## Docker/VPS

В Docker-режиме MCP работает как отдельный контейнер. В
`config/mcp.toml` секция `[playwright]` включена по умолчанию, и
`setup-mcp.sh` поднимает её автоматически.

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

## Native macOS

`make setup-macos` регистрирует stdio-сервер:

```bash
npx -y @playwright/mcp@0.0.76 \
  --browser chrome \
  --user-data-dir ~/.hermes/playwright-profile
```

Версия задаётся через `HERMES_PLAYWRIGHT_MCP_VERSION` в
`config/macos.env`. Выделенный профиль сохраняет cookies и браузерные сессии
между запусками MCP и не конфликтует с уже открытым обычным Chrome.

Проверка:

```bash
hermes mcp test playwright
hermes gateway restart
```

MCP-конфигурация читается при создании агента. Уже работающий gateway или
закэшированная сессия не увидят новый Playwright до `hermes gateway restart`,
новой сессии либо `/reload-mcp` в чате.
