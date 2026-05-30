# shellcheck shell=bash

has_command() {
  command -v "$1" &>/dev/null
}

has_user() {
  id -u "$1" &>/dev/null
}

user_in_group() {
  local user="$1" group="$2"
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"
}

is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

systemd_unit_enabled() {
  systemctl is-enabled "$1" &>/dev/null
}

systemd_unit_active() {
  systemctl is-active "$1" &>/dev/null
}

docker_image_present() {
  docker image inspect "$1" &>/dev/null
}

docker_container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

docker_container_running() {
  [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]
}

docker_volume_present() {
  docker volume inspect "$1" &>/dev/null
}

env_var_set_in_file() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  # Match: optional leading whitespace, KEY=NONEMPTY (not just whitespace)
  grep -qE "^[[:space:]]*${key}=[^[:space:]].*\$" "$file"
}

ufw_rule_present() {
  ufw status verbose 2>/dev/null | grep -qE "$1"
}
