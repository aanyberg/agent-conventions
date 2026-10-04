#!/usr/bin/env bash
# End-to-end dry run: drives the whole loop on a fixture repository with a
# five-item backlog, playing the part of Claude. No network: gh and the remote
# side of git are stubbed (BACKLOG_LOOP_DRY_RUN=1).
#
#   tests/dry-run.sh [github|file] [--keep]
#
# Scenario:
#   items 1, 2  batch 1, clean path
#   item 3      batch 2, CI red (one rerun, then a fix by a worker)
#   item 4      batch 3, unclear -> research -> decision record (low confidence)
#   item 5      batch 3, hard blocker (missing credentials)
# shellcheck disable=SC2016
set -u
# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

SOURCE="github"
KEEP=0
for a in "$@"; do
  case "$a" in
    github | file) SOURCE="$a" ;;
    --keep) KEEP=1 ;;
  esac
done

export BACKLOG_LOOP_DRY_RUN=1
# The driver plays Claude, so its own git and gh calls are stubbed as well.
BACKLOG_LOOP_REAL_GIT="$(command -v git)"
export BACKLOG_LOOP_REAL_GIT
PATH="$SKILL_DIR/tests/stubs:$PATH"
export PATH
export BACKLOG_LOOP_POLL_SECONDS=0
export BACKLOG_LOOP_SLICE_SECONDS=0
unset BACKLOG_LOOP_ROOT BACKLOG_LOOP_NOW CLAUDE_CODE_STOP_HOOK_BLOCK_CAP

t_tmp
REPO="$T_TMP/fixture"
make_fixture "$REPO" "$SOURCE"
cd "$REPO" || exit 1
DIR="$REPO/.planning/backlog-loop"
STATE="$DIR/state.json"
[ "$KEEP" -eq 0 ] || trap - EXIT

echo "Dry run ($SOURCE source) in $REPO"

# --- the simulated worker ----------------------------------------------------------

# worker <branch> <start ref> <shell snippet run inside the worktree>
worker() {
  local branch="$1" start="$2" snippet="$3" wt rc
  wt="$T_TMP/wt-$RANDOM"
  git worktree add -q -B "$branch" "$wt" "$start" >/dev/null 2>&1 || { echo "worker: worktree add failed" >&2; return 1; }
  (cd "$wt" && eval "$snippet")
  rc=$?
  git worktree remove --force "$wt" >/dev/null 2>&1
  return "$rc"
}

bq() { jq -r --argjson b "$1" ".batches[] | select(.id == \$b) | $2" "$STATE"; }
iq() { jq -r --arg i "$1" ".items[] | select(.id == \$i) | $2" "$STATE"; }

implement() {
  local b="$1" branch prompt ids id snippet=""
  branch="$("$S/state.sh" record worker-started "$b")" || return 1
  prompt="$("$S/state.sh" worker-prompt "$b")"
  assert_contains "batch $b: worker prompt names the branch" "$branch" "$prompt"
  assert_contains "batch $b: worker prompt asks for the item trailer" "Backlog-Item:" "$prompt"
  ids="$(jq -r --argjson b "$b" '.items[] | select(.batch == $b and .pending == null and .research != "pending"
    and (.status == "todo" or .status == "in-progress")) | .id' "$STATE")"
  for id in $ids; do
    case "$id" in
      4)
        if [ "$(iq 4 '.research')" = "none" ]; then
          "$S/state.sh" record unclear 4 --question "ISO 8601 or locale format for dates?" >/dev/null
          continue
        fi
        assert_contains "item 4: worker prompt carries the decision record" "Decision for item 4" "$prompt"
        ;;
      5)
        "$S/state.sh" record hard-blocker 5 --reason "needs production billing API credentials" >/dev/null
        continue
        ;;
    esac
    snippet="$snippet echo 'feature $id' > feature-$id.txt;"
    [ "$id" != "3" ] || snippet="$snippet touch .ci-fail;"
    snippet="$snippet git add -A; git commit -q -m 'feat: item $id' -m 'Backlog-Item: $id';"
  done
  if [ -n "$snippet" ]; then
    worker "$branch" "origin/main" "$snippet git push -q origin $branch" || return 1
  fi
  "$S/state.sh" record worker-done "$b" >/dev/null
}

# Run the Stop hook as Claude Code would.
gate() { hook_input Stop "$REPO" | "$S/stop-gate.sh"; }

guard() { bash_input "$REPO" "$1" | "$S/guard.sh"; }

# --- the loop ----------------------------------------------------------------------------

steps=0
action=""
seen=" "
while [ "$steps" -lt 150 ]; do
  steps=$((steps + 1))
  out="$("$S/next.sh")" || { not_ok "next.sh exits 0" "step $steps"; break; }
  action="$(printf '%s' "$out" | jq -r '.action')"
  target="$(printf '%s' "$out" | jq -r '.batch // .item // (.batches // [] | map(tostring) | join(","))')"
  case "$seen" in *" $action "*) ;; *) seen="$seen$action " ;; esac
  [ -z "${DRY_RUN_VERBOSE:-}" ] || printf '    step %s: %s %s\n' "$steps" "$action" "$target"

  case "$action" in
    preflight)
      "$S/preflight.sh" --probes | while IFS= read -r probe; do
        bash -c "$probe" >/dev/null 2>&1 || echo "probe failed: $probe"
      done
      pre="$("$S/preflight.sh" --session dry 2>&1)" || { not_ok "preflight passes" "$pre"; break; }
      assert_contains "preflight prints the summary line" "Preflight: " "$pre"
      assert_contains "preflight has no failures" " 0 failed" "$pre"
      assert_eq "state directory is ignored" "0" "$(git check-ignore -q "$DIR/state.json"; echo $?)"
      assert_empty "preflight leaves tracked files unchanged" "$(git status --porcelain --untracked-files=no)"
      ;;

    plan)
      assert_eq "plan: five open items are listed" "5" "$("$S/state.sh" items | jq length)"
      cat >"$DIR/plan.json" <<'EOP'
{"batches": [
  {"theme": "Greeting", "title": "feat: greeting", "rationale": "Feature and its tests belong together.", "items": ["1", "2"]},
  {"theme": "Farewell", "title": "feat: farewell", "items": ["3"]},
  {"theme": "Dates and billing", "title": "feat: dates and billing", "items": ["4", "5"], "depends_on": [1]}
]}
EOP
      "$S/state.sh" plan-apply "$DIR/plan.json" >/dev/null || { not_ok "plan is accepted"; break; }
      assert_contains "plan.md lists the batches" "## Batch 3: Dates and billing" "$(cat "$DIR/plan.md")"
      # Claude tries to stop right after planning: the gate must send it back to work.
      g="$(gate)"
      assert_eq "stop gate blocks while work remains" "block" "$(printf '%s' "$g" | jq -r '.decision')"
      assert_contains "stop gate hands over the next action" "implement_batch" "$g"
      ;;

    implement_batch)
      for b in $(printf '%s' "$out" | jq -r '.batches[]'); do
        implement "$b" || { not_ok "worker for batch $b"; break 2; }
      done
      ;;

    research)
      prompt="$("$S/state.sh" research-prompt "$target")"
      assert_contains "research prompt carries the question" "ISO 8601" "$prompt"
      cat >"$DIR/decisions/$target.md" <<'EOD'
# Decision for 4: Pick a date format

## Question

ISO 8601 or locale format for dates?

## Options

1. ISO 8601: unambiguous, sorts as text.
2. Locale format: friendlier, but varies per user.

## Choice

ISO 8601, because the fixture has no locale handling to build on.

## Evidence

- `CLAUDE.md:1`: no locale tooling in the repository.

## Assumptions

- Dates are shown to developers, not end users.

## Confidence

low: no existing convention settles it.
EOD
      "$S/state.sh" record decision "$target" --confidence low >/dev/null || { not_ok "decision is recorded"; break; }
      second="$("$S/state.sh" record unclear "$target" --question "again?" 2>&1)"
      assert_contains "a second research pass is refused" "research budget" "$second"
      ;;

    mark_blocked)
      "$S/mark-blocked.sh" "$target" --tried "implementing against the sandbox API" \
        --why "the billing API rejects calls without production credentials" \
        --needs "production billing API credentials" >/dev/null || { not_ok "mark-blocked.sh"; break; }
      ;;

    open_pr)
      "$S/state.sh" open-pr "$target" >/dev/null || { not_ok "open-pr for batch $target"; break; }
      ;;

    wait_ci)
      "$S/ci-wait.sh" "$target" >/dev/null || { not_ok "ci-wait.sh"; break; }
      ;;

    rerun_ci)
      "$S/ci-wait.sh" "$target" --rerun >/dev/null || { not_ok "ci-wait.sh --rerun"; break; }
      ;;

    fix_ci)
      assert_contains "fix_ci names the failing check" "CI red" "$(printf '%s' "$out" | jq -r '.summary')"
      "$S/state.sh" cleanup "$target"
      prompt="$("$S/state.sh" worker-prompt "$target" --mode fix)"
      assert_contains "fix prompt says what failed" "CI red" "$prompt"
      branch="$(bq "$target" '.branch')"
      worker "$branch" "origin/$branch" "git rm -q .ci-fail; git commit -q -m 'fix: make CI pass' -m 'Backlog-Fix: 3'; git push -q origin $branch" ||
        { not_ok "fix worker"; break; }
      "$S/state.sh" record fix-pushed "$target" >/dev/null || { not_ok "fix-pushed"; break; }
      ;;

    merge)
      pr="$(bq "$target" '.pr')"
      early="$(guard "gh pr merge $pr --squash")"
      assert_contains "guard denies a merge before pre-merge verification (PR #$pr)" '"deny"' "$early"
      pre="$("$S/verify-batch.sh" "$target" pre-merge)"
      case "$pre" in
        READY*)
          merge_cmd="$(printf '%s\n' "$pre" | sed -n 's/^Merge command: //p')"
          assert_empty "guard allows the verified merge of PR #$pr" "$(guard "$merge_cmd")"
          assert_contains "guard denies --admin" '"deny"' "$(guard "$merge_cmd --admin")"
          eval "$merge_cmd" >/dev/null || { not_ok "merge command"; break; }
          "$S/verify-batch.sh" "$target" merged >/dev/null || { not_ok "verify merged"; break; }
          ;;
      esac
      ;;

    rebase_batch)
      "$S/verify-batch.sh" "$target" rebase >/dev/null || { not_ok "verify-batch.sh rebase"; break; }
      ;;

    verify)
      "$S/verify-batch.sh" "$target" post-merge >/dev/null || { not_ok "verify-batch.sh post-merge"; break; }
      ;;

    sync_backlog)
      "$S/state.sh" sync-backlog >/dev/null || { not_ok "sync-backlog"; break; }
      ;;

    done | halt) break ;;

    *)
      not_ok "the dry run knows how to handle action '$action'"
      break
      ;;
  esac
done

# --- what must be true at the end -------------------------------------------------------

assert_eq "the loop ends with action done" "done" "$action"
assert_eq "run status is done" "done" "$(jq -r '.run.status' "$STATE")"
assert_eq "items 1-4 are merged" "1,2,3,4" "$(jq -r '[.items[] | select(.status == "merged") | .id] | join(",")' "$STATE")"
assert_eq "item 5 is blocked" "5" "$(jq -r '[.items[] | select(.status == "blocked") | .id] | join(",")' "$STATE")"
assert_eq "item 4 needs review" "true" "$(iq 4 '.needs_review')"
assert_eq "decision record exists" "yes" "$([ -s "$DIR/decisions/4.md" ] && echo yes)"
assert_eq "batch 2 took one fix" "1" "$(bq 2 '.fixes')"
assert_eq "batch 2 took one CI rerun" "1" "$(bq 2 '.ci_reruns')"
assert_eq "the lock is released" "no" "$([ -e "$DIR/lock" ] && echo yes || echo no)"
for step in plan implement_batch research mark_blocked open_pr wait_ci rerun_ci fix_ci merge rebase_batch verify; do
  case "$seen" in *" $step "*) ok "action $step was exercised" ;; *) not_ok "action $step was exercised" "seen:$seen" ;; esac
done

tree="$(git ls-tree -r --name-only origin/main | tr '\n' ' ')"
for f in feature-1.txt feature-2.txt feature-3.txt feature-4.txt; do
  assert_contains "origin/main contains $f" "$f" "$tree"
done
case "$tree" in *feature-5.txt* | *.ci-fail*) not_ok "origin/main has no blocked or broken content" "$tree" ;; *) ok "origin/main has no blocked or broken content" ;; esac
assert_eq "the main checkout follows origin/main" "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
assert_empty "no worktrees are left behind" "$(git worktree list --porcelain | grep '^branch refs/heads/backlog-loop/' || true)"

assert_contains "run.log records actions while the run is live" "next action=merge" "$(cat "$DIR/run.log")"
report="$("$S/report.sh")"
assert_contains "report: headline" "Backlog loop finished: done" "$report"
assert_contains "report: item counts" "Items:   4 merged, 1 blocked, 0 remaining" "$report"
assert_contains "report: blocked reason" "Reason: the billing API rejects calls without production credentials" "$report"
assert_contains "report: review line" "decided with low confidence, see decisions/4.md" "$report"
assert_contains "report: retries" "batch 2 (1 fix, 1 CI rerun)" "$report"
assert_eq "report.md is written" "yes" "$([ -s "$DIR/report.md" ] && echo yes)"
assert_eq "a finished run keeps report and state, not logs and prompts" "state.json report.md plan.md | gone gone gone" \
  "$(cd "$DIR" && ls state.json report.md plan.md | tr '\n' ' ')| $([ -e run.log ] || echo gone) $([ -e prompts ] || echo gone) $([ -e pr-body.md ] || echo gone)"
assert_eq "a later report still works and leaves no log behind" "gone" "$("$S/report.sh" >/dev/null; [ -e "$DIR/run.log" ] || echo gone)"

GH="$DIR/dry-run/gh.json"
if [ "$SOURCE" = "github" ]; then
  assert_contains "report: PR list" "(3 PRs for 4 items)" "$report"
  assert_eq "issue 5 carries the blocked label" "true" "$(jq '.issues[] | select(.number == 5) | .labels | index("blocked") != null' "$GH")"
  assert_eq "issue 4 carries the needs-review label" "true" "$(jq '.issues[] | select(.number == 4) | .labels | index("needs-review") != null' "$GH")"
  assert_contains "issue 5 got the blocker comment" "production billing API credentials" "$(jq -r '.issues[] | select(.number == 5) | .comments | join(" ")' "$GH")"
  assert_eq "issues 1-4 are closed" "1,2,3,4" "$(jq -r '[.issues[] | select(.state == "CLOSED") | .number | tostring] | join(",")' "$GH")"
  assert_contains "PR body closes its items" "Closes #1" "$(jq -r '.prs[] | select(.number == 201 or .number == 202) | .body' "$GH")"
  assert_contains "PR body carries the decision record" "ISO 8601" "$(jq -r '.prs[].body' "$GH")"
else
  backlog="$(git show origin/main:BACKLOG.md)"
  assert_contains "BACKLOG.md marks merged items done" "| 1 | Add greeting | done |" "$backlog"
  assert_contains "BACKLOG.md annotates the blocked item" "BLOCKED: the billing API rejects calls" "$backlog"
  assert_contains "the status update went through a PR" "sync_backlog" "$seen"
fi

# The gate allows the stop once the run is finished, and both hooks are silent.
assert_empty "stop gate is silent after the run" "$(gate)"
assert_empty "guard is silent after the run" "$(guard "git push --force origin main")"

t_summary
