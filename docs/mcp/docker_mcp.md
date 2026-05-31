# Docker MCP — ⚠️ host-level access

Inspect host containers and read logs.

## Risk
This MCP mounts `/var/run/docker.sock` into the hermes container. Anyone who can talk to the Docker daemon can effectively become root on the host. The script refuses to enable this MCP unless you explicitly acknowledge.

## What you need to do by hand
1. Read the risk section above. Understand that enabling this gives the agent (and anyone who can prompt-inject it) root-equivalent access to the VPS.
2. In `config/mcp.toml`:
   ```toml
   [docker_mcp]
   enabled = true
   acknowledge_socket_risk = true
   ```
3. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-docker` inside the hermes container.
- Verifies that `/var/run/docker.sock` is already mounted into the Hermes
  container before registering the MCP.
- Registers it with Hermes when the socket is present.

The script does not edit `config/docker-compose.yml` automatically because that
requires a deliberate container recreate. If setup reports that the socket is
missing, add this volume under `services.hermes.volumes` and recreate the
container:

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

## Verify
```bash
docker exec hermes hermes mcp test docker_mcp
```

## Disable
Set both `enabled = false` and `acknowledge_socket_risk = false`, then re-run `./scripts/setup-mcp.sh`. The script un-registers the MCP.
