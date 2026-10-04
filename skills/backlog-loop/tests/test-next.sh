#!/usr/bin/env bash
# next.sh: every state maps to exactly one action, and no reachable state
# produces no action. Driven by fixture state files.
# shellcheck disable=SC2016
set -u
# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export BACKLOG_LOOP_DRY_RUN=1
export BACKLOG_LOOP_NOW=2000

KNOWN=" preflight plan implement_items integrate apply_item research fix_ci drop_item merge verify mark_blocked revert_batch halt done open_pr wait_ci rerun_ci rebase_batch resolve_conflict wait_worker sync_backlog "

# jq helpers to put the fixture in a given state.
DEFS='
def inprog($b; $phase): .batches |= map(if .id == $b then .status = "in-progress" | .phase = $phase
    | .branch = "backlog-loop/r/b\($b)-t1" | .pushed = true | .pr = (200 + $b) | .ci_started_at = 1900
    | .worker_started_at = 1900 else . end)
  | .items |= map(if .batch == $b then .status = "in-progress" else . end);
def merged($b): .batches |= map(if .id == $b then .status = "merged" | .phase = null | .pr = (200 + $b) else . end)
  | .items |= map(if .batch == $b then .status = "merged" else . end);
def item($i; f): .items |= map(if .id == $i then f else . end);
def batch($b; f): .batches |= map(if .id == $b then f else . end);
def batches($ids; f): .batches |= map(if (.id as $i | any($ids[]; . == $i)) then f else . end);
def items($ids; f): .items |= map(if (.id as $i | any($ids[]; . == $i)) then f else . end);
def started($b): .batches |= map(if .id == $b then .status = "in-progress" | .phase = "working" else . end)
  | .items |= map(if .batch == $b then .status = "in-progress" else . end);
# Batch 1 with ten items: 1, 2 and 6-13.
def big: .items[0] as $tpl | .items += [range(6; 14) | tostring as $i | $tpl + {id: $i, title: "Item \($i)"}]
  | .batches |= map(if .id == 1 then .items += [range(6; 14) | tostring] else . end);
'

# instr: the instruction lines of the last action, unescaped.
instr() { printf '%s' "$LAST" | jq -r '.instructions[]'; }

# expect <name> <jq filter> <expected action> [peek|run]
expect() {
  local name="$1" filter="$2" want="$3" mode="${4:-peek}" out count got
  use_state base.json "$DEFS $filter"
  if [ "$mode" = "peek" ]; then out="$("$S/next.sh" --peek 2>&1)"; else out="$("$S/next.sh" 2>&1)"; fi
  count="$(printf '%s' "$out" | jq -s 'length' 2>/dev/null)"
  got="$(printf '%s' "$out" | jq -r '.action' 2>/dev/null)"
  if [ "$count" != "1" ]; then
    not_ok "$name" "expected exactly one JSON action, got: $(printf '%s' "$out" | head -c 200)"
  elif [ "$got" != "$want" ]; then
    not_ok "$name" "expected '$want', got '$got'"
  else
    ok "$name"
  fi
  LAST="$out"
}

echo "next.sh: states without a usable run"
t_tmp
BACKLOG_LOOP_ROOT="$T_TMP/empty"
export BACKLOG_LOOP_ROOT
mkdir -p "$BACKLOG_LOOP_ROOT"
assert_eq "no state file -> preflight" "preflight" "$("$S/next.sh" | jq -r '.action')"
mkdir -p "$BACKLOG_LOOP_ROOT/.planning/backlog-loop"
echo '{"run": tru' >"$BACKLOG_LOOP_ROOT/.planning/backlog-loop/state.json"
assert_eq "corrupt state file -> halt" "halt" "$("$S/next.sh" | jq -r '.action')"

echo "next.sh: run status"
expect "status done -> done" '.run.status = "done"' "done"
expect "status halted -> halt" '.run.status = "halted" | .run.halt_reason = "iteration limit reached (100)"' halt
expect "status stalled -> halt" '.run.status = "stalled"' halt
expect "plan-only halt -> halt" '.run.status = "halted" | .run.halt_reason = "plan-only"' halt
assert_contains "plan-only halt points at plan.md" "plan.md" "$LAST"

echo "next.sh: limits"
expect "iteration limit -> halt" '.run.iterations = 100' halt run
assert_eq "iteration limit sets status halted" "halted" "$(sget '.run.status')"
expect "wall-clock limit -> halt" '.run.segment_started_at = (2000 - 12 * 3600)' halt run
assert_eq "wall-clock limit sets status halted" "halted" "$(sget '.run.status')"
expect "just under the wall-clock limit -> keeps going" '.run.segment_started_at = (2000 - 12 * 3600 + 1)' implement_items

echo "next.sh: planning and implementing items"
expect "no batches -> plan" '.batches = [] | .items |= map(.batch = null)' plan
expect "fresh plan -> implement_items" '.' implement_items
assert_eq "every item of the first batch starts" '["1","2"]' "$(printf '%s' "$LAST" | jq -c '.items')"
assert_eq "the action names the batch" "1" "$(printf '%s' "$LAST" | jq -r '.batch')"
expect "ten items, five slots -> five workers" 'big' implement_items
assert_eq "five items start" '["1","2","6","7","8"]' "$(printf '%s' "$LAST" | jq -c '.items')"
assert_contains "each item has its own spawn line" 'Item 8: Spawn one worker' "$(instr)"
assert_contains "each item has its own prompt" 'worker-prompt 1 --mode item --item 8' "$(instr)"
expect "three of five finished -> three more start" 'big | started(1) | items(["1","2","6","7","8"]; .phase = "working" | .worker_started_at = 1900)
  | items(["1","2","6"]; .phase = "done")' implement_items
assert_eq "the free slots are filled" '["9","10","11"]' "$(printf '%s' "$LAST" | jq -c '.items')"
expect "all slots busy -> wait_worker" 'big | started(1) | items(["1","2","6","7","8"]; .phase = "working" | .worker_started_at = 1900)' wait_worker
assert_eq "wait_worker lists the running items" '["1","2","6","7","8"]' "$(printf '%s' "$LAST" | jq -c '.items')"
expect "parallel-items of 1 -> one item at a time" '.config.limits.parallel_items = 1' implement_items
assert_eq "one item starts" '["1"]' "$(printf '%s' "$LAST" | jq -c '.items')"
expect "batch 1 not merged, slots free -> no batch 2 item starts" 'started(1) | items(["1","2"]; .phase = "working" | .worker_started_at = 1900)' wait_worker
expect "batch 1 in CI -> batch 2 waits" 'inprog(1; "ci")' wait_ci
expect "batch 1 merged -> batch 2 starts" 'merged(1)' implement_items
assert_eq "the next batch in order starts" '["3"]' "$(printf '%s' "$LAST" | jq -c '.items')"
expect "blocked batch -> the next one starts" 'batch(1; .status = "blocked" | .items = []) | items(["1","2"]; .status = "blocked" | .batch = null)' implement_items
expect "every item done -> integrate" 'started(1) | items(["1","2"]; .phase = "done")' integrate
assert_eq "integrate names the batch" "1" "$(printf '%s' "$LAST" | jq -r '.batch')"
assert_contains "integrate runs the script" "state.sh integrate 1" "$(instr)"
expect "conflicting item -> apply_item" 'inprog(1; "apply") | batch(1; .pr = null | .pushed = false) | item("1"; .phase = "applied") | item("2"; .phase = "conflict")' apply_item
assert_eq "apply_item names the item" "2" "$(printf '%s' "$LAST" | jq -r '.item')"
assert_contains "apply_item uses the apply prompt" "worker-prompt 1 --mode apply --item 2" "$(instr)"
expect "apply worker running -> wait_worker" 'inprog(1; "apply") | batch(1; .pr = null | .pushed = false) | item("1"; .phase = "applying" | .worker_started_at = 1900) | item("2"; .phase = "conflict")' wait_worker
expect "unclear item, another item ready -> start the ready item first" 'item("1"; .research = "pending" | .question = "which?")' implement_items
assert_eq "the item waiting on research is not started" '["2"]' "$(printf '%s' "$LAST" | jq -c '.items')"
expect "unclear item, nothing else to start -> research" 'item("1"; .research = "pending" | .question = "which?") | started(1) | item("2"; .phase = "working" | .worker_started_at = 1900) | .config.limits.parallel_items = 1' research
assert_eq "research names the item" "1" "$(printf '%s' "$LAST" | jq -r '.item')"
assert_contains "research runs on the light model" 'subagent_type "Explore", model "haiku"' "$(instr)"
expect "research uses a configured light model" 'item("1"; .research = "pending" | .question = "which?") | started(1) | item("2"; .phase = "working" | .worker_started_at = 1900) | .config.limits.parallel_items = 1 | .config.models = {light: "sonnet"}' research
assert_contains "research runs on the configured light model" 'model "sonnet"' "$(instr)"
expect "batch 1 waits for CI, batch 2 has an unclear item -> research" 'inprog(1; "ci") | item("3"; .research = "pending" | .question = "which?")' research
assert_eq "research looks ahead to the next batch" "3" "$(printf '%s' "$LAST" | jq -r '.item')"
expect "no-merge: batch 1 green -> halt waiting for the merge" '.run.flags.no_merge = true | batch(1; .status = "pr-ready" | .pr = 201) | items(["1","2"]; .status = "in-progress")' halt run
assert_contains "the halt asks for the merge" "wait for your merge" "$(printf '%s' "$LAST" | jq -r '.summary')"

echo "next.sh: models and agents"
expect "standard items -> sonnet workers" '.' implement_items
assert_eq "the action lists each item's tier and model" '[["1","standard","sonnet"],["2","standard","sonnet"]]' "$(printf '%s' "$LAST" | jq -c '[.detail[] | [.item, .tier, .model]]')"
assert_contains "the summary names the models" "item 1 on sonnet, item 2 on sonnet" "$(printf '%s' "$LAST" | jq -r '.summary')"
assert_contains "the spawn instruction names the model" 'Item 1: Spawn one worker: Agent tool, subagent_type "general-purpose", isolation "worktree", model "sonnet"' "$(instr)"
expect "item tier overrides the batch tier" 'batch(1; .tier = "complex") | item("1"; .tier = "light")' implement_items
assert_contains "the light item spawns haiku" 'Item 1: Spawn one worker: Agent tool, subagent_type "general-purpose", isolation "worktree", model "haiku"' "$(instr)"
assert_contains "the other item uses the batch tier" 'Item 2: Spawn one worker: Agent tool, subagent_type "general-purpose", isolation "worktree", model "opus"' "$(instr)"
expect "configured model -> that model" '.config.models = {standard: "opus"}' implement_items
assert_contains "the configured model is spawned" 'Item 1: Spawn one worker: Agent tool, subagent_type "general-purpose", isolation "worktree", model "opus"' "$(instr)"
expect "inherit -> no model is passed" '.config.models = {standard: "inherit"}' implement_items
assert_contains "an inherited model is spawned without a model" 'Item 1: Spawn one worker: Agent tool, subagent_type "general-purpose", isolation "worktree". Pass' "$(instr)"
assert_contains "the summary says the model is inherited" "item 1 on inherit" "$(printf '%s' "$LAST" | jq -r '.summary')"
expect "project agent for the tier -> that agent, no model" '.config.agents = {standard: "backlog-worker"}' implement_items
assert_contains "the agent is spawned without a model" 'Item 1: Spawn one worker: Agent tool, subagent_type "backlog-worker", isolation "worktree". Pass' "$(instr)"
assert_contains "the summary names the agent" "item 1 on agent backlog-worker" "$(printf '%s' "$LAST" | jq -r '.summary')"
expect "fix worker uses the highest item tier" 'merged(2) | inprog(1; "fix") | item("2"; .tier = "complex") | batch(1; .last_error = "CI red: ci")' fix_ci
assert_contains "fix_ci spawns the highest tier" 'model "opus"' "$(instr)"
expect "conflict worker uses the batch tier" 'merged(2) | inprog(1; "conflict") | batch(1; .tier = "light")' resolve_conflict
assert_contains "resolve_conflict spawns the batch model" 'model "haiku"' "$(instr)"
expect "drop worker uses the highest item tier" 'merged(2) | inprog(1; "fix") | batch(1; .tier = "complex") | item("1"; .pending = "drop")' drop_item
assert_contains "drop_item spawns the batch model" 'model "opus"' "$(instr)"
expect "apply worker uses the item tier" 'inprog(1; "apply") | batch(1; .pr = null | .pushed = false) | item("1"; .phase = "applied") | item("2"; .phase = "conflict" | .tier = "complex")' apply_item
assert_contains "apply_item spawns the item model" 'model "opus"' "$(instr)"
expect "squashed commits -> fix_ci never offers poison" '.config.batch_commits = "squashed" | merged(2) | inprog(1; "fix") | batch(1; .last_error = "CI red: ci")' fix_ci
case "$(instr)" in *"record poison"*) not_ok "squashed fix_ci has no poison step" ;; *) ok "squashed fix_ci has no poison step" ;; esac

echo "next.sh: one action per batch phase"
expect "phase open-pr -> open_pr" 'merged(2) | inprog(1; "open-pr") | batch(1; .pr = null)' open_pr
expect "phase ci -> wait_ci" 'merged(2) | inprog(1; "ci")' wait_ci
expect "phase ci-rerun -> rerun_ci" 'merged(2) | inprog(1; "ci-rerun")' rerun_ci
expect "phase fix -> fix_ci" 'merged(2) | inprog(1; "fix") | batch(1; .last_error = "CI red: ci")' fix_ci
expect "phase fix after timeout -> fix_ci" 'merged(2) | inprog(1; "fix") | batch(1; .last_error = "CI timeout: checks did not finish")' fix_ci
assert_contains "timeout variant offers ci-retry" "ci-retry" "$LAST"
expect "phase merge -> merge" 'merged(2) | inprog(1; "merge")' merge
expect "phase rebase -> rebase_batch" 'merged(2) | inprog(1; "rebase")' rebase_batch
expect "phase conflict -> resolve_conflict" 'merged(2) | inprog(1; "conflict")' resolve_conflict
expect "phase post-merge -> verify" 'merged(2) | inprog(1; "post-merge")' verify
expect "phase revert -> revert_batch" 'merged(2) | inprog(1; "revert")' revert_batch
expect "item to drop -> drop_item" 'merged(2) | inprog(1; "fix") | item("1"; .pending = "drop")' drop_item
expect "item to block -> mark_blocked" 'item("5"; .pending = "block" | .last_error = "hard blocker: creds")' mark_blocked
assert_eq "mark_blocked names the item" "5" "$(printf '%s' "$LAST" | jq -r '.item')"

echo "next.sh: priorities"
expect "merge beats starting new work" 'inprog(1; "merge")' merge
expect "mark_blocked beats everything" 'inprog(1; "revert") | item("5"; .pending = "block")' mark_blocked
expect "revert beats merge" 'inprog(1; "merge") | inprog(2; "revert")' revert_batch
expect "verify beats merge (merges are sequential)" 'inprog(1; "post-merge") | inprog(2; "merge")' verify
expect "batches run one at a time: CI on batch 1 holds batch 2 back" 'inprog(1; "ci")' wait_ci
expect "merges go in batch order" 'inprog(1; "merge") | inprog(2; "merge")' merge
assert_eq "lowest order merges first" "1" "$(printf '%s' "$LAST" | jq -r '.batch')"

echo "next.sh: end of run"
expect "everything merged -> done" 'merged(1) | merged(2) | merged(3)' "done" run
assert_eq "done sets the run status" "done" "$(sget '.run.status')"
expect "merged and blocked -> done" 'merged(1) | merged(2) | batch(3; .status = "blocked" | .items = []) | items(["4", "5"]; .status = "blocked" | .batch = null)' "done"
expect "file source with results -> sync_backlog" '.config.source = "file" | merged(1) | merged(2) | merged(3)' sync_backlog
expect "file source after the sync -> done" '.config.source = "file" | .run.sync = "skipped" | merged(1) | merged(2) | merged(3)' "done"
expect "no-merge: green PRs only -> done" '.run.flags.no_merge = true | batches([1, 2, 3]; .status = "pr-ready" | .pr = 201) | .batches |= map(.depends_on = [])' "done"
expect "no-merge: dependents wait for a human merge -> halt" '.run.flags.no_merge = true | batches([1, 2]; .status = "pr-ready" | .pr = 201)' halt run
assert_eq "waiting on a human merge halts the run" "halted" "$(sget '.run.status')"

echo "next.sh: housekeeping"
expect "needed item blocked -> dependent item is blocked" 'merged(2) | batch(1; .status = "blocked" | .items = []) | items(["1", "2"]; .status = "blocked" | .batch = null) | item("4"; .needs = ["1"])' mark_blocked run
assert_eq "the dependent item is queued for blocking" "block" "$(sget '.items[] | select(.id == "4") | .pending')"
assert_contains "the reason names the needed item" "needs item 1, which is blocked" "$(sget '.items[] | select(.id == "4") | .last_error')"
expect "needed item not merged -> dependent item moves on, no attempt" 'merged(1) | item("3"; .needs = ["4"])' implement_items run
assert_eq "the dependent item moved to the next batch" "3/0" "$(sget '.items[] | select(.id == "3") | "\(.batch)/\(.attempts)"')"
assert_eq "its old batch is closed" "closed" "$(sget '.batches[] | select(.id == 2) | .status')"
expect "item worker past its deadline -> attempt counted, item moves on" 'started(1) | items(["1", "2"]; .phase = "working" | .worker_started_at = 1900) | item("1"; .worker_started_at = (2000 - 121 * 60))' wait_worker run
assert_eq "the deadline counts as an attempt and moves the item" "2/1" "$(sget '.items[] | select(.id == "1") | "\(.batch)/\(.attempts)"')"
expect "wait_ci does not use up iterations" 'merged(2) | merged(3) | inprog(1; "ci")' wait_ci run
assert_eq "iteration counter unchanged by waiting" "0" "$(sget '.run.total_iterations')"
expect "other actions count as iterations" '.' implement_items run
assert_eq "iteration counter incremented" "1" "$(sget '.run.total_iterations')"
expect "--peek changes nothing" '.' implement_items peek
assert_eq "peek leaves the counter alone" "0" "$(sget '.run.total_iterations')"

echo "next.sh: exhaustive sweep, every state yields exactly one known action"
sweep_fail=0
sweep_count=0
check_one() {
  # check_one <label> <next.sh output>
  local action n instr
  sweep_count=$((sweep_count + 1))
  action="$(printf '%s' "$2" | jq -r '.action' 2>/dev/null)"
  n="$(printf '%s' "$2" | jq -s 'length' 2>/dev/null)"
  instr="$(printf '%s' "$2" | jq -r '.instructions | length' 2>/dev/null)"
  case "$KNOWN" in
    *" $action "*)
      if [ "$n" != "1" ] || [ "${instr:-0}" -lt 1 ]; then
        sweep_fail=$((sweep_fail + 1))
        printf '    bad output for %s: %s\n' "$1" "$(printf '%s' "$2" | head -c 200)"
      fi
      ;;
    *)
      sweep_fail=$((sweep_fail + 1))
      printf '    no known action for %s: %s\n' "$1" "$(printf '%s' "$2" | head -c 200)"
      ;;
  esac
}
for status_phase in "todo:null" "in-progress:apply" "in-progress:working" "in-progress:open-pr" "in-progress:ci" \
  "in-progress:ci-rerun" "in-progress:fix" "in-progress:merge" "in-progress:rebase" "in-progress:conflict" \
  "in-progress:post-merge" "in-progress:revert" "in-progress:blocking" "merged:null" "blocked:null" "closed:null" "pr-ready:null"; do
  st="${status_phase%%:*}"
  ph="${status_phase##*:}"
  [ "$ph" = "null" ] || ph="\"$ph\""
  for other in todo merged blocked; do
    for pending in null '"block"' '"drop"'; do
      for research in '"none"' '"pending"'; do
        use_state base.json "$DEFS
          batch(1; .status = \"$st\" | .phase = $ph | .pr = 201 | .branch = \"b\" | .worker_started_at = 1900 | .ci_started_at = 1900)
          | batches([2, 3]; .status = \"$other\")
          | item(\"1\"; .pending = $pending | .research = $research
              | .status = (if \"$st\" == \"merged\" then \"merged\" elif \"$st\" == \"blocked\" then \"blocked\" else \"in-progress\" end))"
        check_one "$status_phase/$other/$pending/$research (peek)" "$("$S/next.sh" --peek 2>&1)"
        # The mutating path is slower, so it runs on a slice of the grid.
        if [ "$other" = "todo" ] && [ "$research" = '"none"' ]; then
          check_one "$status_phase/$other/$pending/$research (run)" "$("$S/next.sh" 2>&1)"
        fi
      done
    done
  done
done
assert_eq "$sweep_count state/mode combinations each give one known action with instructions" "0" "$sweep_fail"

t_summary
