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
  # awk with a literal key match avoids regex injection from $key
  # (a key like "FOO|BAR" must NOT match a line with KEY=BAR).
  awk -v k="$key" '
    {
      sub(/^[[:space:]]+/, "")
      if ($0 ~ /^#/) next
      eq = index($0, "=")
      if (eq == 0) next
      lhs = substr($0, 1, eq-1)
      sub(/[[:space:]]+$/, "", lhs)
      if (lhs != k) next
      rhs = substr($0, eq+1)
      sub(/^[[:space:]]+/, "", rhs)
      sub(/[[:space:]]+$/, "", rhs)
      if (rhs != "") { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

ufw_rule_present() {
  ufw status verbose 2>/dev/null | grep -qE "$1"
}

# is_numeric_csv "123,456" -> 0 ; "123,abc" / "" / "12," -> 1
is_numeric_csv() {
  local v="$1"
  [[ -n "$v" ]] || return 1
  [[ "$v" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

# read_env_value FILE KEY -> prints the value (comments/whitespace stripped),
# exit 1 if the key is absent or empty. Complements env_var_set_in_file (boolean only).
# awk with a literal key match — no regex injection from $key.
read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v k="$key" '
    {
      sub(/^[[:space:]]+/, "")
      if ($0 ~ /^#/) next
      eq = index($0, "=")
      if (eq == 0) next
      lhs = substr($0, 1, eq-1); sub(/[[:space:]]+$/, "", lhs)
      if (lhs != k) next
      rhs = substr($0, eq+1)
      sub(/^[[:space:]]+/, "", rhs); sub(/[[:space:]]+$/, "", rhs)
      if (rhs != "") { print rhs; found = 1 }
      exit
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}
