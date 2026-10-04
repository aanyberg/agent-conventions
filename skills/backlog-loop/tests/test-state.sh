#!/usr/bin/env bash
# state.sh: transitions, limits and bookkeeping, driven by fixture state files.
# The paths that need a real repository are covered by dry-run.sh.
# shellcheck disable=SC2016
set -u
# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export BACKLOG_LOOP_DRY_RUN=1
export BACKLOG_LOOP_NOW=2000

DEFS='
def inprog($b; $phase): .batches |= map(if .id == $b then .status = "in-progress" | .phase = $phase
    | .branch = "backlog-loop/r/b\($b)-t1" | .pushed = true | .pr = (200 + $b) | .ci_started_at = 1900
    | .head_sha = "aaa" | .worker_started_at = 1900 else . end)
  | .items |= map(if .batch == $b then .status = "in-progress" else . end);
'
st() { "$S/state.sh" "$@"; }
b1() { sget ".batches[] | select(.id == 1) | $1"; }
attempts() { sget "[.items[] | select(.id == \"$1\") | .attempts][0]"; }

echo "state.sh: writes"
use_state base.json
before="$(st hash)"
st tick
st gate abc 1 2 auto
assert_eq "hash ignores iteration and gate bookkeeping" "$before" "$(st hash)"
assert_eq "gate bookkeeping is stored" "abc/1/2/auto" "$(sget '"\(.run.last_hash)/\(.run.unchanged_gates)/\(.run.gate_blocks)/\(.run.permission_mode)"')"
st record worker-started 1 >/dev/null
[ "$before" != "$(st hash)" ] && ok "hash changes with a transition" || not_ok "hash changes with a transition"
assert_empty "atomic writes leave no temp files" "$(find "$STATE_DIR" -name '*.tmp*')"
assert_eq "state stays valid JSON" "0" "$(jq -e . "$STATE" >/dev/null 2>&1; echo $?)"
out="$(st record worker-started 99 2>&1)"
assert_contains "unknown batch is rejected" "unknown batch" "$out"
out="$(st record fix-pushed 2 2>&1)"
assert_contains "a transition from the wrong phase is rejected" "expected: fix" "$out"

echo "state.sh: plan-apply"
plan() { printf '%s' "$1" >"$STATE_DIR/plan.json"; st plan-apply "$STATE_DIR/plan.json" 2>&1; }
fresh='.batches = [] | .items |= map(.batch = null)'
use_state base.json "$fresh"
out="$(plan '{"batches":[{"theme":"A","items":["1","2"]},{"theme":"B","items":["3","4","5"],"depends_on":[1]}],"unclear":[{"id":"4","question":"which?"}]}')"
assert_contains "valid plan is applied" "Plan applied: 2 batches" "$out"
assert_eq "items point at their batch" "1,1,2,2,2" "$(sget '[.items[].batch | tostring] | join(",")')"
assert_eq "unclear items are queued for research" "pending" "$(sget '.items[] | select(.id == "4") | .research')"
assert_contains "plan.md is written" "## Batch 2: B" "$(cat "$STATE_DIR/plan.md")"
use_state base.json "$fresh"
assert_contains "plan missing an item is rejected" "item 5 is in 0 batches" "$(plan '{"batches":[{"theme":"A","items":["1","2","3","4"]}]}')"
assert_contains "plan with an item twice is rejected" "item 1 is in 2 batches" "$(plan '{"batches":[{"theme":"A","items":["1","2","3","4","5"]},{"theme":"B","items":["1"]}]}')"
assert_contains "plan with an unknown item is rejected" "item 9 is not an open backlog item" "$(plan '{"batches":[{"theme":"A","items":["1","2","3","4","5","9"]}]}')"
assert_contains "plan depending on a later batch is rejected" "may only depend on earlier batches" "$(plan '{"batches":[{"theme":"A","items":["1","2"],"depends_on":[2]},{"theme":"B","items":["3","4","5"]}]}')"
assert_contains "plan with an empty batch is rejected" "batch 2 has no items" "$(plan '{"batches":[{"theme":"A","items":["1","2","3","4","5"]},{"theme":"B","items":[]}]}')"
assert_contains "plan without a theme is rejected" "batch 1 has no theme" "$(plan '{"batches":[{"items":["1","2","3","4","5"]}]}')"
use_state base.json "$fresh | .config.limits.max_batch_items = 2"
assert_contains "oversized batch is rejected" "more than 2 items" "$(plan '{"batches":[{"theme":"A","items":["1","2","3","4","5"]}]}')"
assert_eq "a rejected plan changes nothing" "0" "$(sget '.batches | length')"
use_state base.json "$fresh | .run.flags.plan_only = true"
plan '{"batches":[{"theme":"A","items":["1","2","3","4","5"]}]}' >/dev/null
assert_eq "--plan-only halts after planning" "halted/plan-only" "$(sget '"\(.run.status)/\(.run.halt_reason)"')"
use_state base.json "$DEFS inprog(1; \"ci\")"
assert_contains "the plan cannot be replaced once batches are in flight" "already in flight" "$(plan '{"batches":[{"theme":"A","items":["1"]}]}')"

echo "state.sh: workers and attempts"
use_state base.json
branch="$(st record worker-started 1)"
assert_contains "worker-started names the branch" "backlog-loop/20260101-000000/b1-t1" "$branch"
assert_eq "batch and items are in progress" "in-progress/working/in-progress" "$(b1 '"\(.status)/\(.phase)"')/$(sget '.items[0].status')"
st record worker-done 1 >/dev/null
assert_eq "worker-done without a pushed branch counts as a failed attempt" "1/implement" "$(attempts 1)/$(b1 .phase)"
st record worker-started 1 >/dev/null
st record worker-failed 1 --reason "crashed" >/dev/null
st record worker-started 1 >/dev/null
st record worker-failed 1 --reason "crashed again" >/dev/null
assert_eq "three failed attempts queue the items for blocking" "3/block/blocking" "$(attempts 1)/$(sget '.items[0].pending')/$(b1 .phase)"

echo "state.sh: research"
use_state base.json
assert_contains "unclear needs a question" "usage" "$(st record unclear 4 2>&1)"
st record unclear 4 --question "ISO or locale?" >/dev/null
assert_eq "unclear queues research" "pending" "$(sget '.items[3].research')"
assert_contains "a decision needs its record" "write the decision record" "$(st record decision 4 --confidence low 2>&1)"
printf '# D\n\n## Question\nq\n\n## Options\no\n\n## Choice\nc\n' >"$STATE_DIR/decisions/4.md"
assert_contains "an incomplete record is rejected" 'no "Evidence" section' "$(st record decision 4 --confidence low 2>&1)"
printf '\n## Evidence\ne\n\n## Assumptions\na\n\n## Confidence\nlow\n' >>"$STATE_DIR/decisions/4.md"
assert_contains "confidence must be a known level" "must be high, medium or low" "$(st record decision 4 --confidence sure 2>&1)"
st record decision 4 --confidence low >/dev/null
assert_eq "low confidence sets needs-review" "done/true/decisions/4.md" "$(sget '.items[3] | "\(.research)/\(.needs_review)/\(.decision)"')"
assert_contains "research does not loop" "research budget" "$(st record unclear 4 --question "again" 2>&1)"

echo "state.sh: blocking"
use_state base.json
st record hard-blocker 5 --reason "needs credentials" >/dev/null
assert_eq "hard blocker queues the item" "block" "$(sget '.items[4].pending')"
assert_contains "mark-blocked needs a reason" "--why is required" "$("$S/mark-blocked.sh" 5 2>&1)"
"$S/mark-blocked.sh" 5 --tried "t" --why "no credentials" --needs "credentials" >/dev/null
assert_eq "blocked item leaves its batch" "blocked/null/4" "$(sget '.items[4] | "\(.status)/\(.batch)"')/$(sget '.batches[2].items | join(",")')"
assert_eq "the batch goes on with the rest" "todo" "$(sget '.batches[2].status')"
st record hard-blocker 4 --reason "x" >/dev/null
"$S/mark-blocked.sh" 4 --why "w" --needs "n" >/dev/null
assert_eq "a batch with nothing left is blocked" "blocked" "$(sget '.batches[2].status')"

echo "state.sh: CI results"
use_state base.json "$DEFS inprog(1; \"ci\")"
st record ci 1 poll
assert_eq "a poll is progress" "1" "$(b1 .ci_polls)"
st record ci 1 green
assert_eq "green CI -> merge" "merge" "$(b1 .phase)"
use_state base.json "$DEFS inprog(1; \"ci\") | .run.flags.no_merge = true"
st record ci 1 green
assert_eq "green CI with --no-merge -> pr-ready" "pr-ready/null" "$(b1 '"\(.status)/\(.phase)"')"
use_state base.json "$DEFS inprog(1; \"ci\")"
st record ci 1 red "ci"
assert_eq "first red -> rerun, no attempt counted" "ci-rerun/0" "$(b1 .phase)/$(attempts 1)"
st record ci-rerun 1
assert_eq "rerun goes back to waiting" "ci/1" "$(b1 '"\(.phase)/\(.ci_reruns)"')"
st record ci 1 red "ci"
assert_eq "red after the rerun is real: attempt counted, fix needed" "fix/1/1" "$(b1 .phase)/$(attempts 1)/$(attempts 2)"
assert_contains "ci-retry is refused for a red CI" "only for CI timeouts" "$(st record ci-retry 1 2>&1)"
assert_contains "fix-pushed needs a new commit" "no new commit" "$(st record fix-pushed 1 2>&1)"
use_state base.json "$DEFS inprog(1; \"ci\")"
st record ci 1 timeout
assert_eq "CI timeout counts as a failed attempt" "fix/1" "$(b1 .phase)/$(attempts 1)"
assert_contains "timeout is named in the error" "CI timeout" "$(b1 .last_error)"
st record ci-retry 1
assert_eq "ci-retry after a timeout waits again" "ci" "$(b1 .phase)"
st record ci 1 timeout
st record ci-retry 1
st record ci 1 timeout
assert_eq "three failed attempts end the batch" "blocking/block,block" "$(b1 .phase)/$(sget '[.items[] | select(.batch == 1) | .pending] | join(",")')"
use_state base.json "$DEFS inprog(1; \"ci\") | .batches[0].ci_reruns = 1 | .items[0].attempts = 2"
st record ci 1 red "ci"
assert_eq "an item out of attempts is dropped while the rest goes on" "drop/null/fix" "$(sget '.items[0].pending')/$(sget '.items[1].pending')/$(b1 .phase)"

echo "state.sh: poison"
use_state base.json "$DEFS inprog(1; \"fix\") | .batches[0].failures = 2 | .items[0].attempts = 2 | .items[1].attempts = 2"
st record poison 1 2 --reason "its test hangs" >/dev/null
assert_eq "the culprit is queued for dropping, the rest is refunded" "0/2/drop" "$(attempts 1)/$(attempts 2)/$(sget '.items[1].pending')"
assert_contains "poison checks batch membership" "not in batch" "$(st record poison 1 3 2>&1)"

echo "state.sh: conflicts and merging"
use_state base.json "$DEFS inprog(1; \"merge\")"
st record behind 1
assert_eq "behind base -> rebase" "rebase" "$(b1 .phase)"
st record conflict 1
assert_eq "first conflict -> one fix attempt" "conflict" "$(b1 .phase)"
st record conflict-failed 1 >/dev/null
assert_eq "failed conflict fix re-queues the batch last" "todo/2/4/null" "$(b1 '"\(.status)/\(.try)/\(.order)/\(.pr)"')"
assert_eq "re-queued items are todo again" "todo" "$(sget '.items[0].status')"
st record worker-started 1 >/dev/null
assert_contains "the retry uses a new branch" "b1-t2" "$(b1 .branch)"
use_state base.json "$DEFS inprog(1; \"conflict\") | .batches[0].requeues = 1"
st record conflict-failed 1 >/dev/null
assert_eq "a second re-queue blocks the items instead" "blocking/block" "$(b1 .phase)/$(sget '.items[0].pending')"
use_state base.json "$DEFS inprog(1; \"merge\")"
st record merge-failed 1 "refused"
st record merge-failed 1 "refused"
assert_eq "two refused merges keep trying" "merge" "$(b1 .phase)"
st record merge-failed 1 "refused"
assert_eq "three refused merges block the items" "blocking" "$(b1 .phase)"
use_state base.json "$DEFS inprog(1; \"merge\")"
st record premerge-ok 1 abc123
st record recheck 1
assert_eq "recheck drops the merge verification" "ci/null" "$(b1 '"\(.phase)/\(.premerge_sha)"')"

echo "state.sh: after the merge"
use_state base.json "$DEFS inprog(1; \"merge\")"
st record merged 1 deadbeef
assert_eq "merged -> post-merge" "post-merge/deadbeef" "$(b1 '"\(.phase)/\(.merge_commit)"')"
st record post-merge 1 pass
assert_eq "green base -> batch and items merged" "merged/merged,merged" "$(b1 .status)/$(sget '[.items[] | select(.batch == 1) | .status] | join(",")')"
use_state base.json "$DEFS inprog(1; \"post-merge\")"
st record post-merge 1 fail "test: exited 1"
assert_eq "red base -> revert" "revert" "$(b1 .phase)"
assert_contains "the failure is kept" "base branch red after merge" "$(b1 .last_error)"
st record revert-failed 1 --reason "gh pr revert failed" >/dev/null
assert_eq "a failed revert blocks the batch and halts the run" "blocked/halted" "$(b1 .status)/$(sget '.run.status')"
assert_contains "the halt reason is urgent" "URGENT" "$(sget '.run.halt_reason')"

echo "state.sh: lock and resume"
use_state base.json
( . "$S/lib.sh"; bl_paths; bl_lock_acquire one ) && ok "first session takes the lock" || not_ok "first session takes the lock"
( . "$S/lib.sh"; bl_paths; bl_lock_acquire one ) && ok "the same session may re-acquire" || not_ok "the same session may re-acquire"
( . "$S/lib.sh"; bl_paths; bl_lock_acquire two ) && not_ok "a second session is refused" || ok "a second session is refused"
touch -t 202001010000 "$STATE_DIR/lock"
( . "$S/lib.sh"; bl_paths; bl_lock_acquire two ) && ok "a stale lock is taken over" || not_ok "a stale lock is taken over"
assert_eq "the lock names its owner" "two" "$(sed -n 1p "$STATE_DIR/lock")"
use_state base.json "$DEFS inprog(1; \"working\") | .batches[0].pr = null | .run.status = \"halted\" | .run.halt_reason = \"iteration limit\" | .run.iterations = 100"
st resume --session three >/dev/null
assert_eq "resume restarts the run with a fresh budget" "running/0/null" "$(sget '"\(.run.status)/\(.run.iterations)/\(.run.halt_reason)"')"
assert_eq "a lost worker goes back to implement" "implement" "$(b1 .phase)"
assert_contains "a second session cannot resume a live run" "holds" "$(st resume --session four 2>&1)"
use_state base.json '.run.status = "done"'
assert_contains "a finished run is not resumed" "already finished" "$(st resume --session x 2>&1)"

echo "state.sh: BACKLOG.md parsing"
md="$T_TMP/BACKLOG.md"
cat >"$md" <<'EOM'
# Backlog

| ID | Title | Status | Notes |
|---|---|---|---|
| B-1 | Table item | ready | |
| B-2 | Finished | done | |
| B-3 | Stuck | blocked | BLOCKED: creds |

- [ ] B-4: Checkbox item
- [x] B-5: Checked item
- [ ] **B-6** Bold id
- [ ] no id here

## Archive

| ID | Title | Status | Notes |
|---|---|---|---|
| B-0 | Old | ready | |
EOM
list="$(awk -v mode=list -f "$S/backlog.awk" "$md" | tr '\t' '/' | tr '\n' ' ')"
assert_eq "open items of both layouts are listed, done and archived ones skipped" \
  "B-1/Table item/open B-3/Stuck/blocked B-4/Checkbox item/open B-6/Bold id/open item-4/no id here/open " "$list"
printf 'B-1\tdone\t\nB-4\tblocked\tno access\nB-6\tdone\t\n' >"$T_TMP/edits.tsv"
applied="$(awk -v mode=apply -v edits="$T_TMP/edits.tsv" -f "$S/backlog.awk" "$md")"
assert_contains "apply: table row marked done" "| B-1 | Table item | done |" "$applied"
assert_contains "apply: checkbox annotated as blocked" "- [ ] B-4: Checkbox item — BLOCKED: no access" "$applied"
assert_contains "apply: checkbox ticked" "- [x] **B-6** Bold id" "$applied"
assert_contains "apply: the archive is untouched" "| B-0 | Old | ready | |" "$applied"

echo "report.sh"
use_state base.json "$DEFS inprog(1; \"merge\") | inprog(2; \"merge\")
  | .run.status = \"done\"
  | .batches |= map(if .id < 3 then .status = \"merged\" | .phase = null else .status = \"blocked\" | .items = [\"4\"] end)
  | .batches[0].fixes = 1 | .batches[1].ci_reruns = 1
  | .items |= map(if .batch < 3 then .status = \"merged\" else . end)
  | .items[3] |= (.status = \"merged\" | .needs_review = true | .decision = \"decisions/4.md\")
  | .items[4] |= (.status = \"blocked\" | .batch = null | .blocked_reason = {tried: \"t\", why: \"needs production API credentials\", needs: \"credentials\"})"
report="$("$S/report.sh")"
assert_contains "report: headline" "Backlog loop finished: done" "$report"
assert_contains "report: items" "Items:   4 merged, 1 blocked, 0 remaining" "$report"
assert_contains "report: PRs" "PRs:     #201 #202 (2 PRs for 3 items)" "$report"
assert_contains "report: blocked item" 'Blocked: #5 "Sync with billing API"' "$report"
assert_contains "report: reason" "         Reason: needs production API credentials" "$report"
assert_contains "report: review" "Review:  #4 decided with low confidence, see decisions/4.md" "$report"
assert_contains "report: retries" "Retries: batch 1 (1 fix), batch 2 (1 CI rerun)" "$report"
assert_contains "report: path" "Report:  .planning/backlog-loop/report.md" "$report"
assert_eq "report.md is written" "yes" "$([ -s "$STATE_DIR/report.md" ] && echo yes)"

t_summary
