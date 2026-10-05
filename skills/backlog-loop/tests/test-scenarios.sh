#!/usr/bin/env bash
# The approved scenarios of backlog-loop, run against a real git repository
# with a bare origin and a stub gh. One section per scenario.
# shellcheck disable=SC2016
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

item() { printf '{"id":"%s","title":"Item %s"}' "$1" "$1"; }
# batch <name> <needs json> <item>...
batch() {
  local name="$1" needs="$2" items=""
  shift 2
  while [ $# -gt 0 ]; do
    items="$items${items:+,}$(item "$1")"
    shift
  done
  printf '{"name":"%s","theme":"Theme %s","title":"feat: batch %s","needs":%s,"items":[%s]}' "$name" "$name" "$name" "$needs" "$items"
}
# plan_of <source> <batch json>...
plan_of() {
  local source="$1" batches=""
  shift
  while [ $# -gt 0 ]; do
    batches="$batches${batches:+,}$1"
    shift
  done
  printf '{"source":"%s","backlog":"BACKLOG.md","batches":[%s]}' "$source" "$batches"
}
batch_field() { sget --arg b "$1" ".batches[] | select(.name == \$b) | $2"; }
on_main() { git fetch -q origin main && git cat-file -e "origin/main:$1" 2>/dev/null; }

echo "1. /backlog-loop D runs only batch D"
new_repo
planned "$(plan_of github "$(batch A '[]' 1)" "$(batch B '[]' 2)" "$(batch C '[]' 3)" "$(batch D '[]' 4 5)")"
assert_eq "a plan-only run ends after planning" "done" "$(sget .run.status)"
"$L" start --session s1 execute D >/dev/null
drive
assert_eq "run finishes" "done" "$ACT"
assert_eq "D is merged" "merged" "$(batch_field D .status)"
assert_eq "A, B and C are untouched" "todo todo todo" "$(sget '[.batches[] | select(.name != "D") | .status] | join(" ")')"
if on_main item-4.txt && on_main item-5.txt; then ok "D's items are on the base branch"; else not_ok "D's items are on the base branch"; fi
if on_main item-1.txt; then not_ok "A's item is not built"; else ok "A's item is not built"; fi
report="$("$L" report)"
assert_contains "report lists what was implemented" "Batch D" "$report"
assert_contains "report lists remaining batches" "Batch A" "${report#*Remaining}"

echo "2. plan creates the batches, execute runs them"
new_repo
out="$("$L" start --session s1)"
assert_contains "without a command nothing starts and the usage is shown" "Nothing was started. Usage: /backlog-loop plan | execute" "$out"
out="$("$L" start --session s1 execute 2>&1)"
assert_contains "execute without a plan is refused" "Run /backlog-loop plan" "$out"
out="$("$L" start --session s1 D 2>&1)"
assert_contains "a bare batch name points to execute" "/backlog-loop execute D" "$out"
"$L" start --session s1 plan >/dev/null
next
assert_eq "plan asks for a plan" "plan" "$ACT"
out="$(plan '{"source":"github","batches":[{"name":"A","theme":"x","items":[{"id":"1","title":"t"}]},{"name":"A","theme":"y","items":[{"id":"2","title":"t"}]}]}' 2>&1)"
assert_contains "a duplicate batch name is rejected" "more than once" "$out"
out="$(plan '{"source":"github","batches":[{"name":"B","theme":"x","needs":["Z"],"items":[{"id":"1","title":"t"}]}]}' 2>&1)"
assert_contains "an unknown needed batch is rejected" "needs" "$out"
out="$(plan '{"source":"github","batches":[{"name":"B","theme":"x","items":[{"id":"1","title":"t"}]},{"name":"C","theme":"x","items":[{"id":"1","title":"t"}]}]}' 2>&1)"
assert_contains "an item in two batches is rejected" "more than one batch" "$out"
plan "$(plan_of github "$(batch A '[]' 1)")" >/dev/null
assert_eq "batch names are stored" "A" "$(sget '.batches[0].name')"
next
assert_eq "planning ends without starting work" "done todo" "$ACT $(sget '.batches[0].status')"
"$L" start --session s1 execute >/dev/null
out="$("$L" start --session s1 plan 2>&1)"
assert_contains "planning is refused while a run is in progress" "a run is in progress" "$out"
next
assert_eq "execute starts the work" "implement" "$ACT"

new_repo
assert_contains "before any plan the report says so" "no plan yet" "$("$L" status)"
"$L" start --session s1 plan >/dev/null
out="$(plan '{"source":"github","batches":[]}')"
assert_contains "an empty plan is reported as nothing to do" "nothing to do" "$out"
assert_lacks "and not as a missing plan" "no plan yet" "$out"
next
assert_eq "the run ends" "done" "$ACT"

echo "3. Independent batches run in the same wave"
new_repo
execute "$(plan_of github "$(batch B '[]' 1 2)" "$(batch C '[]' 3)")"
next
assert_eq "one implement action covers both batches" "B B C" "$(printf '%s' "$ACTION" | jq -r '[.items[].batch] | join(" ")')"
"$L" record started 1 2 3 >/dev/null
for i in 1 2 3; do work "$i"; "$L" record item "$i" >/dev/null; done
drive
assert_eq "run finishes" "done" "$ACT"
assert_eq "each batch has its own pull request" "2" "$(sget '[.batches[].pr] | unique | length')"
assert_eq "both are merged" "merged merged" "$(sget '[.batches[].status] | join(" ")')"
assert_eq "both ran in wave 1" "1 1" "$(sget '[.batches[].wave] | join(" ")')"

echo "4. A batch waits for the batches it needs"
new_repo
execute "$(plan_of github "$(batch B '[]' 1)" "$(batch D '["B"]' 2)")"
next
assert_eq "wave 1 holds only B" "1" "$(printf '%s' "$ACTION" | jq -r '[.items[].id] | join(" ")')"
drive
assert_eq "D ran in a later wave" "2" "$(batch_field D .wave)"
assert_eq "D is merged after B" "merged" "$(batch_field D .status)"

new_repo
execute "$(plan_of github "$(batch B '[]' 1)" "$(batch D '["B"]' 2)")"
next
"$L" record started 1 >/dev/null
"$L" record item 1 --blocker "needs production credentials" >/dev/null
drive
assert_eq "run finishes when B is set aside" "done" "$ACT"
assert_eq "B is set aside" "aside" "$(batch_field B .status)"
assert_eq "D is not built" "todo" "$(batch_field D .status)"
report="$("$L" report)"
assert_contains "D is reported as remaining" "Batch D" "${report#*Remaining}"
assert_contains "the report says what D waits for" "needs B" "$report"
out="$("$L" start --session s1 execute D 2>&1)"
assert_contains "starting D alone is refused while B is not merged" "needs B" "$out"

echo "5. One pull request per batch, one commit per item"
new_repo
execute "$(plan_of github "$(batch A '[]' 1 2 3)")" --no-merge
drive
assert_eq "run finishes" "done" "$ACT"
assert_eq "the batch waits for the user's merge" "ready" "$(batch_field A .status)"
assert_eq "one pull request" "1" "$(jq '.prs | length' "$GH_STUB_DB")"
git fetch -q origin
assert_eq "three commits on its branch" "3" "$(git rev-list --count "origin/main..origin/$(batch_field A .branch)")"
assert_contains "the body closes the issues" "Closes #2" "$(jq -r '.prs[0].body' "$GH_STUB_DB")"
assert_lacks "nothing is merged with --no-merge" "merge " "$(ghlog)"

echo "6. A worker's claim is checked against its branch"
new_repo
execute "$(plan_of github "$(batch A '[]' 1 2)")"
next
"$L" record started 1 2 >/dev/null
out="$("$L" record item 1 2>&1)"
assert_contains "a missing commit is reported" "no commit" "$out"
assert_eq "the item is retried" "todo 1" "$(sget '.items["1"] | "\(.status) \(.attempts)"')"
next
assert_eq "the retry is handed out" "1" "$(printf '%s' "$ACTION" | jq -r '[.items[].id] | join(" ")')"
"$L" record started 1 >/dev/null
"$L" record item 1 >/dev/null 2>&1
assert_eq "after the second failure it is set aside" "aside" "$(sget '.items["1"].status')"
work 2
"$L" record item 2 >/dev/null
drive
assert_eq "the rest of the batch still merges" "merged" "$(batch_field A .status)"
assert_eq "the set-aside item stays aside" "aside" "$(sget '.items["1"].status')"

echo "7. Unclear items are researched; low confidence sets them aside"
decision() {
  mkdir -p .planning/backlog-loop/decisions
  printf '# Decision for %s\n\n## Question\n\nq\n\n## Options\n\n1. a\n\n## Choice\n\nUse a.\n\n## Evidence\n\n- x\n\n## Confidence\n\n%s\n' "$1" "$2" \
    >".planning/backlog-loop/decisions/$1.md"
}
new_repo
execute '{"source":"github","batches":[{"name":"A","theme":"x","items":[
  {"id":"1","title":"Clear"},{"id":"2","title":"Unclear","question":"One line or two?"},{"id":"3","title":"Murky","question":"Which provider?"}]}]}'
next
assert_eq "research comes first" "research" "$ACT"
assert_eq "for the unclear items" "2 3" "$(printf '%s' "$ACTION" | jq -r '[.items[].id] | join(" ")')"
"$L" record started 2 3 >/dev/null
out="$("$L" record decision 2 --confidence high 2>&1)"
assert_contains "a decision needs its record" "decisions/2.md" "$out"
decision 2 high
"$L" record decision 2 --confidence high >/dev/null
decision 3 low
"$L" record decision 3 --confidence low --needs "the owner's choice of provider" >/dev/null
assert_eq "low confidence sets the item aside" "aside" "$(sget '.items["3"].status')"
next
assert_eq "the decided item is implemented, the set-aside one never" "1 2" "$(printf '%s' "$ACTION" | jq -r '[.items[].id] | join(" ")')"
assert_contains "the worker prompt carries the decision" "Use a." "$("$L" record started 1 2 >/dev/null; "$L" prompt item 2)"
work 1
"$L" record item 1 >/dev/null
"$L" record item 2 --unclear "Still: one line or two?" >/dev/null
assert_eq "unclear again after research sets it aside" "aside" "$(sget '.items["2"].status')"
drive
assert_contains "the report says what a set-aside item needs" "the owner's choice of provider" "$("$L" report)"

echo "8. Red CI: rerun once, then fix, then set the batch aside"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)")"
next
"$L" record started 1 >/dev/null
work 1 item-1.txt .ci-flaky
"$L" record item 1 >/dev/null
drive
assert_eq "a flaky failure merges after one rerun" "merged" "$(batch_field A .status)"
assert_contains "the failed run was rerun" "rerun" "$(ghlog)"

new_repo
execute "$(plan_of github "$(batch A '[]' 1)")"
next
"$L" record started 1 >/dev/null
work 1 item-1.txt .ci-fail
"$L" record item 1 >/dev/null
drive
assert_eq "a real failure asks for a fix" "fix" "$ACT"
assert_lacks "a red pull request is never merged" "merge " "$(ghlog)"
"$L" record started --batch A >/dev/null
out="$("$L" record fixed A 2>&1)"
assert_contains "a fix without a new commit is refused" "no new commit" "$out"
push_on A "fix: try to make it pass" extra.txt
"$L" record fixed A >/dev/null
drive
assert_eq "still red: a second fix is asked for" "fix" "$ACT"
"$L" record started --batch A >/dev/null
"$L" record fixed A --failed "cannot find the cause" >/dev/null
drive
assert_eq "run finishes" "done" "$ACT"
assert_eq "after two failed fixes the batch is set aside" "aside" "$(batch_field A .status)"
assert_eq "its pull request stays open" "OPEN" "$(jq -r '.prs[0].state' "$GH_STUB_DB")"
assert_contains "the report names the open pull request" "#1" "$("$L" report)"

new_repo
execute "$(plan_of github "$(batch A '[]' 1 2)")"
next
"$L" record started 1 2 >/dev/null
work 1
work 2 item-2.txt .ci-fail
"$L" record item 1 >/dev/null
"$L" record item 2 >/dev/null
drive
assert_eq "a red batch of two asks for a fix" "fix" "$ACT"
assert_contains "the fix prompt lists the batch's items" "- 2: Item 2" "$("$L" prompt fix A)"
"$L" record started --batch A >/dev/null
push_on A "revert: drop item 2

Backlog-Drop: 2" -.ci-fail -item-2.txt
"$L" record fixed A >/dev/null
assert_eq "an item reverted by the fix is set aside" "aside" "$(sget '.items["2"].status')"
body="$(jq -r '.prs[0].body' "$GH_STUB_DB")"
assert_lacks "the pull request no longer closes the dropped item" "#2" "$body"
assert_contains "it still closes the other" "Closes #1" "$body"
drive
assert_eq "the rest of the batch merges" "merged merged" "$(batch_field A .status) $(sget '.items["1"].status')"
if on_main item-2.txt; then not_ok "the dropped item is not on the base branch"; else ok "the dropped item is not on the base branch"; fi

echo "9. Later batches of a wave are updated from base before they merge"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)" "$(batch B '[]' 2)")"
drive
assert_eq "both merge" "merged merged" "$(sget '[.batches[].status] | join(" ")')"
log="$(ghlog)"
assert_contains "the second pull request is updated from base" "update-branch 2" "$log"
assert_contains "it merges after green checks" "merge 2 squash pass" "$log"
case "$log" in
  *"merge 1"*"update-branch 2"*"merge 2"*) ok "update happens between the two merges" ;;
  *) not_ok "update happens between the two merges" "$log" ;;
esac

new_repo
execute "$(plan_of github "$(batch A '[]' 1)" "$(batch B '[]' 2)")"
next
"$L" record started 1 2 >/dev/null
work 1 shared.txt=from-one
work 2 shared.txt=from-two
"$L" record item 1 >/dev/null
"$L" record item 2 >/dev/null
drive
assert_eq "batches that clash ask for a conflict resolution" "conflict" "$ACT"
assert_eq "for the second batch" "B" "$(printf '%s' "$ACTION" | jq -r '.batch')"
"$L" record started --batch B >/dev/null
"$L" record fixed B --failed "cannot keep both" >/dev/null
drive
assert_eq "an unresolved conflict sets the batch aside" "aside" "$(batch_field B .status)"

echo "10. Items of one batch that conflict are applied by hand"
new_repo
execute "$(plan_of github "$(batch A '[]' 1 2)")"
next
"$L" record started 1 2 >/dev/null
work 1 shared.txt=from-one
work 2 shared.txt=from-two
"$L" record item 1 >/dev/null
"$L" record item 2 >/dev/null
next
assert_eq "the conflicting item gets an apply worker" "apply 2" "$ACT $(printf '%s' "$ACTION" | jq -r '.item')"
"$L" record started --batch A >/dev/null
"$L" record applied 2 --failed "both rewrite the same line" >/dev/null
assert_eq "a failed apply leaves the item for a later batch" "todo null" "$(sget '.items["2"] | "\(.status) \(.batch)"')"
drive
assert_eq "the batch merges without it" "merged" "$(batch_field A .status)"
assert_contains "the item is reported as remaining" "2: Item 2" "$(r="$("$L" report)"; printf '%s' "${r#*Remaining}")"

echo "11. An interrupted run continues; merged work is not redone"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)" "$(batch B '["A"]' 2 3)")"
drive_until_b() {
  local i=0
  while [ "$i" -lt 30 ]; do
    i=$((i + 1))
    next
    if [ "$ACT" = "implement" ] && [ "$(printf '%s' "$ACTION" | jq -r '.items[0].batch')" = "B" ]; then return 0; fi
    [ "$ACT" = "implement" ] || continue
    "$L" record started 1 >/dev/null
    work 1
    "$L" record item 1 >/dev/null
  done
}
drive_until_b
"$L" record started 2 3 >/dev/null
work 2
out="$("$L" start --session s2 execute 2>&1)"
assert_contains "a live run of another session is not taken over" "another session" "$out"
out="$(BACKLOG_LOOP_LOCK_STALE_SECONDS=0 "$L" start --session s2 execute 2>&1)"
assert_contains "the run is resumed" "Resuming" "$out"
assert_eq "a finished worker's commit is kept" "built" "$(sget '.items["2"].status')"
assert_eq "a lost worker's item is handed out again" "todo 0" "$(sget '.items["3"] | "\(.status) \(.attempts)"')"
before="$(jq '.prs | length' "$GH_STUB_DB")"
drive
assert_eq "run finishes" "done" "$ACT"
assert_eq "A was not built again" "$((before + 1))" "$(jq '.prs | length' "$GH_STUB_DB")"
assert_eq "everything is merged" "merged merged" "$(sget '[.batches[].status] | join(" ")')"

echo "12. The report: implemented, set aside, remaining"
new_repo
planned '{"source":"github","batches":[
  {"name":"A","theme":"Forms","title":"feat(forms): validate","items":[{"id":"1","title":"Validate zip"},{"id":"2","title":"Needs keys"}]},
  {"name":"B","theme":"Checkout","items":[{"id":"3","title":"Show total"}]}]}'
"$L" start --session s1 execute A >/dev/null
next
"$L" record started 1 2 >/dev/null
work 1
"$L" record item 1 >/dev/null
"$L" record item 2 --blocker "the payment sandbox keys" >/dev/null
drive
report="$("$L" report)"
assert_contains "status line" "Backlog loop: done" "$report"
assert_contains "implemented batch with its pull request" "Batch A \"Forms\": PR #1, merged" "$report"
assert_contains "implemented item" "1: Validate zip" "$report"
assert_contains "set-aside item with what it needs" "Needs: the payment sandbox keys" "$report"
assert_contains "remaining batch with its items" "3: Show total" "${report#*Remaining}"
assert_contains "the blocker is posted on the issue" "comment issue 2" "$(ghlog)"
assert_contains "status prints the same without a run" "Batch B" "$("$L" status)"

echo "13. File backlogs are marked in the batch's pull request"
new_repo
execute "$(plan_of file "$(batch A '[]' 1)")"
next
"$L" record started 1 >/dev/null
work 1
"$L" record item 1 >/dev/null
next
assert_eq "a worker marks the backlog" "mark_backlog" "$ACT"
"$L" record started --batch A >/dev/null
out="$("$L" record marked A 2>&1)"
assert_contains "the mark is checked on the branch" "Backlog-Status" "$out"
push_on A "docs: mark batch A done

Backlog-Status: A" "BACKLOG.md=marked A" other.txt
out="$("$L" record marked A 2>&1)"
assert_contains "the mark may change only the backlog file" "must change only BACKLOG.md" "$out"
next
assert_eq "while the worker runs, the loop waits" "wait" "$ACT"
"$L" record marked A --failed "worker touched other files" >/dev/null
assert_eq "a failed mark does not hold the batch back" "pr" "$(batch_field A .phase)"
drive
assert_eq "the batch merges without the mark" "merged" "$(batch_field A .status)"
assert_contains "the report notes the missing mark" "backlog file was not updated" "$("$L" report)"

new_repo
execute "$(plan_of file "$(batch A '[]' 1)")"
drive
assert_eq "the batch merges" "merged" "$(batch_field A .status)"
git fetch -q origin main
assert_eq "the backlog change landed with the code" "marked A" "$(git show origin/main:BACKLOG.md)"
assert_lacks "file items do not close issues" "Closes" "$(jq -r '.prs[0].body' "$GH_STUB_DB")"

echo "14. A red base branch after a merge halts the run with a revert PR"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)" "$(batch B '["A"]' 2)")"
next
"$L" record started 1 >/dev/null
work 1 item-1.txt .ci-fail-base
"$L" record item 1 >/dev/null
drive
assert_eq "the run halts" "halt" "$ACT"
assert_contains "a revert pull request is opened" "revert 1" "$(ghlog)"
assert_eq "the revert is left for the user" "OPEN" "$(jq -r '.prs[1].state' "$GH_STUB_DB")"
assert_eq "the next batch is not started" "todo" "$(batch_field B .status)"
assert_contains "the report is urgent about it" "red" "$("$L" report)"

echo "15. Pull requests without checks"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)")"
next
"$L" record started 1 >/dev/null
work 1 item-1.txt .ci-none
"$L" record item 1 >/dev/null
BACKLOG_LOOP_CI_GRACE_SECONDS=0 drive
assert_eq "no checks halts the run by default" "halt" "$ACT"
assert_lacks "nothing is merged unchecked" "merge " "$(ghlog)"

new_repo "ci: optional"
execute "$(plan_of github "$(batch A '[]' 1)")"
next
"$L" record started 1 >/dev/null
work 1 item-1.txt .ci-none
"$L" record item 1 >/dev/null
BACKLOG_LOOP_CI_GRACE_SECONDS=0 drive
assert_eq "with ci: optional it merges" "merged" "$(batch_field A .status)"

echo "16. --no-merge: the next wave starts after the user merged"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)" "$(batch B '["A"]' 2)")" --no-merge
drive
assert_eq "the run ends with A waiting and B not started" "ready todo" "$(sget '[.batches[].status] | join(" ")')"
assert_contains "the report says whose turn it is" "waiting for your merge" "$("$L" report)"
gh pr merge 1 --squash
"$L" start --session s1 --no-merge execute >/dev/null
assert_eq "the user's merge is picked up" "merged" "$(batch_field A .status)"
drive
assert_eq "B follows" "ready" "$(batch_field B .status)"

echo "17. Workers that never report"
new_repo
execute "$(plan_of github "$(batch A '[]' 1)")"
next
"$L" record started 1 >/dev/null
jq '.items["1"].since = 0' "$STATE" >"$STATE.t" && mv "$STATE.t" "$STATE"
next
assert_eq "a silent worker costs an attempt and the item is handed out again" "implement 1" "$ACT $(sget '.items["1"].attempts')"
jq '.run.started = 0' "$STATE" >"$STATE.t" && mv "$STATE.t" "$STATE"
next
assert_eq "the run halts at its time limit" "halt" "$ACT"
assert_contains "and says how to continue" "/backlog-loop" "$(sget .run.reason)"

echo "18. Limits and configuration"
new_repo "parallel-batches: 1" "parallel-workers: 2" "merge-method: \`merge\`"
execute "$(plan_of github "$(batch A '[]' 1 2 3)" "$(batch B '[]' 4)")"
assert_eq "config is read from the Backlog loop section only" "merge github" "$(sget '"\(.config.merge_method) \(.config.source)"')"
next
assert_eq "at most parallel-workers items at once, one batch per wave" "1 2" "$(printf '%s' "$ACTION" | jq -r '[.items[].id] | join(" ")')"
"$L" record started 1 2 >/dev/null
next
assert_eq "then the loop waits for workers" "wait true" "$ACT $(printf '%s' "$ACTION" | jq -r '.workers > 0')"
assert_contains "items carry a model" "sonnet" "$(sget '.config.models.standard')"

t_summary
