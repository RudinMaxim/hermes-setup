#!/usr/bin/env bats

load '../helpers/setup_suite'
load '../helpers/assertions'

@test "setup-server.sh refuses to run as non-root" {
  run sudo -u nobody bash "$SCRIPTS/setup-server.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must run as root"* ]]
}

@test "setup-server.sh refuses to run on non-Debian OS" {
  run bash -c "OS_RELEASE_FILE=/dev/null '$SCRIPTS/setup-server.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Debian/Ubuntu only"* ]]
}

@test "setup-server.sh installs base packages and creates hermes user" {
  bash "$SCRIPTS/setup-server.sh"
  run dpkg-query -W -f='${Status}' ufw
  [[ "$output" == *"ok installed"* ]]
  run id -u hermes
  [ "$status" -eq 0 ]
}

@test "setup-server.sh creates sudoers drop-in for hermes" {
  bash "$SCRIPTS/setup-server.sh"
  [ -f /etc/sudoers.d/hermes ]
  run visudo -cf /etc/sudoers.d/hermes
  [ "$status" -eq 0 ]
}

@test "setup-server.sh aborts SSH hardening when hermes has no authorized_keys" {
  rm -f /home/hermes/.ssh/authorized_keys /root/.ssh/authorized_keys
  run bash "$SCRIPTS/setup-server.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"self-lockout"* || "$output" == *"no SSH keys"* ]]
}

@test "setup-server.sh hardens SSH when hermes has authorized_keys" {
  install -d -m 0700 -o hermes -g hermes /home/hermes/.ssh
  echo "ssh-ed25519 AAAA fake@test" > /home/hermes/.ssh/authorized_keys
  chown hermes:hermes /home/hermes/.ssh/authorized_keys
  chmod 0600 /home/hermes/.ssh/authorized_keys

  bash "$SCRIPTS/setup-server.sh"
  [ -f /etc/ssh/sshd_config.d/99-hermes.conf ]
  run grep -E '^PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hermes.conf
  [ "$status" -eq 0 ]
}

@test "setup-server.sh enables UFW with required rules" {
  bash "$SCRIPTS/setup-server.sh"
  run ufw status verbose
  [[ "$output" == *"Status: active"* ]]
  [[ "$output" == *"22/tcp"* ]]
  [[ "$output" == *"80/tcp"* ]]
  [[ "$output" == *"443/tcp"* ]]
}

@test "setup-server.sh enables fail2ban service" {
  bash "$SCRIPTS/setup-server.sh"
  run systemctl is-enabled fail2ban
  [[ "$output" == "enabled" ]]
}

@test "setup-server.sh writes /etc/apt/apt.conf.d/20auto-upgrades" {
  bash "$SCRIPTS/setup-server.sh"
  [ -f /etc/apt/apt.conf.d/20auto-upgrades ]
  run grep -E 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
  [ "$status" -eq 0 ]
}

@test "setup-server.sh installs Docker and adds hermes to docker group" {
  bash "$SCRIPTS/setup-server.sh"
  run command -v docker
  [ "$status" -eq 0 ]
  run id -nG hermes
  [[ "$output" == *"docker"* ]]
}

@test "setup-server.sh is fully idempotent (second run = only [SKIP])" {
  bash "$SCRIPTS/setup-server.sh"
  run bash "$SCRIPTS/setup-server.sh"
  [ "$status" -eq 0 ]
  ! grep -qE '^\[(ACT|OK)\]' <<<"$output" || {
    echo "second run was not idempotent:"
    echo "$output"
    false
  }
  grep -qE '^\[SKIP\]' <<<"$output"
}
