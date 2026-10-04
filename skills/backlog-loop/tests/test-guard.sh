#!/usr/bin/env bash
# guard.sh: what the PreToolUse hook denies while a run is active, and what it
# must leave alone.
# shellcheck disable=SC2016
set -u
# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export BACKLOG_LOOP_DRY_RUN=1
unset BACKLOG_LOOP_ROOT BACKLOG_LOOP_NOW

t_tmp
REPO="$T_TMP/fixture"
make_fixture "$REPO" github
STATE_DIR="$REPO/.planning/backlog-loop"
STATE="$STATE_DIR/state.json"
# A running run with batch 1 waiting to merge PR #201, not yet verified.
jq '.batches |= map(if .id == 1 then .status = "in-progress" | .phase = "merge" | .pr = 201 | .branch = "backlog-loop/r/b1-t1" else . end)' \
  "$FIXTURES/base.json" >"$STATE"
jq '.prs = [{number: 201, head: "backlog-loop/r/b1-t1", base: "main", title: "t", body: "", state: "OPEN", merge_commit: null}]' \
  "$STATE_DIR/dry-run/gh.json" >"$STATE_DIR/gh.tmp" && mv "$STATE_DIR/gh.tmp" "$STATE_DIR/dry-run/gh.json"
git -C "$REPO" update-ref refs/remotes/origin/backlog-loop/r/b1-t1 "$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b feature

run_guard() { bash_input "${2:-$REPO}" "$1" | "$S/guard.sh"; }
verdict() {
  local out
  out="$(run_guard "$@")"
  if [ -z "$out" ]; then echo allow; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
denies() { assert_eq "denies: $1" "deny" "$(verdict "$1")"; }
allows() { assert_eq "allows: $1" "allow" "$(verdict "$1")"; }

echo "guard.sh: output format"
out="$(run_guard "git push --force origin feature")"
assert_eq "deny uses the PreToolUse decision format" "PreToolUse/deny" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput | "\(.hookEventName)/\(.permissionDecision)"')"
assert_contains "deny explains itself" "force-push is not allowed" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
assert_eq "exit status is 0 with a deny" "0" "$(run_guard "git push -f" >/dev/null; echo $?)"
assert_contains "denials are logged" "denied:" "$(cat "$STATE_DIR/run.log")"

echo "guard.sh: force-push in any form"
denies "git push --force origin feature"
denies "git push -f origin feature"
denies "git push -uf origin feature"
denies "git push --force-with-lease origin feature"
denies "git push --force-with-lease=feature origin feature"
denies "git push --force-if-includes origin feature"
denies "git push origin +feature"
denies "git push origin +feature:feature"
denies "git push --mirror origin"
denies "git -C . push -f origin feature"
denies "git -c push.default=current push --force"
denies "cd sub && git push --force origin feature"
denies "git fetch origin; git push -f origin feature"
denies 'echo "$(git push --force origin feature)"'
denies "FOO=bar git push -f origin feature"
denies "command git push --force origin feature"
denies "/usr/bin/git push --force origin feature"

echo "guard.sh: direct push to the base branch"
denies "git push origin main"
denies "git push origin HEAD:main"
denies "git push origin feature:main"
denies "git push origin feature:refs/heads/main"
denies "git push origin --delete main"
denies "git push origin :main"
denies "git push --all origin"
denies "git push -u origin main"
git -C "$REPO" checkout -q main
denies "git push"
denies "git push origin"
denies "git push origin HEAD"
git -C "$REPO" checkout -q feature

echo "guard.sh: merging"
denies "gh pr merge 201 --squash --admin"
denies "gh pr merge 201 --squash"
assert_contains "an unverified merge names the fix" "verify-batch.sh 1 pre-merge" "$(run_guard "gh pr merge 201 --squash" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
denies "gh pr merge --squash"
denies "gh pr merge 999 --squash"
denies "gh api -X PUT repos/example/fixture/pulls/201/merge"
jq '.run.flags.no_merge = true' "$STATE" >"$STATE.t" && mv "$STATE.t" "$STATE"
denies "gh pr merge 201 --squash"
assert_contains "--no-merge leaves merging to the user" "merged by the user" "$(run_guard "gh pr merge 201 --squash" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
jq '.run.flags.no_merge = false' "$STATE" >"$STATE.t" && mv "$STATE.t" "$STATE"

echo "guard.sh: state file"
denies "rm .planning/backlog-loop/state.json"
denies "rm -f $STATE"
denies "rm -rf .planning/backlog-loop"
denies "rm -rf .planning/backlog-loop/"
denies "rm -rf .planning"
denies "mv .planning/backlog-loop /tmp/x"
denies "echo '{}' > .planning/backlog-loop/state.json"
denies "jq '.run.status = \"done\"' .planning/backlog-loop/state.json > .planning/backlog-loop/state.json"
denies "sed -i '' 's/todo/merged/' .planning/backlog-loop/state.json"
denies "cp /tmp/x .planning/backlog-loop/state.json"
denies "tee .planning/backlog-loop/state.json"
denies "python3 -c 'open(\".planning/backlog-loop/state.json\",\"w\")'"
denies "git clean -fdx"
denies "git clean -xfd ."
for tool in Edit Write; do
  out="$(jq -n --arg cwd "$REPO" --arg t "$tool" --arg f "$STATE" \
    '{session_id: "dry", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: $t, tool_input: {file_path: $f}}' | "$S/guard.sh")"
  assert_eq "denies: $tool tool on state.json" "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
done

echo "guard.sh: what stays allowed"
allows "git status"
allows "git push origin feature"
allows "git push -u origin feature"
allows "git push origin backlog-loop/r/b1-t1"
allows "git push -q origin --delete backlog-loop/r/b1-t0"
allows "git push"
allows "git commit -m 'docs: explain why git push --force is banned'"
allows "git fetch origin main"
allows "git clean -fd"
allows "git log --oneline main"
allows "cat .planning/backlog-loop/state.json"
allows "jq .run .planning/backlog-loop/state.json"
allows "$S/state.sh record worker-done 1"
allows "$S/state.sh get '.run' && cat .planning/backlog-loop/state.json"
allows "rm .planning/backlog-loop/pr-body.md"
allows "rm -rf node_modules"
allows "gh pr view 201"
allows "gh pr checks 201"
allows "gh pr create --base main --head feature --title x --body y"
allows "npm test"
out="$(jq -n --arg cwd "$REPO" --arg f "$REPO/README.md" \
  '{session_id: "dry", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Edit", tool_input: {file_path: $f}}' | "$S/guard.sh")"
assert_empty "allows: Edit on other files" "$out"
out="$(jq -n --arg cwd "$REPO" '{session_id: "dry", cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Read", tool_input: {file_path: "x"}}' | "$S/guard.sh")"
assert_empty "allows: other tools" "$out"

echo "guard.sh: from a worktree of the same repository"
git -C "$REPO" worktree add -q "$T_TMP/wt" -b wt-branch main
assert_eq "denies a force-push from a worktree" "deny" "$(verdict "git push -f origin wt-branch" "$T_TMP/wt")"
assert_eq "allows a normal push from a worktree" "allow" "$(verdict "git push origin wt-branch" "$T_TMP/wt")"

echo "guard.sh: no active run -> silent"
jq '.run.status = "done"' "$STATE" >"$STATE.t" && mv "$STATE.t" "$STATE"
allows "git push --force origin main"
allows "rm -rf .planning/backlog-loop"
allows "gh pr merge 201 --admin"
rm -f "$STATE"
allows "git push --force origin main"
assert_eq "garbage input: exit 0" "0" "$(printf 'not json' | "$S/guard.sh" >/dev/null 2>&1; echo $?)"

t_summary
