#!/usr/bin/env bash
# next.sh: print the single next action of the loop as one JSON object.
#
# Every reachable state maps to exactly one action. The action carries the ids
# and the concrete commands, so the loop survives context compaction.
#
#   next.sh            decide, count the iteration, print the action
#   next.sh --peek     decide and print without counting or changing state
# shellcheck disable=SC2016
set -u
BL_SELF=next
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PEEK=0
[ "${1:-}" = "--peek" ] && PEEK=1

S="$BL_SCRIPT_DIR"

emit() {
  # emit <action> <summary> [jq args...] -- instruction lines on stdin
  local action="$1" summary="$2"
  shift 2
  jq -n -R --arg action "$action" --arg summary "$summary" \
    --arg run "${RUN_ID:-}" --argjson iteration "${ITERATION:-0}" "$@" '
    { action: $action, run: $run, iteration: $iteration, summary: $summary }
    + ($ARGS.named | del(.action, .summary, .run, .iteration))
    + { instructions: [inputs | select(length > 0)],
        then: (if $action == "done" or $action == "halt" then "Stop. Show the report to the user."
               else "Run next.sh again and do what it returns." end) }'
}

if ! bl_paths; then
  emit halt "Not inside a git repository." <<EOT
cd into the target repository and run /backlog-loop again.
EOT
  exit 0
fi

if [ ! -e "$BL_STATE" ]; then
  emit preflight "No run exists yet in this repository." <<EOT
Run: $S/preflight.sh --probes   and run each printed probe command as its own Bash call.
Run: $S/preflight.sh <the arguments the skill was invoked with>
If preflight fails, show its output to the user and stop. Preflight creates the run on success.
EOT
  exit 0
fi

if ! bl_state_ok; then
  emit halt "The state file is unreadable: $BL_STATE" <<EOT
Do not edit state.json by hand. Show this to the user: restore $BL_STATE from $BL_DIR/archive or delete the directory $BL_DIR to start over.
EOT
  exit 0
fi

st() { "$S/state.sh" "$@"; }
get() { jq -r "$@" "$BL_STATE"; }
bq() { jq -r --argjson b "$1" ".batches[] | select(.id == \$b) | $2" "$BL_STATE"; }
iq() { jq -r --arg i "$1" ".items[] | select(.id == \$i) | $2" "$BL_STATE"; }

RUN_ID="$(get '.run.id')"
ITERATION="$(get '.run.total_iterations')"
STATUS="$(get '.run.status')"
REPORT="Run: $S/report.sh"

finish() {
  # finish <done|halted|stalled> <reason>
  if [ "$PEEK" -eq 0 ] && [ "$(get '.run.status')" = "running" ]; then
    st record run "$1" "$2" >/dev/null
  fi
}

case "$STATUS" in
  done)
    emit "done" "The run is finished." <<EOT
$REPORT
EOT
    exit 0
    ;;
  halted | stalled)
    reason="$(get '.run.halt_reason // "no reason recorded"')"
    if [ "$reason" = "plan-only" ]; then
      emit halt "Plan-only run: the plan is ready for review." --arg reason "$reason" <<EOT
Show the user $BL_DIR/plan.md.
Tell the user to run /backlog-loop --resume to execute the plan.
EOT
    else
      emit halt "The run is $STATUS: $reason" --arg reason "$reason" <<EOT
$REPORT
Tell the user that /backlog-loop --resume continues from the saved state.
EOT
    fi
    exit 0
    ;;
esac

# --- limits -------------------------------------------------------------------

now="$(bl_now)"
max_iter="$(bl_limit max_iterations)"
max_hours="$(bl_limit max_hours)"
iter="$(get '.run.iterations')"
started="$(get '.run.segment_started_at')"
if [ "$iter" -ge "${max_iter:-100}" ]; then
  finish halted "iteration limit reached ($max_iter)"
  emit halt "Iteration limit reached ($max_iter)." --arg reason "iteration limit" <<EOT
$REPORT
Tell the user that /backlog-loop --resume continues with a fresh budget.
EOT
  exit 0
fi
if [ $((now - started)) -ge $((${max_hours:-12} * 3600)) ]; then
  finish halted "wall-clock limit reached (${max_hours}h)"
  emit halt "Wall-clock limit reached (${max_hours}h)." --arg reason "wall-clock limit" <<EOT
$REPORT
Tell the user that /backlog-loop --resume continues with a fresh budget.
EOT
  exit 0
fi

# --- bookkeeping that needs no agent -------------------------------------------

if [ "$PEEK" -eq 0 ]; then
  bl_lock_touch
  st housekeeping
fi

# --- decide --------------------------------------------------------------------

# One line: "<action>\t<batch-or-item id>". Order is the priority of the loop.
decision="$(jq -r '
  def first_batch(f): [.batches | sort_by(.order)[] | select(f)] | first;
  . as $s
  | [.batches[] | select(.status == "merged" or .status == "closed"
      or (.status == "blocked" and .retry_of != null)) | .id] as $ok
  | ([.batches[] | select(.phase == "working")] | length) as $running
  | (.config.limits.parallel_batches // 2) as $par
  | [.batches | sort_by(.order)[] | select(.status == "todo")
      | select(all(.depends_on[]; . as $d | any($ok[]; . == $d)))] as $eligible
  | [.batches | sort_by(.order)[] | select(.status == "in-progress" and .phase == "implement")] as $again
  | ($again + $eligible) as $startable
  | ([$startable[] | .id as $b | $s.items[] | select(.batch == $b and .research == "pending"
        and .pending == null and (.status == "todo" or .status == "in-progress"))] | first) as $research
  | [$startable[] | select(.id as $b | [$s.items[] | select(.batch == $b and .research == "pending" and .pending == null
        and (.status == "todo" or .status == "in-progress"))] | length == 0)] as $ready
  | ([.items[] | select(.pending == "block" and .status != "blocked")] | first) as $block
  | ([.items[] | select(.pending == "drop")] | first) as $drop
  | if (.batches | length) == 0 then "plan\t0"
    elif $block then "mark_blocked\t\($block.id)"
    elif first_batch(.phase == "revert") then "revert_batch\t\(first_batch(.phase == "revert").id)"
    elif first_batch(.phase == "post-merge") then "verify\t\(first_batch(.phase == "post-merge").id)"
    elif first_batch(.phase == "merge") then "merge\t\(first_batch(.phase == "merge").id)"
    elif first_batch(.phase == "rebase") then "rebase_batch\t\(first_batch(.phase == "rebase").id)"
    elif first_batch(.phase == "conflict") then "resolve_conflict\t\(first_batch(.phase == "conflict").id)"
    elif $drop then "drop_item\t\($drop.id)"
    elif first_batch(.phase == "fix") then "fix_ci\t\(first_batch(.phase == "fix").id)"
    elif first_batch(.phase == "ci-rerun") then "rerun_ci\t\(first_batch(.phase == "ci-rerun").id)"
    elif first_batch(.phase == "open-pr") then "open_pr\t\(first_batch(.phase == "open-pr").id)"
    elif $research then "research\t\($research.id)"
    elif ($ready | length) > 0 and $running < $par
      then "implement_batch\t\([$ready[:($par - $running)][] | .id | tostring] | join(","))"
    elif first_batch(.phase == "ci") then "wait_ci\t\(first_batch(.phase == "ci").id)"
    elif $running > 0 then "wait_worker\t\([.batches[] | select(.phase == "working") | .id | tostring] | join(","))"
    elif .config.source == "file" and (.run.sync == null)
      and ([.items[] | select((.preblocked | not) and (.status == "merged" or .status == "blocked"))] | length) > 0
      and ([.batches[] | select(.status == "todo")] | length) == 0
      then "sync_backlog\t0"
    elif ([.batches[] | select(.status == "todo")] | length) > 0 then "waiting_on_merge\t0"
    else "finished\t0" end' "$BL_STATE")"

action="${decision%%	*}"
target="${decision#*	}"

# Waiting does not use up the iteration budget.
if [ "$PEEK" -eq 0 ]; then
  case "$action" in
    wait_ci | wait_worker) ;;
    *)
      st tick
      ITERATION="$(get '.run.total_iterations')"
      ;;
  esac
  bl_log "next action=$action target=$target iteration=$ITERATION"
fi

base="$(bl_cfg base_branch)"
method="$(bl_cfg merge_method)"
SPAWN='Spawn one worker: Agent tool, subagent_type "general-purpose", isolation "worktree". Pass the printed prompt verbatim as the prompt.'

case "$action" in
  plan)
    emit plan "Cluster the open items into themed batches." --arg plan_file "$BL_DIR/plan.json" <<EOT
Run: $S/state.sh items   to list the open items. Read each item in full before clustering.
Read $BL_SKILL_DIR/reference/batching.md and follow it.
Write the plan to $BL_DIR/plan.json as {"batches":[{"theme":"...","title":"<PR title in the repo's commit convention>","rationale":"...","items":["<id>"],"depends_on":[<earlier batch number>]}],"unclear":[{"id":"<id>","question":"..."}]}.
Run: $S/state.sh plan-apply $BL_DIR/plan.json   and fix the plan if it is rejected.
EOT
    ;;

  mark_blocked)
    emit mark_blocked "Item $(bl_ref "$target") is out of options: $(iq "$target" '.last_error // "no error recorded"')" \
      --arg item "$target" --arg last_error "$(iq "$target" '.last_error // ""')" <<EOT
Run: $S/mark-blocked.sh $target --tried "<what was attempted>" --why "<why it failed>" --needs "<the input a human must provide>"
Fill the three texts from the evidence you have: worker reports, CI logs, the last error above.
EOT
    ;;

  revert_batch)
    pr="$(bq "$target" '.pr')"
    emit revert_batch "The base branch is red after merging batch $target (PR #$pr): $(bq "$target" '.last_error')" \
      --argjson batch "$target" --argjson pr "$pr" <<EOT
Run: gh pr revert $pr --title "revert: backlog batch $target" --body "Base branch checks failed after the merge."
Run: $S/state.sh record revert-opened $target <number of the revert PR>
Run: $S/ci-wait.sh --pr <revert PR number>   and repeat it while it prints pending.
When it prints green, run: gh pr merge <revert PR number> --$method
Run: $S/state.sh record reverted $target
If any step cannot be completed, run: $S/state.sh record revert-failed $target --reason "<what failed>"
EOT
    ;;

  verify)
    emit verify "Confirm batch $target is merged and that $base is still green." --argjson batch "$target" \
      --argjson pr "$(bq "$target" '.pr')" <<EOT
Run with a 10 minute Bash timeout: $S/verify-batch.sh $target post-merge
EOT
    ;;

  merge)
    pr="$(bq "$target" '.pr')"
    emit merge "Merge batch $target (PR #$pr) into $base." --argjson batch "$target" --argjson pr "$pr" <<EOT
Run: $S/verify-batch.sh $target pre-merge
Only if it prints READY, run the merge command it prints, exactly as printed.
Run: $S/verify-batch.sh $target merged
EOT
    ;;

  rebase_batch)
    emit rebase_batch "Batch $target is behind $base and must be updated before it merges." --argjson batch "$target" <<EOT
Run: $S/verify-batch.sh $target rebase
EOT
    ;;

  resolve_conflict)
    emit resolve_conflict "Batch $target conflicts with $base. One fix attempt, then the batch is re-queued." \
      --argjson batch "$target" --arg branch "$(bq "$target" '.branch')" <<EOT
Run: $S/state.sh cleanup $target
Run: $S/state.sh worker-prompt $target --mode conflict
$SPAWN
If the worker reports the conflict resolved and pushed, run: $S/state.sh record conflict-resolved $target
Otherwise run: $S/state.sh record conflict-failed $target
EOT
    ;;

  drop_item)
    b="$(iq "$target" '.batch')"
    emit drop_item "Remove item $(bl_ref "$target") from batch $b: $(iq "$target" '.last_error // ""')" \
      --arg item "$target" --argjson batch "$b" --arg branch "$(bq "$b" '.branch')" <<EOT
Run: $S/state.sh cleanup $b
Run: $S/state.sh worker-prompt $b --mode drop --item $target
$SPAWN
Run: $S/state.sh record item-dropped $target
EOT
    ;;

  fix_ci)
    pr="$(bq "$target" '.pr')"
    err="$(bq "$target" '.last_error // ""')"
    case "$err" in
      "CI timeout"*)
        emit fix_ci "CI for batch $target (PR #$pr) did not finish in time." --argjson batch "$target" --argjson pr "$pr" \
          --arg last_error "$err" <<EOT
Find out why: gh pr checks $pr ; gh run list --branch $(bq "$target" '.branch') --limit 5
If runs are stuck or queued, cancel them with gh run cancel <id> and start them again with gh run rerun <id>.
Run: $S/state.sh record ci-retry $target
If the cause is in the code, delegate a fix as for a red CI and run: $S/state.sh record fix-pushed $target
EOT
        ;;
      *)
        emit fix_ci "CI is red for batch $target (PR #$pr): $err" --argjson batch "$target" --argjson pr "$pr" \
          --arg branch "$(bq "$target" '.branch')" --arg last_error "$err" \
          --argjson failures "$(bq "$target" '.failures')" <<EOT
Read the evidence yourself: gh pr checks $pr ; gh run list --branch $(bq "$target" '.branch') --limit 5 ; gh run view <run id> --log-failed
Reason about the cause. Read $BL_SKILL_DIR/reference/failures.md if the cause is not obvious.
If one item is the cause and the rest is sound, run: $S/state.sh record poison $target <item id> --reason "<cause>"   and stop here.
Otherwise run: $S/state.sh cleanup $target
Run: $S/state.sh worker-prompt $target --mode fix   and append your diagnosis and the relevant log lines to the printed prompt.
$SPAWN
Run: $S/state.sh record fix-pushed $target
EOT
        ;;
    esac
    ;;

  rerun_ci)
    emit rerun_ci "CI failed once for batch $target. Rerun the failed jobs before treating it as real." \
      --argjson batch "$target" --argjson pr "$(bq "$target" '.pr')" <<EOT
Run: $S/ci-wait.sh $target --rerun
EOT
    ;;

  open_pr)
    emit open_pr "Open the pull request for batch $target." --argjson batch "$target" \
      --arg branch "$(bq "$target" '.branch')" <<EOT
Run: $S/state.sh open-pr $target
EOT
    ;;

  research)
    emit research "Item $(bl_ref "$target") is unclear: $(iq "$target" '.question // ""')" --arg item "$target" \
      --arg decision_file "$BL_DIR/decisions/$target.md" <<EOT
Run: $S/state.sh research-prompt $target
Spawn one research agent: Agent tool, subagent_type "Explore". Pass the printed prompt verbatim. One pass only.
Read $BL_SKILL_DIR/reference/research.md and write the decision record to $BL_DIR/decisions/$target.md using its template.
If the agent returns nothing useful, decide yourself from the codebase and set confidence low. Never ask the user.
Run: $S/state.sh record decision $target --confidence <high|medium|low>
EOT
    ;;

  implement_batch)
    {
      old_ifs="$IFS"
      IFS=','
      for b in $target; do
        IFS="$old_ifs"
        printf 'Batch %s: run: %s/state.sh record worker-started %s\n' "$b" "$S" "$b"
        printf 'Batch %s: run: %s/state.sh worker-prompt %s\n' "$b" "$S" "$b"
        printf 'Batch %s: %s\n' "$b" "$SPAWN"
      done
      IFS="$old_ifs"
      printf 'Start the workers of all listed batches in one message so they run in parallel.\n'
      printf 'When a worker reports, for each item it calls unclear run: %s/state.sh record unclear <item> --question "<question>"\n' "$S"
      printf 'For each item it calls a hard blocker (missing credentials or access, destructive or irreversible operation) run: %s/state.sh record hard-blocker <item> --reason "<reason>"\n' "$S"
      printf 'Then run: %s/state.sh record worker-done <batch>   (it checks the pushed branch, not the report).\n' "$S"
      printf 'If a worker crashed or returned nothing, run: %s/state.sh record worker-failed <batch> --reason "<what happened>"\n' "$S"
    } | emit implement_batch "Implement batch(es) $target, each in its own worktree." \
      --argjson batches "[$target]" \
      --argjson detail "$(jq -c --argjson ids "[$target]" '[.batches[] | select(.id as $b | any($ids[]; . == $b))
        | {batch: .id, theme, items, mode: (if .pushed then "continue" else "fresh" end)}]' "$BL_STATE")"
    ;;

  wait_ci)
    emit wait_ci "Wait for CI on batch $target (PR #$(bq "$target" '.pr'))." --argjson batch "$target" \
      --argjson pr "$(bq "$target" '.pr')" <<EOT
Run: $S/ci-wait.sh $target
While it prints PENDING, run the same command again. It records the result itself and stops at the deadline.
EOT
    ;;

  wait_worker)
    emit wait_worker "Workers for batch(es) $target are still running." --argjson batches "[$target]" <<EOT
If a worker has reported since, record its result now: $S/state.sh record worker-done <batch>
If workers run in the background, end your turn. Their completion notification wakes you; then run next.sh.
If no worker is actually running, run: $S/state.sh record worker-failed <batch> --reason "worker lost"
EOT
    ;;

  sync_backlog)
    emit sync_backlog "Record the results in $(bl_cfg path) through a final pull request." <<EOT
Run: $S/state.sh sync-backlog
EOT
    ;;

  waiting_on_merge)
    finish halted "remaining batches depend on pull requests that wait for a human merge"
    emit halt "The remaining batches depend on pull requests that wait for your merge." \
      --arg reason "waiting for human merge" <<EOT
$REPORT
Tell the user to merge the listed pull requests and run /backlog-loop --resume.
EOT
    ;;

  finished)
    finish "done" ""
    emit "done" "Every item is merged, waits in a green pull request, or is blocked." <<EOT
$REPORT
EOT
    ;;

  *)
    emit halt "next.sh could not decide on an action (got: $action)." --arg reason "internal error" <<EOT
Show this to the user together with the output of: $S/state.sh status
EOT
    ;;
esac
