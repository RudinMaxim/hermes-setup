# Memory MCP

Long-term agent memory backed by a SQLite file in the `hermes_data` volume. No external service.

## What you need to do by hand
1. In `config/mcp.toml`:
   ```toml
   [memory]
   enabled = true
   ```
2. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-memory` inside the hermes container.
- Registers it with Hermes; storage lives under Hermes' data dir `$HERMES_HOME` (e.g. `/opt/data/memory.db`), persisted in the `hermes_data` volume.

## Verify
Tell Hermes: "Remember that I prefer Go over Rust." Then start a new chat and ask: "What languages do I prefer?"
