# Google Drive MCP

Google Drive search/read through Google's hosted MCP endpoint.

## What you need to do by hand

### 1. Create or select a Google Cloud project

Open the Google Cloud Console:

```text
https://console.cloud.google.com/
```

Create a new project, or select an existing project that you want to use for
Hermes.

### 2. Enable the Google Drive API

Open **APIs & Services -> Library**, search for **Google Drive API**, and enable
it for the selected project.

Google requires the relevant API to be enabled before you can register OAuth
scopes for that API.

### 3. Configure the OAuth app

Open **Google Auth Platform**:

```text
https://console.cloud.google.com/auth/overview
```

Then configure:

- **App name:** `Hermes Google Drive MCP`
- **User support email:** your email
- **Audience/User type:** use **External** for a personal Google account, or
  **Internal** if this is a Google Workspace project and you only need users in
  the organization.
- **Test users:** add the Google account that will connect Drive to Hermes.

For data access/scopes, add:

```text
https://www.googleapis.com/auth/drive.readonly
https://www.googleapis.com/auth/drive.file
```

Google's hosted Drive MCP requires exactly these two scopes (`drive.readonly`
for search/read across your Drive, `drive.file` for per-file create/download).
Add both on the consent screen. Keep this OAuth app in testing mode and only add
users you trust unless you intend to go through Google's verification process.

### 4. Create the OAuth client

Open **Google Auth Platform -> Clients**:

```text
https://console.cloud.google.com/auth/clients
```

Click **Create client**, choose **Desktop app**, name it
`Hermes Google Drive MCP`, and create it.

Copy the generated **Client ID** and **Client secret** immediately. Google only
shows/downloads newly created client secrets at creation time; if you lose the
secret, rotate/create a new one.

### 5. Add credentials to config/.env

Edit `config/.env`:

```bash
GOOGLE_DRIVE_OAUTH_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_DRIVE_OAUTH_CLIENT_SECRET=your-client-secret
```

### 6. Enable Google Drive MCP

Edit `config/mcp.toml`:

```toml
[google_drive]
enabled = true
```

Then sync MCP config:

```bash
./scripts/setup-mcp.sh
```

If you are doing a fresh host setup, you can skip the manual enable/sync steps
and run the one-command setup instead:

```bash
./setup.sh
```

In interactive mode it can enable `[google_drive]`, ask for the OAuth client
credentials, sync MCP config, print the Google authorization URL, and ask you to
paste the final callback URL.

### 7. Complete OAuth login

Run:

```bash
docker exec -it hermes hermes mcp login google_drive
```

Hermes opens or prints an authorization URL. Approve access with the Google
account you added as a test user. On a remote VPS, if the browser redirect
cannot reach the server, copy the final redirect URL from your browser and paste
it back into the terminal when Hermes asks.

Tokens are stored by Hermes inside its data directory (`$HERMES_HOME`, e.g.
`/opt/data` on the current image) under `mcp-tokens/`:

```text
$HERMES_HOME/mcp-tokens/
```

## What the script does

- Writes this server into Hermes' active config (`$HERMES_HOME/config.yaml`,
  e.g. `/opt/data/config.yaml`):

  ```yaml
  mcp_servers:
    google_drive:
      enabled: true
      url: https://drivemcp.googleapis.com/mcp/v1
      auth: oauth
      oauth:
        client_id: "<value of GOOGLE_DRIVE_OAUTH_CLIENT_ID from config/.env>"
        client_secret: "<value of GOOGLE_DRIVE_OAUTH_CLIENT_SECRET from config/.env>"
        scope: https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file
  ```

  The credentials are written as **literal values** read from `config/.env`,
  not `${VAR}` placeholders — Hermes does not expand environment variables in
  the `oauth` block, and Google's Drive MCP requires real client credentials.

- Does not install an npm package; this is a remote HTTP MCP.
- Does not store Google OAuth tokens in this repo. Hermes stores tokens in its
  Docker volume after `hermes mcp login google_drive`.

## Verify

```bash
docker exec hermes hermes mcp test google_drive
```

Then ask Hermes to search Drive, for example:

```text
Find recent Google Drive documents about Hermes setup and summarize them.
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `missing GOOGLE_DRIVE_OAUTH_CLIENT_ID` | Fill `GOOGLE_DRIVE_OAUTH_CLIENT_ID` and `GOOGLE_DRIVE_OAUTH_CLIENT_SECRET` in `config/.env`. |
| `redirect_uri_mismatch` | Use an OAuth client type **Desktop app**. If you created a Web client, create a new Desktop client. |
| Consent screen says app is unverified | Keep the app in testing and add your Google account as a test user, or complete Google's verification process before using it broadly. |
| Login appears to work but tool calls time out | Re-run `docker exec -it hermes hermes mcp login google_drive`. Google's Drive MCP requires a pre-registered OAuth client; bare dynamic registration is not enough. |
| Need to switch Google accounts | Revoke the app at https://myaccount.google.com/permissions, remove the cached token in `$HERMES_HOME/mcp-tokens/` (e.g. `/opt/data/mcp-tokens/`), then run `hermes mcp login google_drive` again. |

## References

- Hermes MCP OAuth config: https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp/
- Hermes MCP config reference: https://hermes-agent.nousresearch.com/docs/reference/mcp-config-reference/
- Google OAuth clients: https://support.google.com/cloud/answer/15549257
- Google Drive API scopes: https://developers.google.com/workspace/drive/api/guides/api-specific-auth
