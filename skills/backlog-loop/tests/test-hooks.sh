#!/usr/bin/env bash
# The Stop hook and the guard hook.
# shellcheck disable=SC2016,SC2119
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PLAN='{"source":"github","batches":[{"name":"A","theme":"Alpha","items":[{"id":"1","title":"One"}]}]}'
stop() { hook_input "$1" "${2:-}" | "$H" stop; }
guard() { bash_input "$1" | "$H" guard; }
decision() { printf '%s' "$1" | jq -r '.decision // .hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow; }
allowed() { if [ -z "$1" ]; then echo allow; else decision "$1"; fi; }

echo "Stop hook"
new_repo
assert_eq "no run: the stop is allowed" "allow" "$(allowed "$(stop s1)")"
execute "$PLAN"
out="$(stop s1)"
assert_eq "work remains: the stop is blocked" "block" "$(decision "$out")"
assert_contains "the reason names the next command" "loop.sh next" "$out"
assert_eq "a background worker is running: allowed" "allow" \
  "$(allowed "$(stop s1 '{"background_tasks":[{"id":"a","status":"running"}]}')")"
assert_eq "finished background workers do not count" "block" \
  "$(decision "$(stop s1 '{"background_tasks":[{"id":"a","status":"completed"}]}')")"
assert_eq "another session's run: allowed" "allow" "$(allowed "$(stop other)")"

next
assert_eq "progress resets the stall count" "block" "$(decision "$(stop s1)")"
stop s1 >/dev/null
stop s1 >/dev/null
out="$(stop s1)"
assert_eq "three stops without progress: allowed" "allow" "$(decision "$out")"
assert_eq "and the run is halted as stalled" "halted" "$(sget .run.status)"
assert_contains "with a reason" "stalled" "$(sget .run.reason)"
assert_eq "a halted run does not block" "allow" "$(allowed "$(stop s1)")"

new_repo
execute "$PLAN"
export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=3
stop s1 >/dev/null
next
stop s1 '{"stop_hook_active":true}' >/dev/null
next
out="$(stop s1 '{"stop_hook_active":true}')"
assert_eq "one below the block cap: allowed" "allow" "$(decision "$out")"
assert_eq "and the run stays resumable" "running" "$(sget .run.status)"
unset CLAUDE_CODE_STOP_HOOK_BLOCK_CAP

echo "Guard hook"
new_repo
assert_eq "no run: nothing is denied" "allow" "$(allowed "$(guard 'gh pr merge 5 --squash')")"
execute "$PLAN"
deny_case() { assert_eq "denied: $1" "deny" "$(decision "$(guard "$1")")"; }
allow_case() { assert_eq "allowed: $1" "allow" "$(allowed "$(guard "$1")")"; }
deny_case 'gh pr merge 5 --squash'
deny_case 'cd x && gh pr merge --admin'
deny_case 'gh api -X PUT repos/o/r/pulls/5/merge'
deny_case 'git push --force origin feature'
deny_case 'git push -f'
deny_case 'git push origin +HEAD:feature'
deny_case 'git push --force-with-lease origin feature'
deny_case 'git push origin main'
deny_case 'git push origin HEAD:main'
deny_case 'git -C /tmp/w push origin HEAD:refs/heads/main'
deny_case 'git push --all origin'
deny_case 'rm -rf .planning/backlog-loop'
deny_case 'echo {} > .planning/backlog-loop/state.json'
deny_case 'git clean -fdx'
allow_case 'git push origin HEAD:backlog-loop/A/batch-t1'
allow_case 'git push origin feature'
allow_case 'gh pr view 5 --json state'
allow_case 'gh pr checks 5'
allow_case 'cat .planning/backlog-loop/state.json'
allow_case 'git commit -m "fix: merge the two parsers"'
out="$(jq -n --arg cwd "$PWD" --arg f "$PWD/.planning/backlog-loop/state.json" \
  '{cwd: $cwd, tool_name: "Edit", tool_input: {file_path: $f}}' | "$H" guard)"
assert_eq "denied: editing state.json with a file tool" "deny" "$(decision "$out")"
out="$(jq -n --arg cwd "$PWD" --arg f "$PWD/.planning/backlog-loop/plan.json" \
  '{cwd: $cwd, tool_name: "Write", tool_input: {file_path: $f}}' | "$H" guard)"
assert_eq "allowed: writing plan.json" "allow" "$(allowed "$out")"

t_summary
