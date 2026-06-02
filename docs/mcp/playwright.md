# Playwright MCP

Headless browser automation. Runs as a separate Docker container (the image is ~1 GB).

**Работает из коробки.** В `config/mcp.toml` секция `[playwright]` включена по
умолчанию, и `setup-mcp.sh` (часть `./setup.sh`) поднимает её автоматически.

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
