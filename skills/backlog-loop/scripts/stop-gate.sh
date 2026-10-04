#!/usr/bin/env bash
# stop-gate.sh: Stop hook. Keeps the loop going while work remains.
#
# Allows the stop (exit 0, no decision) in every case except the last:
#   1. no active run in this repository, or the run belongs to another session
#   2. nothing left to do: writes the report
#   3. iteration or wall-clock limit hit: status halted
#   4. state hash unchanged for `stall_threshold` gate checks in a row: status stalled
#   5. any script error, missing dependency or timeout: fail open, logged
#   6. work remains and state changed: block, with the next action as reason
#
# Also allows the stop while background workers are still running, and before
# Claude Code's cap on consecutive Stop hook blocks would be hit.
# shellcheck disable=SC2016
set -u
BL_SELF=stop-gate

input="$(cat 2>/dev/null || true)"

# Rule 5: without jq nothing can be decided.
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" 2>/dev/null || exit 0; fi
bl_paths 2>/dev/null || exit 0

# Rule 1.
[ -e "$BL_STATE" ] || exit 0
if ! bl_state_ok; then
  bl_log "state file unreadable, allowing stop"
  exit 0
fi
[ "$(bl_get '.run.status' 2>/dev/null)" = "running" ] || exit 0
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
owner="$(bl_lock_owner 2>/dev/null)"
if [ -n "$session" ] && [ -n "$owner" ] && [ "$owner" != "unknown" ] && [ "$owner" != "$session" ]; then
  exit 0
fi

S="$BL_SCRIPT_DIR"
OUT="$BL_DIR/gate.out.$$"

say() { jq -n --arg m "$1" '{systemMessage: $m}'; }

decide() {
  local action_json action hash last unchanged threshold blocks cap active mode report
  action_json="$("$S/next.sh")" || return 1
  action="$(printf '%s' "$action_json" | jq -r '.action')" || return 1
  mode="$(printf '%s' "$input" | jq -r '.permission_mode // empty')"

  case "$action" in
    done | halt)
      # Rules 2 and 3. next.sh already set the status.
      report="$("$S/report.sh" 2>/dev/null)" || report=""
      [ -z "$report" ] || say "$report"
      return 0
      ;;
    preflight) return 0 ;;
    wait_worker)
      if [ "$(printf '%s' "$input" | jq '[.background_tasks[]? | select(.status != "completed" and .status != "failed")] | length')" -gt 0 ]; then
        bl_log "background workers in flight, allowing stop"
        return 0
      fi
      ;;
  esac

  # Rule 4.
  hash="$(bl_hash)" || return 1
  last="$(bl_get '.run.last_hash // ""')"
  unchanged="$(bl_get '.run.unchanged_gates')"
  threshold="$(bl_limit stall_threshold)"
  if [ "$hash" = "$last" ]; then unchanged=$((unchanged + 1)); else unchanged=0; fi
  if [ "$unchanged" -ge "${threshold:-2}" ]; then
    "$S/state.sh" record run stalled "state unchanged across $unchanged stop-gate checks; last action: $action" || return 1
    report="$("$S/report.sh" 2>/dev/null)" || report=""
    say "backlog-loop stalled: nothing changed across $unchanged checks. Run /backlog-loop --resume to continue.
$report"
    return 0
  fi

  # Stay below Claude Code's cap on consecutive Stop hook blocks (default 8).
  active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false')"
  blocks="$(bl_get '.run.gate_blocks')"
  if [ "$active" = "true" ]; then blocks=$((blocks + 1)); else blocks=1; fi
  cap="${CLAUDE_CODE_STOP_HOOK_BLOCK_CAP:-8}"
  case "$cap" in '' | *[!0-9]*) cap=8 ;; esac
  if [ "$cap" -gt 0 ] && [ "$blocks" -ge "$cap" ]; then
    "$S/state.sh" gate "$hash" "$unchanged" 0 "$mode" || return 1
    bl_log "consecutive block cap ($cap) reached, allowing stop; the run stays resumable"
    say "backlog-loop paused: the Stop hook block cap ($cap) was reached. Work remains. Run /backlog-loop to resume."
    return 0
  fi
  "$S/state.sh" gate "$hash" "$unchanged" "$blocks" "$mode" || return 1

  # Rule 6.
  bl_log "blocking stop: action=$action blocks=$blocks unchanged=$unchanged"
  jq -n --arg r "backlog-loop: work remains. Do this next, then keep following next.sh until it returns done or halt.
$action_json" '{decision: "block", reason: $r}'
}

# Rule 5: run the decision under a deadline. Anything unexpected allows the stop.
deadline="${BACKLOG_LOOP_GATE_SECONDS:-45}"
(decide >"$OUT" 2>>"$BL_LOG") &
pid=$!
start="$(date +%s)"
while kill -0 "$pid" 2>/dev/null; do
  if [ $(($(date +%s) - start)) -ge "$deadline" ]; then
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null
    bl_log "gate deadline of ${deadline}s hit, allowing stop"
    rm -f "$OUT"
    exit 0
  fi
  sleep 0.2
done
if wait "$pid" && [ -s "$OUT" ] && jq -e . "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
else
  [ ! -s "$OUT" ] || bl_log "gate produced no usable decision, allowing stop"
fi
rm -f "$OUT"
exit 0
