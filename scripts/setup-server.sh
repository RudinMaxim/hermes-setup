#!/usr/bin/env bash
# scripts/setup-server.sh — Idempotent VPS preparation for Hermes.
# Runs as root on Debian/Ubuntu 22.04+. Re-runs are safe.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_HOME=/home/hermes
HERMES_REPO="$HERMES_HOME/hermes-setup"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/checks.sh
source "$SCRIPT_DIR/lib/checks.sh"
# shellcheck source=lib/write_file.sh
source "$SCRIPT_DIR/lib/write_file.sh"

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"
}

require_debian_family() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "Debian/Ubuntu only (no $OS_RELEASE_FILE)"
  if ! grep -qE '^(ID|ID_LIKE)=.*debian' "$OS_RELEASE_FILE" && \
     ! grep -qE '^(ID|ID_LIKE)=.*ubuntu' "$OS_RELEASE_FILE"; then
    die "Debian/Ubuntu only (found $(grep ^ID= "$OS_RELEASE_FILE" || echo unknown))"
  fi
}

ensure_apt_cache_fresh() {
  local cache=/var/cache/apt/pkgcache.bin
  if [[ -f "$cache" ]] && find "$cache" -mmin -60 -print -quit | grep -q .; then
    log_skip "apt cache fresh (<60 min old)"
    return 0
  fi
  log_act "apt-get update"
  apt-get update -qq
  log_ok "apt cache refreshed"
}

ensure_pkgs() {
  local pkgs=(ca-certificates curl gnupg ufw fail2ban unattended-upgrades htop git)
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
    if is_pkg_installed "$p"; then
      log_skip "package $p already installed"
    else
      missing+=("$p")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  log_act "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  log_ok "installed: ${missing[*]}"
}

ensure_hermes_user() {
  if has_user hermes; then
    log_skip "user 'hermes' already exists"
  else
    log_act "creating user 'hermes'"
    useradd -m -s /bin/bash hermes
    log_ok "user 'hermes' created"
  fi

  local rk=/root/.ssh/authorized_keys
  local hk_dir=/home/hermes/.ssh
  local hk=$hk_dir/authorized_keys
  if [[ -s "$rk" && ! -s "$hk" ]]; then
    log_act "copying root's authorized_keys to hermes"
    install -d -m 0700 -o hermes -g hermes "$hk_dir"
    install -m 0600 -o hermes -g hermes "$rk" "$hk"
    log_ok "copied authorized_keys for hermes"
  else
    log_skip "authorized_keys for hermes (already present or no root keys)"
  fi
}

ensure_sudoers() {
  local target=/etc/sudoers.d/hermes
  local content
  content=$(cat <<'EOF'
# Managed by hermes-setup. Allows the 'hermes' user to manage the Hermes service
# without a password — no other privileges.
#
# Wildcards are intentionally absent: a `journalctl -u hermes *` rule would let
# 'hermes' pass flags like --file=/var/log/journal/...system.journal to read
# arbitrary root-owned journal files. Use `docker logs hermes` for live logs.
hermes ALL=(root) NOPASSWD: /bin/systemctl restart hermes
hermes ALL=(root) NOPASSWD: /bin/systemctl status hermes
EOF
)
  write_file_idempotent "$target" "$content" 0440
  if ! visudo -cf "$target" >/dev/null; then
    rm -f "$target"
    die "invalid sudoers file written to $target — removed"
  fi
}

ensure_repo_in_hermes_home() {
  if [[ "$REPO_ROOT" == "$HERMES_REPO" ]]; then
    log_skip "repo already at $HERMES_REPO"
    return 0
  fi
  if [[ -d "$HERMES_REPO" ]]; then
    log_skip "$HERMES_REPO already exists (not overwriting)"
    return 0
  fi
  log_act "copying repo $REPO_ROOT -> $HERMES_REPO"
  cp -a "$REPO_ROOT" "$HERMES_REPO"
  chown -R hermes:hermes "$HERMES_REPO"
  log_ok "repo copied to $HERMES_REPO"
}

ensure_hermes_ssh_key() {
  local hk=/home/hermes/.ssh/authorized_keys
  if [[ -s "$hk" ]]; then
    log_skip "hermes already has SSH key(s) in $hk"
    return 0
  fi

  # 1. Explicit override via env var. Multiple keys: separate with literal '\n'
  #    or just pass a single key.
  if [[ -n "${HERMES_SSH_KEY:-}" ]]; then
    log_act "writing hermes SSH key from \$HERMES_SSH_KEY"
    install -d -m 0700 -o hermes -g hermes /home/hermes/.ssh
    printf '%b\n' "$HERMES_SSH_KEY" > "$hk"
    chown hermes:hermes "$hk"
    chmod 0600 "$hk"
    log_ok "hermes SSH key installed from \$HERMES_SSH_KEY"
    return 0
  fi

  # 2. Fall back to root's own key files if /root/.ssh/authorized_keys was empty
  #    but root has its own keypair (some providers leave only id_*.pub).
  local pub
  for pub in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub; do
    if [[ -s "$pub" ]]; then
      log_act "seeding hermes authorized_keys from $pub"
      install -d -m 0700 -o hermes -g hermes /home/hermes/.ssh
      install -m 0600 -o hermes -g hermes "$pub" "$hk"
      log_ok "hermes SSH key seeded from $pub"
      return 0
    fi
  done

  log_warn "hermes has no SSH key — SSH hardening will be skipped"
  log_warn "to enable hardening, re-run with: HERMES_SSH_KEY='ssh-ed25519 AAAA... you@host' sudo $0"
}

ensure_ssh_hardening() {
  local hk=/home/hermes/.ssh/authorized_keys
  if [[ ! -s "$hk" ]]; then
    log_warn "skipping SSH hardening: hermes has no SSH keys ($hk missing) — would cause self-lockout"
    return 0
  fi

  local target=/etc/ssh/sshd_config.d/99-hermes.conf
  local content
  content=$(cat <<'EOF'
# Managed by hermes-setup.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers hermes
EOF
)
  local tmp; tmp=$(mktemp)
  printf '%s' "$content" >"$tmp"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log_skip "sshd_config.d/99-hermes.conf already up-to-date"
    return 0
  fi

  if ! sshd -t -f /etc/ssh/sshd_config -o "Include $tmp"; then
    rm -f "$tmp"
    die "sshd -t failed for proposed config — aborting"
  fi
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
  log_ok "wrote $target"

  log_act "reloading ssh service"
  systemctl reload ssh
  log_ok "ssh reloaded"
}

# _ensure_ufw_rule PATTERN ufw-arg [ufw-arg...]
# Pass the ufw command as separate arguments — do NOT rely on word-splitting,
# since this script sets IFS=$'\n\t' (no space), so "ufw $rule" would pass the
# whole rule as a single argument and ufw rejects it ("Invalid syntax").
_ensure_ufw_rule() {
  local pattern="$1"; shift
  # Join args with spaces for display (IFS has no space, so "$*" would use \n).
  local pretty; pretty="$(printf '%s ' "$@")"; pretty="${pretty% }"
  if ufw_rule_present "$pattern"; then
    log_skip "ufw rule '$pretty' already present"
    return 0
  fi
  log_act "ufw $pretty"
  ufw "$@" >/dev/null
  log_ok "ufw rule added: $pretty"
}

ensure_ufw() {
  if ufw status verbose 2>/dev/null | grep -qE 'Default:.*deny \(incoming\)'; then
    log_skip "ufw default deny incoming already set"
  else
    log_act "ufw default deny incoming / allow outgoing"
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    log_ok "ufw defaults set"
  fi

  _ensure_ufw_rule '22/tcp[[:space:]]+LIMIT' limit 22/tcp
  _ensure_ufw_rule '80/tcp[[:space:]]+ALLOW' allow 80/tcp
  _ensure_ufw_rule '443/tcp[[:space:]]+ALLOW' allow 443/tcp

  if ufw status 2>/dev/null | grep -qE '^Status:[[:space:]]+active'; then
    log_skip "ufw already active"
  else
    log_act "enabling ufw"
    ufw --force enable >/dev/null
    log_ok "ufw enabled"
  fi
}

ensure_fail2ban() {
  if systemd_unit_enabled fail2ban; then
    log_skip "fail2ban already enabled"
  else
    log_act "enabling fail2ban"
    systemctl enable fail2ban >/dev/null
    log_ok "fail2ban enabled"
  fi
  if systemd_unit_active fail2ban; then
    log_skip "fail2ban already running"
  else
    log_act "starting fail2ban"
    systemctl start fail2ban
    log_ok "fail2ban started"
  fi
}

ensure_unattended_upgrades() {
  local target=/etc/apt/apt.conf.d/20auto-upgrades
  local content
  content=$(cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
)
  write_file_idempotent "$target" "$content" 0644
}

ensure_docker() {
  if has_command docker; then
    log_skip "docker already installed ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    log_act "installing docker via get.docker.com"
    curl -fsSL https://get.docker.com | sh >/dev/null
    log_ok "docker installed"
  fi

  if user_in_group hermes docker; then
    log_skip "hermes already in docker group"
  else
    log_act "adding hermes to docker group"
    usermod -aG docker hermes
    log_ok "hermes added to docker group (requires relogin to take effect)"
  fi

  if systemd_unit_enabled docker; then
    log_skip "docker.service already enabled"
  else
    log_act "enabling docker.service"
    systemctl enable docker >/dev/null
    log_ok "docker.service enabled"
  fi

  if systemd_unit_active docker; then
    log_skip "docker.service already running"
  else
    log_act "starting docker.service"
    systemctl start docker
    log_ok "docker.service started"
  fi
}

main() {
  require_root
  require_debian_family
  log_ok "pre-flight checks passed"

  ensure_apt_cache_fresh
  ensure_pkgs
  ensure_hermes_user
  ensure_hermes_ssh_key
  ensure_sudoers
  ensure_repo_in_hermes_home
  ensure_ssh_hardening
  ensure_ufw
  ensure_fail2ban
  ensure_unattended_upgrades
  ensure_docker

  log_ok "server setup complete"
  log_ok "next steps:"
  log_ok "  su - hermes"
  log_ok "  cd ~/hermes-setup && nano config/.env   # add OPENAI_API_KEY or ANTHROPIC_API_KEY"
  log_ok "  ./scripts/setup-hermes.sh"
}

main "$@"
