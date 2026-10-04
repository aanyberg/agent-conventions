#!/usr/bin/env bash
# verify-batch.sh: confirm through gh and git what happened to a batch.
# Never trusts what the agent says: every result is read from GitHub or git.
#
#   verify-batch.sh <batch> pre-merge    PR open, up to date with base, checks green
#   verify-batch.sh <batch> merged       the PR is merged on GitHub
#   verify-batch.sh <batch> post-merge   CI on the base branch is green for the merge
#   verify-batch.sh <batch> rebase       bring the PR branch up to date with base
set -u
BL_SELF=verify-batch
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bl_paths || bl_die "not inside a git repository"
bl_state_ok || bl_die "no usable state; run preflight.sh first"

b="${1:-}"
mode="${2:-}"
case "$b" in '' | *[!0-9]*) bl_die "usage: verify-batch.sh <batch> pre-merge|merged|post-merge|rebase" ;; esac
st() { "$BL_SCRIPT_DIR/state.sh" "$@"; }
bq() { jq -r --argjson b "$b" ".batches[] | select(.id == \$b) | $1" "$BL_STATE"; }
[ -n "$(bq '.id')" ] || bl_die "unknown batch: $b"

pr="$(bq '.pr // empty')"
phase="$(bq '.phase // "none"')"
branch="$(bq '.branch // empty')"
base="$(bl_cfg base_branch)"
[ -n "$pr" ] || bl_die "batch $b has no pull request yet. Run next.sh."
bl_lock_touch

merge_commit() { gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null; }

case "$mode" in
  pre-merge)
    [ "$phase" = "merge" ] || bl_die "batch $b is in phase '$phase', not ready to merge. Run next.sh."
    case "$(bl_pr_field "$pr" state)" in
      MERGED)
        st record merged "$b" "$(merge_commit)"
        echo "ALREADY MERGED: PR #$pr. Run next.sh."
        exit 0
        ;;
      CLOSED)
        st reconcile
        echo "CLOSED: PR #$pr was closed; the batch was reset. Run next.sh."
        exit 0
        ;;
      OPEN) ;;
      *) bl_die "could not read PR #$pr from GitHub" ;;
    esac
    git -C "$BL_ROOT" fetch -q origin "$base" "$branch" >/dev/null 2>&1 || true
    if [ "$(bl_pr_field "$pr" mergeable)" = "CONFLICTING" ]; then
      st record conflict "$b"
      echo "CONFLICT: PR #$pr conflicts with $base. Run next.sh."
      exit 0
    fi
    if ! git -C "$BL_ROOT" merge-base --is-ancestor "origin/$base" "origin/$branch" 2>/dev/null; then
      st record behind "$b"
      echo "BEHIND: PR #$pr does not contain the tip of $base. Run next.sh."
      exit 0
    fi
    checks="$(bl_pr_checks "$pr")"
    if [ "$checks" != "green" ]; then
      st record recheck "$b"
      echo "NOT GREEN: checks on PR #$pr are $checks. Run next.sh."
      exit 0
    fi
    head="$(bl_pr_field "$pr" headRefOid)"
    st record premerge-ok "$b" "$head"
    echo "READY: PR #$pr is open, up to date with $base and green."
    echo "Merge command: gh pr merge $pr --$(bl_cfg merge_method) --match-head-commit $head"
    ;;

  merged)
    [ "$phase" = "merge" ] || bl_die "batch $b is in phase '$phase'. Run next.sh."
    tries=0
    state="$(bl_pr_field "$pr" state)"
    while [ "$state" != "MERGED" ] && [ "$tries" -lt "${BACKLOG_LOOP_MERGE_POLLS:-6}" ]; do
      sleep "${BACKLOG_LOOP_POLL_SECONDS:-5}"
      tries=$((tries + 1))
      state="$(bl_pr_field "$pr" state)"
    done
    if [ "$state" = "MERGED" ]; then
      st record merged "$b" "$(merge_commit)"
      echo "MERGED: GitHub confirms PR #$pr is merged. Run next.sh."
    elif [ "$(bl_pr_field "$pr" mergeable)" = "CONFLICTING" ]; then
      st record conflict "$b"
      echo "CONFLICT: PR #$pr was not merged because it conflicts with $base. Run next.sh."
    else
      st record merge-failed "$b" "PR #$pr is still ${state:-unknown} after the merge command"
      echo "NOT MERGED: PR #$pr is still ${state:-unknown}. Run next.sh."
    fi
    ;;

  post-merge)
    [ "$phase" = "post-merge" ] || bl_die "batch $b is in phase '$phase'. Run next.sh."
    [ "$(bl_pr_field "$pr" state)" = "MERGED" ] || bl_die "GitHub does not show PR #$pr as merged"
    current="$(git -C "$BL_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ "$current" = "$base" ] || bl_die "the main checkout is on '$current', expected '$base'. Check out $base and run this again."
    git -C "$BL_ROOT" pull -q --ff-only origin "$base" >/dev/null 2>&1 ||
      bl_die "could not fast-forward $base in the main checkout. Make it clean and run this again."
    # The base branch is judged by its CI, on the merge commit. Nothing is run locally.
    sha="$(git -C "$BL_ROOT" rev-parse "refs/remotes/origin/$base" 2>/dev/null)"
    wait_min="$(bl_limit ci_wait_minutes)"
    deadline=$(($(bq '.ci_started_at // 0') + ${wait_min:-45} * 60))
    end=$(($(date +%s) + ${BACKLOG_LOOP_SLICE_SECONDS:-100}))
    while :; do
      result="$(bl_commit_checks "$(bl_cfg repo)" "$sha")"
      bl_lock_touch
      case "$result" in
        green)
          st record post-merge "$b" pass
          echo "VERIFIED: PR #$pr is merged and CI is green on $base. Run next.sh."
          exit 0
          ;;
        red*)
          st record post-merge "$b" fail "CI failed on $base: ${result#red }"
          echo "BASE RED: CI fails on $base after merging PR #$pr: ${result#red }"
          echo "Run next.sh. The merge will be reverted."
          exit 0
          ;;
        none)
          # No CI on pushes to the base branch. The PR was green and contained
          # the base tip, so its result stands once CI had time to start.
          if [ "$(bq '.ci_polls')" -ge 1 ]; then
            st record post-merge "$b" pass
            echo "VERIFIED: PR #$pr is merged. No CI runs on $base itself; the green PR result stands. Run next.sh."
            exit 0
          fi
          ;;
      esac
      if [ "$(bl_now)" -ge "$deadline" ]; then
        st record post-merge "$b" pass
        bl_log "post-merge: CI on $base did not finish within ${wait_min:-45} minutes for batch $b; accepted on the green PR result"
        echo "VERIFIED: PR #$pr is merged. CI on $base did not finish in time; the green PR result stands. Run next.sh."
        exit 0
      fi
      if [ $(($(date +%s) + ${BACKLOG_LOOP_POLL_SECONDS:-20})) -gt "$end" ]; then
        st record post-merge "$b" poll
        echo "PENDING: CI on $base is still running for the merge of PR #$pr. Run this command again."
        exit 0
      fi
      sleep "${BACKLOG_LOOP_POLL_SECONDS:-20}"
    done
    ;;

  rebase)
    [ "$phase" = "rebase" ] || bl_die "batch $b is in phase '$phase'. Run next.sh."
    if gh pr update-branch "$pr" --rebase >/dev/null 2>&1 || gh pr update-branch "$pr" >/dev/null 2>&1; then
      sleep "${BACKLOG_LOOP_POLL_SECONDS:-5}"
      st record rebased "$b"
      echo "UPDATED: PR #$pr now contains $base. CI runs again. Run next.sh."
    else
      st record conflict "$b"
      echo "CONFLICT: PR #$pr could not be updated from $base. Run next.sh."
    fi
    ;;

  *) bl_die "usage: verify-batch.sh <batch> pre-merge|merged|post-merge|rebase" ;;
esac
