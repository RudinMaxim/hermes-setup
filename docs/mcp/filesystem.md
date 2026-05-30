# Filesystem MCP

Read/write access to a host directory mounted into the Hermes container.

## What you need to do by hand
1. Decide which host directory to expose (default: `/home/hermes/projects`).
2. Make sure it exists:
   ```bash
   mkdir -p ~/projects
   ```
3. In `config/mcp.toml`, set:
   ```toml
   [filesystem]
   enabled = true
   mount = "/home/hermes/projects"
   ```
4. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-filesystem` inside the hermes container.
- Registers it with Hermes pointing at the `mount` path.

## Verify
```bash
docker exec hermes hermes mcp test filesystem
```
Expected: `ok`.
