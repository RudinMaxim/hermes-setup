# Context7 MCP

Up-to-date library/framework documentation lookup.

## What you need to do by hand
The anonymous tier works without any token; rate-limited but enough for personal use. If you hit limits:

1. Sign up at https://context7.com → API keys → create a key.
2. In `config/.env`:
   ```
   CONTEXT7_API_KEY=ctx7_yourkeyhere
   ```
3. In `config/mcp.toml`:
   ```toml
   [context7]
   enabled = true
   ```
4. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@upstash/context7-mcp` inside the hermes container.
- Registers it with Hermes (key passed through if set).

## Verify
Ask Hermes: "Show me the latest Next.js app-router docs for layouts." It should call the `context7` tool.
