# GitHub MCP

Read repos, manage issues and pull requests.

## What you need to do by hand
1. Open https://github.com/settings/personal-access-tokens/new (fine-grained PAT).
2. **Token name:** `hermes-mcp`
3. **Repository access:** "All repositories" (or "Only select repositories" — list the ones you want).
4. **Permissions:**
   - Contents: **Read**
   - Issues: **Read and write**
   - Pull requests: **Read and write**
   - Metadata: **Read** (auto-included)
5. **Generate token** → copy the `ghp_…` value.
6. In `config/.env`:
   ```
   GITHUB_TOKEN=ghp_yourtokenhere
   ```
7. In `config/mcp.toml`:
   ```toml
   [github]
   enabled = true
   ```
8. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-github` inside the hermes container.
- Registers it with Hermes, passing `GITHUB_TOKEN` through.

## Verify
```bash
docker exec hermes hermes mcp test github
```

## Troubleshooting
- `401 Unauthorized` — token expired (fine-grained PATs default to 30 days). Re-issue.
- Cannot see private repos — verify token has access to those specific repos.
