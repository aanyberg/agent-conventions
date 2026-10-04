#!/usr/bin/env bash
# Shared helpers for the plain-bash tests. Sourced by tests/test-*.sh.
# shellcheck disable=SC2034

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
S="$SKILL_DIR/scripts"
FIXTURES="$TESTS_DIR/fixtures"
T_PASS=0
T_FAIL=0
T_TMP=""

t_cleanup() {
  if [ -n "$T_TMP" ] && [ -d "$T_TMP" ]; then rm -rf "$T_TMP"; fi
}
trap t_cleanup EXIT

t_tmp() {
  T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/backlog-loop-test.XXXXXX")"
  T_TMP="$(cd "$T_TMP" && pwd -P)"
}

ok() {
  T_PASS=$((T_PASS + 1))
  printf '  ok    %s\n' "$1"
}

not_ok() {
  T_FAIL=$((T_FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '        %s\n' "$2"
}

assert_eq() {
  # assert_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected '$2', got '$3'"; fi
}

assert_contains() {
  # assert_contains <name> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) not_ok "$1" "'$2' not found in: $(printf '%s' "$3" | head -c 300)" ;;
  esac
}

assert_empty() {
  if [ -z "$2" ]; then ok "$1"; else not_ok "$1" "expected no output, got: $(printf '%s' "$2" | head -c 300)"; fi
}

t_summary() {
  printf '%s: %s passed, %s failed\n' "$(basename "$0")" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

# A state directory without a git repository, for the pure state tests.
# use_state <fixture.json> [jq filter to adjust it]
use_state() {
  [ -n "$T_TMP" ] || t_tmp
  BACKLOG_LOOP_ROOT="$T_TMP/repo-$T_PASS-$T_FAIL-$RANDOM"
  export BACKLOG_LOOP_ROOT
  STATE_DIR="$BACKLOG_LOOP_ROOT/.planning/backlog-loop"
  STATE="$STATE_DIR/state.json"
  mkdir -p "$STATE_DIR/decisions"
  jq "${2:-.}" "$FIXTURES/$1" >"$STATE"
}

sget() { jq -r "$1" "$STATE"; }

# A real git repository with a five-item backlog, for the dry run.
# make_fixture <dir> <github|file>
make_fixture() {
  local dir="$1" source="$2"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q -b main .
    git config user.email "dry-run@example.com"
    git config user.name "Dry Run"
    git config commit.gpgsign false
    {
      printf '# Fixture\n\n## Backlog loop\n\n'
      printf -- '- source: %s\n- label: backlog\n- path: BACKLOG.md\n- base-branch: main\n' "$source"
      printf -- '- merge-method: `squash`\n'
    } >CLAUDE.md
    if [ "$source" = "file" ]; then
      cat >BACKLOG.md <<'EOS'
# Backlog

| ID | Title | Status | Notes |
|---|---|---|---|
| 1 | Add greeting | ready | |
| 2 | Add greeting tests | ready | |
| 3 | Add farewell | ready | |
| 4 | Pick a date format | ready | |
| 5 | Sync with billing API | ready | |
EOS
    fi
    git add -A
    git commit -q -m "chore: fixture"
    git remote add origin https://github.com/example/fixture.git
    git update-ref refs/remotes/origin/main HEAD
    mkdir -p .planning/backlog-loop/dry-run
    jq -n '{
      next_pr: 201, prs: [], labels: ["backlog"], polls: {}, reruns: {}, ci: {pending_polls: 1},
      repo: { nameWithOwner: "example/fixture", viewerPermission: "ADMIN", defaultBranchRef: {name: "main"},
              squashMergeAllowed: true, mergeCommitAllowed: true, rebaseMergeAllowed: true, hasIssuesEnabled: true },
      issues: [
        {number: 1, title: "Add greeting", labels: ["backlog"], state: "OPEN", comments: []},
        {number: 2, title: "Add greeting tests", labels: ["backlog"], state: "OPEN", comments: []},
        {number: 3, title: "Add farewell", labels: ["backlog"], state: "OPEN", comments: []},
        {number: 4, title: "Pick a date format", labels: ["backlog"], state: "OPEN", comments: []},
        {number: 5, title: "Sync with billing API", labels: ["backlog"], state: "OPEN", comments: []}
      ] }' >.planning/backlog-loop/dry-run/gh.json
  )
}

# hook_input <event> <cwd> [extra jq object]
hook_input() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg e "$1" --arg cwd "$2" --argjson extra "$extra" \
    '{session_id: "dry", cwd: $cwd, permission_mode: "auto", hook_event_name: $e} + $extra'
}

bash_input() {
  # bash_input <cwd> <command>
  jq -n --arg cwd "$1" --arg c "$2" \
    '{session_id: "dry", cwd: $cwd, permission_mode: "auto", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}'
}
