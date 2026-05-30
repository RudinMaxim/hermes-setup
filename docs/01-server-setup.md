# 01 — Manual VPS preparation

`scripts/setup-server.sh` does most of the work. This document covers everything that has to be done by hand (or that you should know before/after running it).

## Before running setup-server.sh

### Provider and image
- Any Debian 12 or Ubuntu 22.04 VPS (Hetzner, DigitalOcean, Linode, Vultr, Scaleway — all fine).
- Minimum: 1 vCPU, 2 GB RAM, 20 GB disk. Hermes itself is small; Playwright MCP image is ~1 GB so plan accordingly.
- Region: pick the one closest to your LLM provider's API endpoint to minimise latency.

### SSH key
1. Generate locally if you don't have one:
   ```bash
   ssh-keygen -t ed25519 -C "hermes-setup@<your-email>"
   ```
2. Paste the public key (`~/.ssh/id_ed25519.pub`) into your VPS provider's web UI **before** booting the server. Most providers inject it into `/root/.ssh/authorized_keys` automatically.
3. Test login: `ssh root@<vps-ip>`.

**Where `setup-server.sh` looks for the hermes user's key**, in order:
1. `$HERMES_SSH_KEY` — explicit override (multi-line OK, separate keys with `\n`):
   ```bash
   HERMES_SSH_KEY="ssh-ed25519 AAAA... you@host" sudo ./scripts/setup-server.sh
   ```
2. `/root/.ssh/authorized_keys` — the key your provider injected.
3. `/root/.ssh/id_ed25519.pub` / `id_rsa.pub` / `id_ecdsa.pub` — root's own keypair.

If none of those exist, the script prints a warning and **skips SSH hardening** (UFW, fail2ban, Docker still install). Re-run later with `HERMES_SSH_KEY=...` to enable hardening.

### DNS (only if you plan to expose a gateway later)
- For Telegram webhooks or a WebUI, you need a domain pointing at the VPS — add an A record `hermes.example.com → <vps-ip>`.
- Not needed for CLI-only or polling-based Telegram.

## After running setup-server.sh

### Verify SSH still works
**Do not close the existing root SSH session** until you've confirmed the new setup works:
```bash
# In a NEW terminal:
ssh hermes@<vps-ip>
```
If this fails, fix the issue from your existing session before closing it. Recovery: revert `/etc/ssh/sshd_config.d/99-hermes.conf` and `systemctl reload ssh`.

### Confirm firewall rules
```bash
sudo ufw status verbose
```
Expected: `Status: active`, default `deny (incoming)` / `allow (outgoing)`, rules for 22/tcp (LIMIT), 80/tcp, 443/tcp.

### Backups
The script does NOT configure backups. Pick one:
- **Provider snapshot**: most providers offer scheduled snapshots ($1-3/month) — easiest.
- **Restic to external storage**: write your own systemd timer.

What to back up at minimum: `/home/hermes/.hermes` (inside the `hermes_data` Docker volume) — it contains config, skills, memory.

### Optional hardening (not done by the script)
- Move SSH off port 22 (edit `/etc/ssh/sshd_config.d/99-hermes.conf`, update UFW rule).
- Install `endlessh` as a tarpit on port 22.
- Add `wireguard` or `tailscale` and require SSH only via VPN.

## Troubleshooting

| Symptom | Check |
|---|---|
| Script aborts: `Debian/Ubuntu only` | `cat /etc/os-release` — only `ID=debian` or `ID=ubuntu` is supported. |
| `[WARN] skipping SSH hardening: hermes has no SSH keys` | Provider didn't inject your key. Re-run with `HERMES_SSH_KEY="ssh-ed25519 AAAA... you@host" sudo ./scripts/setup-server.sh`. |
| Can't log in as hermes after script | Confirm with `sudo cat /home/hermes/.ssh/authorized_keys` that the right key is there. If not, re-run setup-server with `HERMES_SSH_KEY=...`. |
| `/home/hermes/hermes-setup` missing after running as root | The copy step (`ensure_repo_in_hermes_home`) only fires when hermes already exists. Re-run `sudo ./scripts/setup-server.sh` from your original clone — it's idempotent. |
