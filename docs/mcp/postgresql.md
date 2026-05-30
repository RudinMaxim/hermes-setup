# PostgreSQL MCP

Run SQL queries and introspect schemas against your databases.

## What you need to do by hand
1. Obtain a read-only PostgreSQL user for the database you want to expose. Example DDL:
   ```sql
   CREATE USER hermes_ro WITH PASSWORD 'strong-random';
   GRANT CONNECT ON DATABASE mydb TO hermes_ro;
   GRANT USAGE ON SCHEMA public TO hermes_ro;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO hermes_ro;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO hermes_ro;
   ```
2. Build the connection URL: `postgresql://hermes_ro:strong-random@db-host:5432/mydb`.
3. In `config/.env`:
   ```
   POSTGRES_URL=postgresql://hermes_ro:strong-random@db-host:5432/mydb
   ```
4. In `config/mcp.toml`:
   ```toml
   [postgres]
   enabled = true
   ```
5. Run: `./scripts/setup-mcp.sh`

## What the script does
- Installs `@modelcontextprotocol/server-postgres` inside the hermes container.
- Registers it with Hermes; `POSTGRES_URL` is passed through.

## Verify
```bash
docker exec hermes hermes mcp test postgres
```

## Security notes
- Always use a read-only DB user unless you specifically want the agent to modify data.
- Hermes will see *any* data the DB user can read — don't grant SELECT on tables containing secrets, PII, or unencrypted credentials.
