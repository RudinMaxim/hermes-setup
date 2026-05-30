# shellcheck shell=bash
# Minimal TOML reader. Supports: [sections], key = "string" / number / bool,
# key = ["a", "b"] arrays. No nested tables, no inline tables, no multiline.

toml_sections() {
  local file="$1"
  awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
    gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "")
    print
  }' "$file"
}

_toml_strip_quotes() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" == \"*\" ]]; then
    v="${v#\"}"; v="${v%\"}"
  fi
  printf '%s' "$v"
}

toml_get() {
  local file="$1" section="$2" key="$3"
  local raw
  raw=$(awk -v sec="$section" -v k="$key" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      cur=$0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
      next
    }
    cur == sec && /=/ {
      split($0, p, "=")
      lhs=p[1]; gsub(/[[:space:]]/, "", lhs)
      if (lhs == k) {
        rhs=$0
        sub(/^[^=]*=/, "", rhs)
        sub(/[[:space:]]+#.*$/, "", rhs)
        print rhs
        exit
      }
    }
  ' "$file")
  [[ -z "$raw" ]] && return 1
  _toml_strip_quotes "$raw"
}

toml_get_bool() {
  local v
  v=$(toml_get "$1" "$2" "$3") || return 1
  [[ "$v" == "true" ]]
}

toml_get_array() {
  local file="$1" section="$2" key="$3"
  local raw
  raw=$(toml_get "$file" "$section" "$key") || return 1
  raw="${raw#[}"; raw="${raw%]}"
  [[ -z "$raw" ]] && return 0
  local IFS=','
  local item
  for item in $raw; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    item="${item#\"}"; item="${item%\"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}
