# shellcheck shell=bash

# assert_idempotent CMD [ARGS...]
# Runs the command twice. Both runs must succeed. The second run must NOT
# emit any [ACT] or [OK] lines, and must emit at least one [SKIP] line.
assert_idempotent() {
  run "$@"
  [ "$status" -eq 0 ] || {
    echo "first run failed (status=$status):"
    echo "$output"
    return 1
  }

  run "$@"
  [ "$status" -eq 0 ] || {
    echo "second run failed (status=$status):"
    echo "$output"
    return 1
  }
  if grep -qE '^\[(ACT|OK)\]' <<<"$output"; then
    echo "second run was not a no-op (found [ACT]/[OK] lines):"
    echo "$output"
    return 1
  fi
  if ! grep -qE '^\[SKIP\]' <<<"$output"; then
    echo "second run did not emit any [SKIP] lines (script may be silent):"
    echo "$output"
    return 1
  fi
}
