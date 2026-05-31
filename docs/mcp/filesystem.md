# Filesystem MCP

Read/write access to a host directory mounted into the Hermes container.

## What you need to do by hand
1. Decide which host directory to expose on the host (default:
   `/home/hermes/projects`, controlled by `HERMES_PROJECTS_DIR` in
   `config/.env`).
2. Make sure it exists:
   ```bash
   mkdir -p ~/projects
   ```
3. In `config/mcp.toml`, keep the container mount path:
   ```toml
   [filesystem]
   enabled = true
   mount = "/home/hermes/projects"
   ```
4. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-filesystem` inside the hermes container.
- Mounts `HERMES_PROJECTS_DIR` from the host into the Hermes container at
  `/home/hermes/projects`.
- Registers it with Hermes pointing at the container-side `mount` path.

## Verify
```bash
docker exec hermes hermes mcp test filesystem
```
Expected: `ok`.
