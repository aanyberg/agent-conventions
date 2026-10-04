#!/usr/bin/env bash
# ci-wait.sh: poll the checks of a pull request with a hard deadline.
#
#   ci-wait.sh <batch>           poll for one slice, record the result in state
#   ci-wait.sh <batch> --rerun   rerun the failed jobs once (flaky CI)
#   ci-wait.sh --pr <number>     poll any PR for one slice, no state change
#
# One call waits at most BACKLOG_LOOP_SLICE_SECONDS (default 100, below the
# default Bash tool timeout) and prints PENDING when checks are still running.
# Call it again while it prints PENDING. The deadline is counted from the
# moment the batch entered CI and is stored in state, so it survives restarts.
# shellcheck disable=SC2016
set -u
BL_SELF=ci-wait
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bl_paths || bl_die "not inside a git repository"
bl_state_ok || bl_die "no usable state; run preflight.sh first"

POLL="${BACKLOG_LOOP_POLL_SECONDS:-20}"
SLICE="${BACKLOG_LOOP_SLICE_SECONDS:-100}"
st() { "$BL_SCRIPT_DIR/state.sh" "$@"; }
bq() { jq -r --argjson b "$1" ".batches[] | select(.id == \$b) | $2" "$BL_STATE"; }

failing() {
  gh pr checks "$1" --json name,bucket \
    --jq '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")' 2>/dev/null
}

# poll_once <pr> <polls so far>: prints green | red | pending
poll_once() {
  local state
  state="$(bl_pr_checks "$1")"
  case "$state" in
    green | red) echo "$state" ;;
    none)
      # No checks at all: fine for `ci: none` once GitHub had time to start any.
      if [ "$(bl_cfg ci)" = "none" ] && [ "$2" -ge 1 ]; then echo green; else echo pending; fi
      ;;
    *) echo pending ;;
  esac
}

if [ "${1:-}" = "--pr" ]; then
  pr="${2:-}"
  case "$pr" in '' | *[!0-9]*) bl_die "usage: ci-wait.sh --pr <number>" ;; esac
  end=$(($(date +%s) + SLICE))
  polls=0
  while :; do
    state="$(poll_once "$pr" "$polls")"
    bl_lock_touch
    [ "$state" = "pending" ] || break
    polls=$((polls + 1))
    [ $(($(date +%s) + POLL)) -le "$end" ] || break
    sleep "$POLL"
  done
  bl_log "pr=$pr checks=$state"
  echo "$state" | tr '[:lower:]' '[:upper:]'
  exit 0
fi

b="${1:-}"
case "$b" in '' | *[!0-9]*) bl_die "usage: ci-wait.sh <batch> [--rerun] | --pr <number>" ;; esac
[ -n "$(bq "$b" '.id')" ] || bl_die "unknown batch: $b"
phase="$(bq "$b" '.phase // "none"')"
pr="$(bq "$b" '.pr // empty')"

if [ "${2:-}" = "--rerun" ]; then
  [ "$phase" = "ci-rerun" ] || bl_die "batch $b is in phase '$phase'; a rerun is not due. Run next.sh."
  head="$(bl_pr_field "$pr" headRefOid)"
  count=0
  for run in $(gh run list --branch "$(bq "$b" '.branch')" --limit 20 --json databaseId,conclusion,headSha \
    --jq ".[] | select(.headSha == \"$head\" and (.conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\")) | .databaseId" 2>/dev/null); do
    if gh run rerun "$run" --failed >/dev/null 2>&1; then count=$((count + 1)); fi
  done
  st record ci-rerun "$b"
  bl_log "batch=$b reran $count failed run(s)"
  sleep "$POLL"
  printf 'RERUN: %s failed run(s) restarted for PR #%s. Run next.sh.\n' "$count" "$pr"
  exit 0
fi

if [ "$phase" != "ci" ]; then
  printf 'NOT WAITING: batch %s is in phase %s. Run next.sh.\n' "$b" "$phase"
  exit 0
fi

case "$(bl_pr_field "$pr" state)" in
  MERGED)
    st record merged "$b" "$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null)"
    printf 'MERGED: PR #%s was merged outside the loop. Run next.sh.\n' "$pr"
    exit 0
    ;;
  CLOSED)
    st reconcile
    printf 'CLOSED: PR #%s was closed outside the loop; the batch was reset. Run next.sh.\n' "$pr"
    exit 0
    ;;
esac

wait_min="$(bl_limit ci_wait_minutes)"
deadline=$(($(bq "$b" '.ci_started_at') + ${wait_min:-45} * 60))
end=$(($(date +%s) + SLICE))
while :; do
  if [ "$(bl_now)" -ge "$deadline" ]; then
    st record ci "$b" timeout
    printf 'TIMEOUT: checks on PR #%s did not finish within %s minutes. Counted as a failed attempt. Run next.sh.\n' "$pr" "${wait_min:-45}"
    exit 0
  fi
  state="$(poll_once "$pr" "$(bq "$b" '.ci_polls')")"
  bl_lock_touch
  case "$state" in
    green)
      st record ci "$b" green
      printf 'GREEN: all checks passed on PR #%s. Run next.sh.\n' "$pr"
      exit 0
      ;;
    red)
      st record ci "$b" red "$(failing "$pr")"
      printf 'RED: checks failed on PR #%s (%s). Run next.sh.\n' "$pr" "$(failing "$pr")"
      exit 0
      ;;
  esac
  if [ $(($(date +%s) + POLL)) -gt "$end" ]; then
    st record ci "$b" poll
    printf 'PENDING: checks on PR #%s are still running, %s minutes left. Run this command again.\n' \
      "$pr" "$(((deadline - $(bl_now)) / 60))"
    exit 0
  fi
  sleep "$POLL"
done
