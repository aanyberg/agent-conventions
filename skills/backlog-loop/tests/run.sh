#!/usr/bin/env bash
# Run every test suite, and shellcheck when it is installed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
failed=0

run() {
  # run <label> <command...>
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    printf 'PASS  %s  %s\n' "$label" "$(printf '%s\n' "$out" | tail -n 1)"
  else
    failed=$((failed + 1))
    printf 'FAIL  %s\n' "$label"
    printf '%s\n' "$out" | grep -v '^  ok' | sed 's/^/      /'
  fi
}

SHELLCHECK="${SHELLCHECK:-shellcheck}"
if command -v "$SHELLCHECK" >/dev/null 2>&1; then
  run "shellcheck" bash -c "cd '$SKILL_DIR' && '$SHELLCHECK' scripts/*.sh tests/*.sh tests/stubs/gh"
else
  echo "SKIP  shellcheck (not installed; set SHELLCHECK=/path/to/shellcheck)"
fi

run "scenarios" bash "$TESTS_DIR/test-scenarios.sh"
run "hooks" bash "$TESTS_DIR/test-hooks.sh"

if [ "$failed" -eq 0 ]; then
  echo "All suites passed."
else
  echo "$failed suite(s) failed."
  exit 1
fi
