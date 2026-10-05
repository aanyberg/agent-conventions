#!/usr/bin/env bash
# Shared helpers for the plain-bash tests. Sourced by tests/test-*.sh.
# shellcheck disable=SC2034

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
L="$SKILL_DIR/scripts/loop.sh"
H="$SKILL_DIR/scripts/hooks.sh"
T_PASS=0
T_FAIL=0
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/backlog-loop-test.XXXXXX")"
T_TMP="$(cd "$T_TMP" && pwd -P)"
T_N=0
trap 'rm -rf "$T_TMP"' EXIT

PATH="$TESTS_DIR/stubs:$PATH"
export PATH
# No sleeping and no settle time in tests.
export BACKLOG_LOOP_POLL_SECONDS=0 BACKLOG_LOOP_SLICE_SECONDS=0 BACKLOG_LOOP_SETTLE_SECONDS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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
    *) not_ok "$1" "'$2' not found in: $(printf '%s' "$3" | head -c 400)" ;;
  esac
}

assert_lacks() {
  # assert_lacks <name> <needle> <haystack>
  case "$3" in
    *"$2"*) not_ok "$1" "'$2' found in: $(printf '%s' "$3" | head -c 400)" ;;
    *) ok "$1" ;;
  esac
}

t_summary() {
  printf '%s: %s passed, %s failed\n' "$(basename "$0")" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

# new_repo [config lines]: a repository with a bare origin and an empty gh
# database. Leaves the shell inside the clone. Config lines go into the
# "## Backlog loop" section of CLAUDE.md.
new_repo() {
  T_N=$((T_N + 1))
  local dir="$T_TMP/case-$T_N"
  mkdir -p "$dir"
  GH_STUB_ORIGIN="$dir/origin.git"
  GH_STUB_DB="$dir/gh.json"
  export GH_STUB_ORIGIN GH_STUB_DB
  git init -q --bare -b main "$GH_STUB_ORIGIN"
  git init -q -b main "$dir/repo"
  cd "$dir/repo" || exit 1
  git config user.email test@example.com
  git config user.name "Test"
  git config commit.gpgsign false
  {
    printf '# Fixture\n\n## Backlog loop\n\n'
    [ $# -eq 0 ] || printf -- '- %s\n' "$@"
    printf '\n## Other\n\n- source: ignored\n'
  } >CLAUDE.md
  printf '# Backlog\n\n| ID | Title | Status |\n|---|---|---|\n' >BACKLOG.md
  git add -A
  git commit -q -m "chore: fixture"
  git remote add origin "$GH_STUB_ORIGIN"
  git push -q -u origin main
  jq -n '{next: 1, prs: [], log: [], polls: {}, reruns: {}, runs: {},
    repo: {nameWithOwner: "example/fixture", viewerPermission: "ADMIN", defaultBranchRef: {name: "main"}}}' >"$GH_STUB_DB"
  STATE="$PWD/.planning/backlog-loop/state.json"
}

sget() { jq -r "$@" "$STATE"; }
ghlog() { jq -r '.log[]' "$GH_STUB_DB"; }
gh_set() { jq "$@" "$GH_STUB_DB" >"$GH_STUB_DB.tmp" && mv -f "$GH_STUB_DB.tmp" "$GH_STUB_DB"; }

# plan <json>: write plan.json and apply it.
plan() {
  mkdir -p .planning/backlog-loop
  printf '%s' "$1" >.planning/backlog-loop/plan.json
  "$L" plan-apply
}

# planned <json>: what /backlog-loop plan does.
planned() {
  "$L" start --session s1 plan >/dev/null
  plan "$1" >/dev/null
}

# execute <plan json> [start arguments]: plan, then start executing.
execute() {
  local p="$1"
  shift
  planned "$p"
  "$L" start --session s1 "$@" execute >/dev/null
}

# next: ask for the next action. Sets ACTION (JSON) and ACT (its name).
next() {
  ACTION="$("$L" next 2>&1)"
  ACT="$(printf '%s' "$ACTION" | jq -r '.action' 2>/dev/null)"
}

# commit_on <branch> <start point> <message> [file...]: one commit on a branch,
# made in a throwaway worktree the way a worker would. A file argument is a
# name, name=content, or -name to delete the file.
commit_on() {
  local branch="$1" from="$2" msg="$3" wt f name
  shift 3
  wt="$T_TMP/wt-$RANDOM-$RANDOM"
  git worktree add -q --detach "$wt" "$from" || return 1
  for f in "$@"; do
    name="${f%%=*}"
    case "$f" in
      -*) rm -f "$wt/${f#-}" ;;
      *=*) printf '%s\n' "${f#*=}" >"$wt/$name" ;;
      *) printf '%s\n' "$name" >"$wt/$name" ;;
    esac
  done
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "$msg"
  git branch -f "$branch" "$(git -C "$wt" rev-parse HEAD)" >/dev/null
  git worktree remove --force "$wt"
}

# work <item> [file...]: what an item worker does. One commit with the trailer
# on the item's branch. Without files it writes item-<id>.txt.
work() {
  local id="$1" branch
  shift
  [ $# -gt 0 ] || set -- "item-$id.txt"
  branch="$(sget --arg i "$id" '.items[$i].branch')"
  git fetch -q origin main
  commit_on "$branch" origin/main "feat: item $id

Backlog-Item: $id" "$@"
}

# push_on <batch> <message> [file...]: what a batch worker does. One commit on
# top of the pushed batch branch, pushed back.
push_on() {
  local b="$1" msg="$2" branch
  shift 2
  branch="$(jq -r --arg b "$b" '.batches[] | select(.name == $b) | .branch' "$STATE")"
  git fetch -q origin "$branch"
  commit_on "tmp-push-$$" "origin/$branch" "$msg" "$@" || return 1
  git push -q origin "tmp-push-$$:$branch"
  git branch -q -D "tmp-push-$$"
}

# drive: follow next like the orchestrator would, doing the plain work
# (implement, mark the backlog). Stops at done, halt or any other action.
drive() {
  local i=0 ids id b
  while [ "$i" -lt 60 ]; do
    i=$((i + 1))
    next
    case "$ACT" in
      implement)
        ids="$(printf '%s' "$ACTION" | jq -r '.items[].id')"
        # shellcheck disable=SC2086
        "$L" record started $ids >/dev/null
        for id in $ids; do
          work "$id"
          "$L" record item "$id" >/dev/null
        done
        ;;
      mark_backlog)
        b="$(printf '%s' "$ACTION" | jq -r '.batch')"
        "$L" record started --batch "$b" >/dev/null
        push_on "$b" "docs: mark batch $b done

Backlog-Status: $b" "BACKLOG.md=marked $b"
        "$L" record marked "$b" >/dev/null
        ;;
      wait) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# hook_input <session> [extra jq object]: the JSON a hook receives on stdin.
hook_input() {
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg s "$1" --arg cwd "$PWD" --argjson extra "$extra" '{session_id: $s, cwd: $cwd} + $extra'
}

bash_input() {
  # bash_input <command>
  jq -n --arg cwd "$PWD" --arg c "$1" \
    '{session_id: "s1", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}'
}
