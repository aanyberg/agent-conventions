#!/usr/bin/env bash
# Failure-path scenarios on the fixture repository, with gh and the remote side
# of git stubbed: preflight failures, flaky CI, CI timeout, a poisoned batch,
# merge conflicts, a red base branch after a merge, --no-merge, --plan-only,
# resume after a crash, and a concurrent run.
# shellcheck disable=SC2016
set -u
# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

export BACKLOG_LOOP_DRY_RUN=1
export BACKLOG_LOOP_POLL_SECONDS=0
export BACKLOG_LOOP_SLICE_SECONDS=0
unset BACKLOG_LOOP_ROOT BACKLOG_LOOP_NOW CLAUDE_CODE_STOP_HOOK_BLOCK_CAP
BACKLOG_LOOP_REAL_GIT="$(command -v git)"
export BACKLOG_LOOP_REAL_GIT
PATH="$SKILL_DIR/tests/stubs:$PATH"
export PATH

t_tmp
N=0
ACTION=""
TARGET=""
OUT=""

new_repo() {
  N=$((N + 1))
  REPO="$T_TMP/repo$N"
  make_fixture "$REPO" github
  cd "$REPO" || exit 1
  DIR="$REPO/.planning/backlog-loop"
  STATE="$DIR/state.json"
  GH="$DIR/dry-run/gh.json"
}

bq() { jq -r --argjson b "$1" ".batches[] | select(.id == \$b) | $2" "$STATE"; }
iq() { jq -r --arg i "$1" ".items[] | select(.id == \$i) | $2" "$STATE"; }

# start <plan json> [preflight flags]: preflight and plan.
start() {
  local plan="$1"
  shift
  "$S/preflight.sh" --session dry "$@" >/dev/null 2>&1 || { not_ok "preflight ($*)"; return 1; }
  printf '%s' "$plan" >"$DIR/plan.json"
  "$S/state.sh" plan-apply "$DIR/plan.json" >/dev/null || { not_ok "plan-apply"; return 1; }
}

worker() {
  # worker <branch> <start ref> <snippet>
  local wt="$T_TMP/wt-$RANDOM" rc
  git worktree add -q -B "$1" "$wt" "$2" >/dev/null 2>&1 || return 1
  (cd "$wt" && eval "$3")
  rc=$?
  git worktree remove --force "$wt" >/dev/null 2>&1
  return "$rc"
}

# What the simulated worker writes for an item. Scenarios override this.
# shellcheck disable=SC2317,SC2329
item_snippet() { printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1"; }

# implement <item>: one item worker, committing locally without pushing.
implement() {
  local i="$1" branch
  branch="$("$S/state.sh" record item-started "$i")" || return 1
  worker "$branch" "origin/main" "$(item_snippet "$i") git add -A; git commit -q -m 'feat: item $i' -m 'Backlog-Item: $i'" || return 1
  "$S/state.sh" record item-done "$i" >/dev/null
}

# apply <item> <resolution snippet>: an apply worker on the local batch branch.
apply() {
  local i="$1" branch wt
  branch="$("$S/state.sh" record apply-started "$i")" || return 1
  wt="$T_TMP/wt-$RANDOM"
  git worktree add -q "$wt" "$branch" >/dev/null 2>&1 || return 1
  (cd "$wt" && git cherry-pick "$(iq "$i" '.branch')" >/dev/null 2>&1; eval "$2")
  git worktree remove --force "$wt" >/dev/null 2>&1
}

next() {
  OUT="$("$S/next.sh")"
  ACTION="$(printf '%s' "$OUT" | jq -r '.action')"
  TARGET="$(printf '%s' "$OUT" | jq -r '.batch // .item // (.batches // [] | map(tostring) | join(","))')"
}

# Do the routine part of an action. Returns 1 for actions a scenario must handle.
auto() {
  local b pre cmd
  case "$ACTION" in
    implement_items) for i in $(printf '%s' "$OUT" | jq -r '.items[]'); do implement "$i" || return 2; done ;;
    integrate) "$S/state.sh" integrate "$TARGET" >/dev/null ;;
    open_pr) "$S/state.sh" open-pr "$TARGET" >/dev/null ;;
    wait_ci) "$S/ci-wait.sh" "$TARGET" >/dev/null ;;
    rerun_ci) "$S/ci-wait.sh" "$TARGET" --rerun >/dev/null ;;
    rebase_batch) "$S/verify-batch.sh" "$TARGET" rebase >/dev/null ;;
    verify) "$S/verify-batch.sh" "$TARGET" post-merge >/dev/null ;;
    merge)
      pre="$("$S/verify-batch.sh" "$TARGET" pre-merge)"
      case "$pre" in
        READY*)
          cmd="$(printf '%s\n' "$pre" | sed -n 's/^Merge command: //p')"
          [ -z "$(bash_input "$REPO" "$cmd" | "$S/guard.sh")" ] || return 2
          eval "$cmd" >/dev/null && "$S/verify-batch.sh" "$TARGET" merged >/dev/null
          ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# run_until <action>: drive the loop until next.sh returns the given action.
run_until() {
  local want="$1" i=0
  while [ "$i" -lt 80 ]; do
    i=$((i + 1))
    next
    [ "$ACTION" != "$want" ] || return 0
    auto || return 1
  done
  return 1
}

ONE='{"batches":[{"theme":"All","items":["1","2","3","4","5"]}]}'
SPLIT='{"batches":[{"theme":"A","items":["1","2"]},{"theme":"B","items":["3"]},{"theme":"C","items":[{"id":"4","needs":["1"]},"5"]}]}'

# ------------------------------------------------------------------------------------
echo "scenario: preflight collects every failure and changes nothing"
new_repo
touch .ci-fail
git add .ci-fail && git commit -q -m "break the base" && git update-ref refs/remotes/origin/main HEAD
echo "dirty" >>CLAUDE.md
jq '.rules = [{"type": "pull_request", "parameters": {"required_approving_review_count": 1}}]
  | .repo.squashMergeAllowed = false' "$GH" >"$GH.t" && mv "$GH.t" "$GH"
out="$("$S/preflight.sh" --session dry 2>&1)"
rc=$?
assert_eq "preflight exits non-zero" "1" "$rc"
assert_contains "summary line counts failures" "passed, 4 failed" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_contains "branch rule failure, as specified" "FAIL  Branch rules: main requires 1 approving review" "$out"
assert_contains "each failure comes with a fix" "      Fix: allow bypass for your account, or run with --no-merge" "$out"
assert_contains "dirty tree is reported" "FAIL  Working tree: tracked files have uncommitted changes" "$out"
assert_contains "merge method is reported" "FAIL  PR and merge: merge method 'squash' is not allowed" "$out"
assert_contains "a red base branch fails the baseline, read from CI" "FAIL  Baseline: CI is red on main: ci" "$out"
assert_contains "the baseline fix is stated" "Fix: main must be green before starting" "$out"
assert_contains "it says nothing was changed" "Nothing was changed." "$(printf '%s\n' "$out" | tail -n 1)"
assert_eq "no state was created" "no" "$([ -e "$STATE" ] || [ -e "$DIR/config.json" ] && echo yes || echo no)"
assert_eq "no ignore entry was written" "1" "$(git check-ignore -q "$DIR/state.json"; echo $?)"
git checkout -q CLAUDE.md
out="$("$S/preflight.sh" --session dry --no-merge 2>&1)"
case "$out" in *"Branch rules: main requires"*) not_ok "--no-merge accepts required approvals" ;; *) ok "--no-merge accepts required approvals" ;; esac

new_repo
git checkout -q -b other
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "wrong branch is reported" "the checkout is on 'other', not on the base branch 'main'" "$out"
git checkout -q main
sed -i.bak 's/^- merge-method:.*/- merge-method: fastest/' CLAUDE.md && rm -f CLAUDE.md.bak
git commit -q -am "bad config" && git update-ref refs/remotes/origin/main HEAD
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "bad config is reported" "FAIL  Config: merge-method must be squash, merge or rebase" "$out"
assert_contains "the fix shows the exact section" "## Backlog loop" "$out"
assert_contains "the section lists the keys" "- merge-method: squash" "$out"
out="$("$S/preflight.sh" --session dry --resume 2>&1)"
assert_contains "--resume without a run fails" "there is no unfinished run" "$out"

new_repo
mkdir -p .claude
echo '{"permissions": {"deny": ["Bash(git push *)", "WebFetch"]}}' >.claude/settings.json
git add .claude && git commit -q -m "settings" && git update-ref refs/remotes/origin/main HEAD
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "a deny rule on a needed command fails" "FAIL  Claude tools: deny rule 'Bash(git push *)'" "$out"
assert_contains "a denied web tool is a warning" "WARN  Research: deny rule 'WebFetch'" "$out"

new_repo
jq '.rules = [{"type": "merge_queue"}, {"type": "update"}]' "$GH" >"$GH.t" && mv "$GH.t" "$GH"
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "a merge queue fails without --no-merge" "FAIL  Branch rules: main uses a merge queue" "$out"
assert_contains "restricted updates are a warning" "WARN  Branch rules: a ruleset restricts updates to main" "$out"

new_repo
out="$("$S/preflight.sh" --session dry --gitignore 2>&1)"
assert_contains "--gitignore writes .gitignore" ".planning/backlog-loop/" "$(cat .gitignore)"
assert_eq "probes never run the test suite" "git status --short|gh auth status|" "$("$S/preflight.sh" --probes | tr '\n' '|')"
assert_eq "no test command is configured or stored" "null" "$(jq -r '.test // "null"' "$DIR/config.json")"
assert_eq "five items run in parallel by default" "5" "$(jq -r '.limits.parallel_items' "$DIR/config.json")"
assert_eq "one commit per item by default" "per-item" "$(jq -r '.batch_commits' "$DIR/config.json")"
assert_eq "default models per tier" "haiku,sonnet,opus" "$(jq -r '[.models.light, .models.standard, .models.complex] | join(",")' "$DIR/config.json")"

new_repo
printf -- '- model-complex: fable\n' >>CLAUDE.md
git commit -q -am "model config" && git update-ref refs/remotes/origin/main HEAD
"$S/preflight.sh" --session dry >/dev/null 2>&1
assert_eq "a configured model is stored" "fable" "$(jq -r '.models.complex' "$DIR/config.json")"

new_repo
printf -- '- model-light: gpt\n' >>CLAUDE.md
git commit -q -am "bad model" && git update-ref refs/remotes/origin/main HEAD
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "an unknown model is reported" "model-light must be haiku, sonnet, opus, fable or inherit, not 'gpt'" "$out"

new_repo
printf -- '- agent-standard: backlog-worker\n- agent-light: helper\n' >>CLAUDE.md
mkdir -p .claude/agents && printf -- '---\nname: helper\n---\n' >.claude/agents/helper.md
git add -A && git commit -q -m "agents" && git update-ref refs/remotes/origin/main HEAD
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "a configured agent without an agent file is a warning" "WARN  Agents: agent-standard names 'backlog-worker', but no backlog-worker.md is in .claude/agents or ~/.claude/agents" "$out"
case "$out" in *"agent-light names"*) not_ok "an agent with a file passes" ;; *) ok "an agent with a file passes" ;; esac
assert_eq "configured agents are stored" "backlog-worker/helper" "$(jq -r '"\(.agents.standard)/\(.agents.light)"' "$DIR/config.json")"

new_repo
printf -- '- batch-commits: one\n' >>CLAUDE.md
git commit -q -am "bad commits" && git update-ref refs/remotes/origin/main HEAD
assert_contains "an unknown batch-commits value is reported" "batch-commits must be per-item or squashed, not 'one'" "$("$S/preflight.sh" --session dry 2>&1)"

new_repo
mkdir -p "$DIR"
jq '.version = 1 | .run.status = "halted"' "$FIXTURES/base.json" >"$STATE"
out="$("$S/preflight.sh" --session dry 2>&1)"
assert_contains "a run from the previous version is not resumed" "FAIL  Filesystem: the unfinished run was started by an older backlog-loop" "$out"
assert_contains "the fix says what to do" "finish it with the previous version, or move $DIR away to start a new run" "$out"

# ------------------------------------------------------------------------------------
echo "scenario: flaky CI passes after one rerun"
new_repo
item_snippet() { printf "echo 'feature %s' > feature-%s.txt; touch .ci-flaky;" "$1" "$1"; }
start "$ONE" && run_until "done"
assert_eq "the run finishes" "done" "$ACTION"
assert_eq "one rerun, no fix, no attempt counted" "1/0/0" "$(bq 1 '"\(.ci_reruns)/\(.fixes)"')/$(iq 1 '.attempts')"

# ------------------------------------------------------------------------------------
echo "scenario: CI never finishes"
new_repo
item_snippet() { printf "echo 'feature %s' > feature-%s.txt; touch .ci-hang;" "$1" "$1"; }
start "$ONE" && run_until wait_ci
out="$("$S/ci-wait.sh" 1)"
assert_contains "within the deadline the wait reports pending" "PENDING" "$out"
assert_eq "a pending slice still counts as progress" "1" "$(bq 1 '.ci_polls')"
out="$(BACKLOG_LOOP_NOW=$(($(date +%s) + 46 * 60)) "$S/ci-wait.sh" 1)"
assert_contains "past the deadline the wait gives up" "TIMEOUT" "$out"
assert_eq "the timeout counts as a failed attempt" "fix/1" "$(bq 1 '.phase')/$(iq 1 '.attempts')"
next
assert_eq "next action is fix_ci" "fix_ci" "$ACTION"
assert_contains "the timeout variant is offered" "ci-retry" "$OUT"

# ------------------------------------------------------------------------------------
echo "scenario: one item poisons its batch"
new_repo
item_snippet() {
  printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1"
  [ "$1" != "2" ] || printf " touch .ci-fail;"
}
start "$SPLIT" && run_until fix_ci
assert_eq "the red batch is batch 1" "1" "$TARGET"
"$S/state.sh" record poison 1 2 --reason "item 2 breaks CI" >/dev/null
next
assert_eq "next action is drop_item" "drop_item/2" "$ACTION/$(printf '%s' "$OUT" | jq -r '.item')"
"$S/state.sh" cleanup 1
prompt="$("$S/state.sh" worker-prompt 1 --mode drop --item 2)"
assert_contains "drop prompt names the trailer" "Backlog-Drop: 2" "$prompt"
branch="$(bq 1 '.branch')"
assert_contains "dropping needs the revert on the branch" "no commit with trailer" "$("$S/state.sh" record item-dropped 2 2>&1)"
worker "$branch" "origin/$branch" "sha=\$(git log --format=%H --grep='Backlog-Item: 2' origin/main..HEAD);
  git revert --no-commit \$sha; git commit -q -m 'revert: drop backlog item 2' -m 'Backlog-Drop: 2'; git push -q origin $branch"
"$S/state.sh" record item-dropped 2 >/dev/null
assert_eq "item 2 left batch 1 and got its own batch" "1/4/todo" "$(bq 1 '.items | join(",")')/$(iq 2 '.batch')/$(iq 2 '.status')"
assert_eq "the innocent item got its attempt back" "0/1" "$(iq 1 '.attempts')/$(iq 2 '.attempts')"
# The retry of item 2 keeps failing: the worker's "fixes" do not help.
i=0
while [ "$i" -lt 60 ]; do
  i=$((i + 1))
  next
  case "$ACTION" in
    fix_ci)
      "$S/state.sh" cleanup "$TARGET"
      branch="$(bq "$TARGET" '.branch')"
      worker "$branch" "origin/$branch" "echo \$RANDOM >> attempt.txt; git add -A; git commit -q -m 'fix: try again'; git push -q origin $branch"
      "$S/state.sh" record fix-pushed "$TARGET" >/dev/null
      ;;
    mark_blocked)
      "$S/mark-blocked.sh" "$TARGET" --tried "two fixes" --why "$(iq "$TARGET" '.last_error')" --needs "a human look at the failing check" >/dev/null
      ;;
    done | halt) break ;;
    *) auto || break ;;
  esac
done
assert_eq "the run finishes" "done" "$ACTION"
assert_eq "item 2 is blocked after three attempts, the rest is merged" "1,3,4,5/2/3" \
  "$(jq -r '[.items[] | select(.status == "merged") | .id] | join(",")' "$STATE")/$(jq -r '[.items[] | select(.status == "blocked") | .id] | join(",")' "$STATE")/$(iq 2 '.attempts')"
assert_eq "a blocked retry does not block items that need the original batch" "merged" "$(bq 3 '.status')"
assert_eq "the retry batch ends blocked and its PR is closed" "blocked/CLOSED" "$(bq 4 '.status')/$(jq -r '.prs[] | select(.head | test("b4-")) | .state' "$GH")"
assert_eq "the blocked batch's branch is removed from the remote when the run is done" "" \
  "$(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/backlog-loop/*' | tr '\n' ' ')"
git branch -q worktree-agent-stray origin/main
git commit -q --allow-empty -m "unmerged work" && git branch -q worktree-agent-keep && git reset -q --hard origin/main
"$S/state.sh" record run "done" 2>/dev/null
assert_eq "merged-in worker worktree branches are removed, ones with own commits are kept" "worktree-agent-keep" \
  "$(git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-*' | tr '\n' ' ' | sed 's/ $//')"
case "$(git ls-tree -r --name-only origin/main | tr '\n' ' ')" in
  *feature-2.txt* | *.ci-fail*) not_ok "nothing of item 2 reached the base branch" ;;
  *) ok "nothing of item 2 reached the base branch" ;;
esac

# ------------------------------------------------------------------------------------
echo "scenario: merge conflict with the base branch, fixed in one attempt"
# Someone else changes shared.txt on main while batch 1 waits for CI.
human_commit() {
  worker "human-$RANDOM" origin/main "echo 'written by a human' > shared.txt; git add -A; git commit -q -m 'human change'" &&
    git update-ref refs/remotes/origin/main "$(git for-each-ref --sort=-committerdate --format='%(objectname)' 'refs/heads/human-*' | head -n 1)"
}
new_repo
item_snippet() {
  case "$1" in
    1) printf "echo 'written by item 1' > shared.txt;" ;;
    *) printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1" ;;
  esac
}
start "$SPLIT" && run_until wait_ci && human_commit
run_until resolve_conflict
assert_eq "batch 1 hits the conflict" "1" "$TARGET"
"$S/state.sh" cleanup 1
assert_contains "conflict prompt forbids rebasing" "Do not rebase" "$("$S/state.sh" worker-prompt 1 --mode conflict)"
branch="$(bq 1 '.branch')"
worker "$branch" "origin/$branch" "git merge -q origin/main >/dev/null 2>&1; echo 'item 1 and the human' > shared.txt; git add -A; git commit -q -m 'merge main'; git push -q origin $branch"
"$S/state.sh" record conflict-resolved 1 >/dev/null
assert_eq "resolved conflict goes back to CI" "ci/1" "$(bq 1 '"\(.phase)/\(.conflict_attempts)"')"
run_until "done"
assert_eq "the run finishes with everything merged" "done/5" "$ACTION/$(jq '[.items[] | select(.status == "merged")] | length' "$STATE")"
assert_eq "both sides of the conflict survive" "item 1 and the human" "$(git show origin/main:shared.txt)"

echo "scenario: merge conflict with the base branch, fix fails, batch is re-queued last"
new_repo
start "$SPLIT" && run_until wait_ci && human_commit
run_until resolve_conflict
old_branch="$(bq 1 '.branch')"
"$S/state.sh" record conflict-failed 1 >/dev/null
assert_eq "the batch is back in the queue, last, on a new try" "todo/2/CLOSED" "$(bq 1 '"\(.status)/\(.tries)"')/$(jq -r '.prs[] | select(.head | test("b1-t1")) | .state' "$GH")"
run_until "done"
assert_eq "the re-queued batch merges from the new base" "done/merged" "$ACTION/$(bq 1 '.status')"
assert_eq "its stale branch is gone from the remote" "" "$(git rev-parse -q --verify "refs/remotes/origin/$old_branch" || true)"
assert_contains "the report counts the re-queue" "1 re-queue" "$("$S/report.sh")"

# ------------------------------------------------------------------------------------
echo "scenario: ten items in one batch run in parallel and land in one PR"
new_repo
jq '.issues += [range(6; 11) | {number: ., title: "Item \(.)", labels: ["backlog"], state: "OPEN", comments: []}]' "$GH" >"$GH.t" && mv "$GH.t" "$GH"
jq '.issues += [range(11; 13) | {number: ., title: "Item \(.)", labels: ["backlog"], state: "OPEN", comments: []}]' "$GH" >"$GH.t" && mv "$GH.t" "$GH"
printf -- '- parallel-items: 5\n' >>CLAUDE.md && git commit -q -am "limits" && git update-ref refs/remotes/origin/main HEAD
item_snippet() { printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1"; }
start '{"batches":[{"theme":"Ten","items":["1","2","3","4","5","6","7","8","9","10"]},{"theme":"Rest","items":["11","12"]}]}'
next
assert_eq "the first five items start together" "implement_items/1,2,3,4,5" "$ACTION/$(printf '%s' "$OUT" | jq -r '.items | join(",")')"
for i in 1 2 3 4 5; do "$S/state.sh" record item-started "$i" >/dev/null; done
next
assert_eq "with every slot busy the loop waits" "wait_worker" "$ACTION"
for i in 1 2 3; do
  worker "$(iq "$i" '.branch')" origin/main "$(item_snippet "$i") git add -A; git commit -q -m 'feat: item $i' -m 'Backlog-Item: $i'"
  "$S/state.sh" record item-done "$i" >/dev/null
done
next
assert_eq "three finished, three more start" "implement_items/6,7,8" "$ACTION/$(printf '%s' "$OUT" | jq -r '.items | join(",")')"
assert_eq "nothing was pushed by the workers" "" "$(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/backlog-loop/*' | tr '\n' ' ')"
for i in 4 5; do
  worker "$(iq "$i" '.branch')" origin/main "$(item_snippet "$i") git add -A; git commit -q -m 'feat: item $i' -m 'Backlog-Item: $i'"
  "$S/state.sh" record item-done "$i" >/dev/null
done
auto && run_until open_pr
assert_eq "the batch branch has one commit per item, in plan order" "1 2 3 4 5 6 7 8 9 10" \
  "$(git log --reverse --format=%B "origin/main..refs/heads/$(bq 1 '.branch')" | sed -n 's/^Backlog-Item: //p' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "batch 2 has not started" "todo/null" "$(bq 2 '.status')/$(iq 11 '.phase')"
auto
assert_eq "the branch is pushed once, with the PR" "1/$(git rev-parse "refs/heads/$(bq 1 '.branch')")" \
  "$(jq '[.prs[]] | length' "$GH")/$(git rev-parse "refs/remotes/origin/$(bq 1 '.branch')")"
run_until "done"
assert_eq "the run finishes" "done/12" "$ACTION/$(jq '[.items[] | select(.status == "merged")] | length' "$STATE")"
assert_eq "two batches, two PRs" "2" "$(jq '.prs | length' "$GH")"

# ------------------------------------------------------------------------------------
echo "scenario: two items of a batch conflict, the apply worker resolves it"
new_repo
item_snippet() {
  case "$1" in
    1 | 2) printf "echo 'written by item %s' > shared.txt;" "$1" ;;
    *) printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1" ;;
  esac
}
start "$SPLIT" && run_until apply_item
assert_eq "the second item conflicts" "2/1/applied/conflict" "$(printf '%s' "$OUT" | jq -r '.item')/$(bq 1 '.items | length - 1')/$(iq 1 '.phase')/$(iq 2 '.phase')"
assert_contains "the apply prompt names the item branch" "git cherry-pick $(iq 2 '.branch')" "$("$S/state.sh" worker-prompt 1 --mode apply --item 2)"
apply 2 "echo 'items 1 and 2' > shared.txt; git add -A; GIT_EDITOR=true git cherry-pick --continue >/dev/null 2>&1"
"$S/state.sh" record apply-done 2 >/dev/null
assert_eq "applied: the PR opens next" "open-pr" "$(bq 1 '.phase')"
run_until "done"
assert_eq "both items are merged" "merged/merged" "$(iq 1 '.status')/$(iq 2 '.status')"
assert_eq "both sides survive" "items 1 and 2" "$(git show origin/main:shared.txt)"

echo "scenario: the apply worker fails, the item moves to the next batch"
new_repo
start "$SPLIT" && run_until apply_item
apply 2 "git cherry-pick --abort >/dev/null 2>&1"
"$S/state.sh" record apply-done 2 >/dev/null
assert_eq "the item moved on with an attempt counted" "2/1" "$(iq 2 '.batch')/$(iq 2 '.attempts')"
assert_eq "the PR opens with the rest" "open-pr/1" "$(bq 1 '.phase')/$(bq 1 '.items | join(",")')"
run_until "done"
assert_eq "the moved item merges with batch 2, built on batch 1" "merged/2/written by item 2" "$(iq 2 '.status')/$(iq 2 '.batch')/$(git show origin/main:shared.txt)"
assert_contains "the report lists the move" "Moved:   #2 from batch 1 to batch 2" "$("$S/report.sh")"

# ------------------------------------------------------------------------------------
echo "scenario: every item of a batch fails, the batch closes without a PR"
new_repo
start "$SPLIT"
next
for i in 1 2; do
  "$S/state.sh" record item-started "$i" >/dev/null
  "$S/state.sh" record item-failed "$i" --reason "crashed" >/dev/null
done
assert_eq "batch 1 is closed, no PR" "closed/null/0" "$(bq 1 '"\(.status)/\(.pr)"')/$(jq '.prs | length' "$GH")"
assert_eq "its items moved to batch 2" "2/2" "$(iq 1 '.batch')/$(iq 2 '.batch')"

# ------------------------------------------------------------------------------------
echo "scenario: batch-commits squashed"
new_repo
printf -- '- batch-commits: squashed\n' >>CLAUDE.md && git commit -q -am "squash" && git update-ref refs/remotes/origin/main HEAD
item_snippet() { printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1"; }
start "$ONE" && run_until open_pr
branch="$(bq 1 '.branch')"
assert_eq "the batch branch has one commit" "1" "$(git rev-list --count "origin/main..refs/heads/$branch")"
assert_eq "it carries every item's trailer" "1,2,3,4,5" "$(git log -1 --format=%B "refs/heads/$branch" | sed -n 's/^Backlog-Item: //p' | tr '\n' ',' | sed 's/,$//')"
run_until "done"
assert_eq "the run finishes" "done/5" "$ACTION/$(jq '[.items[] | select(.status == "merged")] | length' "$STATE")"

# ------------------------------------------------------------------------------------
echo "scenario: base branch red after a merge"
new_repo
item_snippet() {
  printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1"
  [ "$1" != "1" ] || printf " touch .ci-fail-base;"
}
start "$SPLIT" && run_until revert_batch
assert_eq "the batch to revert is batch 1" "1" "$TARGET"
assert_contains "the action explains why" "CI failed on main: ci" "$(printf '%s' "$OUT" | jq -r '.summary')"
url="$(gh pr revert "$(bq 1 '.pr')" --title "revert: backlog batch 1" --body "red")"
rpr="${url##*/}"
"$S/state.sh" record revert-opened 1 "$rpr"
assert_contains "the revert cannot be recorded before it is merged" "not MERGED" "$("$S/state.sh" record reverted 1 2>&1)"
state="PENDING"
while [ "$state" = "PENDING" ]; do state="$("$S/ci-wait.sh" --pr "$rpr")"; done
assert_eq "the revert PR goes green" "GREEN" "$state"
assert_empty "guard allows merging the green revert PR" "$(bash_input "$REPO" "gh pr merge $rpr --squash" | "$S/guard.sh")"
gh pr merge "$rpr" --squash >/dev/null
"$S/state.sh" record reverted 1 >/dev/null
assert_eq "batch blocked, run halted" "blocked/halted" "$(bq 1 '.status')/$(jq -r '.run.status' "$STATE")"
assert_eq "its items are blocked" "blocked,blocked" "$(jq -r '[.items[] | select(.id == "1" or .id == "2") | .status] | join(",")' "$STATE")"
next
assert_eq "the loop halts" "halt" "$ACTION"
assert_contains "the halt names the revert" "reverted in PR #$rpr" "$(printf '%s' "$OUT" | jq -r '.summary')"
assert_eq "the base branch no longer has the breaking change" "" "$(git ls-tree -r --name-only origin/main | grep -x '.ci-fail-base' || true)"
assert_contains "the report says why the loop halted" "Backlog loop halted: base branch was red" "$("$S/report.sh")"
assert_eq "issue 1 is labelled blocked" "true" "$(jq '.issues[] | select(.number == 1) | .labels | index("blocked") != null' "$GH")"

# ------------------------------------------------------------------------------------
echo "scenario: --no-merge stops at green pull requests"
new_repo
item_snippet() { printf "echo 'feature %s' > feature-%s.txt;" "$1" "$1"; }
start "$SPLIT" --no-merge && run_until halt
assert_eq "the run halts at the first green PR" "pr-ready,todo,todo" "$(jq -r '[.batches[].status] | join(",")' "$STATE")"
assert_contains "the halt asks for the merge" "wait for your merge" "$(printf '%s' "$OUT" | jq -r '.summary')"
assert_eq "nothing was merged" "0" "$(jq '[.prs[] | select(.state == "MERGED")] | length' "$GH")"
report="$("$S/report.sh")"
assert_contains "the report lists the PR to merge" "Merge:   #201 are green and wait for you" "$report"
assert_contains "the report counts items awaiting merge" "2 awaiting your merge" "$report"
gh pr merge 201 --squash >/dev/null
"$S/preflight.sh" --session dry --resume --no-merge >/dev/null 2>&1 || not_ok "resume after the human merge"
run_until halt
assert_eq "after the human merge the next batch gets its PR" "halt/merged,pr-ready,todo" "$ACTION/$(jq -r '[.batches[].status] | join(",")' "$STATE")"
assert_eq "merged work is verified on the base branch" "merged" "$(iq 1 '.status')"

# ------------------------------------------------------------------------------------
echo "scenario: --plan-only, then resume"
new_repo
start "$SPLIT" --plan-only
next
assert_eq "plan-only halts after planning" "halt" "$ACTION"
assert_contains "it points at the plan" "plan.md" "$OUT"
assert_empty "the stop gate lets the turn end" "$(hook_input Stop "$REPO" | "$S/stop-gate.sh")"
assert_eq "no work was started" "0" "$(jq '[.batches[] | select(.status != "todo")] | length' "$STATE")"
"$S/preflight.sh" --session dry >/dev/null 2>&1
next
assert_eq "running the skill again executes the plan" "implement_items" "$ACTION"

# ------------------------------------------------------------------------------------
echo "scenario: crash, concurrent run, resume"
new_repo
start "$SPLIT"
run_until verify && auto # batch 1 merged and verified
assert_eq "batch 1 is merged before the crash" "merged" "$(bq 1 '.status')"
next # implement_items for batch 2
"$S/state.sh" record item-started 3 >/dev/null # ...and the session dies here
out="$("$S/preflight.sh" --session other 2>&1)"
assert_contains "a second session is refused while the first is alive" "FAIL  Filesystem: another session (dry) is running the loop" "$out"
touch -t 202001010000 "$DIR/lock"
out="$("$S/preflight.sh" --session other 2>&1)"
assert_contains "once the lock is stale the run is resumed" "resumed" "$out"
assert_eq "the lost worker's item starts again without an attempt" "null/0" "$(iq 3 '.phase')/$(iq 3 '.attempts')"
assert_eq "merged batches are not redone" "merged/201" "$(bq 1 '"\(.status)/\(.pr)"')"
assert_eq "the new session owns the lock" "other" "$(sed -n 1p "$DIR/lock")"
run_until "done"
assert_eq "the resumed run finishes" "done/5" "$ACTION/$(jq '[.items[] | select(.status == "merged")] | length' "$STATE")"
assert_eq "three PRs, none duplicated" "3" "$(jq '.prs | length' "$GH")"
out="$("$S/preflight.sh" --session again 2>&1)"
assert_contains "with an empty backlog a new run does not start" "FAIL  Issues: no open issues carry the label 'backlog'" "$out"
jq '.issues += [{number: 6, title: "A new item", labels: ["backlog"], state: "OPEN", comments: []}]' "$GH" >"$GH.t" && mv "$GH.t" "$GH"
out="$("$S/preflight.sh" --session again 2>&1)"
assert_contains "after a finished run, a new run starts and the old one is archived" "Archived run" "$out"
assert_eq "the new run has only the new item" "6" "$(jq -r '[.items[].id] | join(",")' "$STATE")"

t_summary
