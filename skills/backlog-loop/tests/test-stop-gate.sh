#!/usr/bin/env bash
# stop-gate.sh: one test per rule of the Stop hook, plus the fail-open cases.
# shellcheck disable=SC2016
set -u
# shellcheck source=helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export BACKLOG_LOOP_DRY_RUN=1
export BACKLOG_LOOP_NOW=2000
unset CLAUDE_CODE_STOP_HOOK_BLOCK_CAP

DEFS='
def merged($b): .batches |= map(if .id == $b then .status = "merged" | .phase = null | .pr = (200 + $b) else . end)
  | .items |= map(if .batch == $b then .status = "merged" else . end);
'

# gate [extra hook input JSON]: prints the hook's stdout, sets RC.
gate() {
  local extra="${1:-}"
  [ -n "$extra" ] || extra='{}'
  OUT="$(jq -n --arg cwd "$BACKLOG_LOOP_ROOT" --argjson extra "$extra" \
    '{session_id: "dry", cwd: $cwd, permission_mode: "auto", hook_event_name: "Stop", stop_hook_active: false} + $extra' |
    "$S/stop-gate.sh")"
  RC=$?
}
decision() {
  if [ -z "$OUT" ]; then echo allow; else printf '%s' "$OUT" | jq -r '.decision // "allow"'; fi
}

echo "rule 1: no active run -> allow"
t_tmp
BACKLOG_LOOP_ROOT="$T_TMP/none"
export BACKLOG_LOOP_ROOT
mkdir -p "$BACKLOG_LOOP_ROOT"
gate
assert_eq "no state: exit 0" "0" "$RC"
assert_empty "no state: no output" "$OUT"
use_state base.json '.run.status = "done"'
gate
assert_empty "finished run: no output" "$OUT"
use_state base.json '.run.status = "halted"'
gate
assert_empty "halted run: no output" "$OUT"
use_state base.json
echo "someone-else" >"$STATE_DIR/lock"
gate
assert_empty "run owned by another session: no output" "$OUT"
assert_eq "another session's run is left alone" "0" "$(sget '.run.total_iterations')"

echo "rule 2: nothing left to do -> allow and report"
use_state base.json "$DEFS merged(1) | merged(2) | merged(3)"
gate
assert_eq "all merged: allowed" "allow" "$(decision)"
assert_eq "all merged: status done" "done" "$(sget '.run.status')"
assert_eq "all merged: report written" "yes" "$([ -s "$STATE_DIR/report.md" ] && echo yes)"
assert_contains "all merged: report shown to the user" "Backlog loop finished: done" "$(printf '%s' "$OUT" | jq -r '.systemMessage')"

echo "rule 3: limits -> allow, status halted"
use_state base.json '.run.iterations = 100'
gate
assert_eq "iteration limit: allowed" "allow" "$(decision)"
assert_eq "iteration limit: status halted" "halted" "$(sget '.run.status')"
use_state base.json '.run.segment_started_at = (2000 - 12 * 3600)'
gate
assert_eq "wall-clock limit: allowed" "allow" "$(decision)"
assert_eq "wall-clock limit: status halted" "halted" "$(sget '.run.status')"

echo "rule 4: state unchanged twice in a row -> stalled, allow"
use_state base.json
gate
assert_eq "first check: blocks" "block" "$(decision)"
gate '{"stop_hook_active": true}'
assert_eq "second check, unchanged once: still blocks" "block" "$(decision)"
assert_eq "unchanged counter is 1" "1" "$(sget '.run.unchanged_gates')"
gate '{"stop_hook_active": true}'
assert_eq "third check, unchanged twice: allowed" "allow" "$(decision)"
assert_eq "status is stalled" "stalled" "$(sget '.run.status')"
assert_contains "the stall is explained" "stalled" "$(printf '%s' "$OUT" | jq -r '.systemMessage')"
use_state base.json
gate
"$S/state.sh" record worker-started 1 >/dev/null
"$S/state.sh" record worker-failed 1 --reason x >/dev/null
gate '{"stop_hook_active": true}'
assert_eq "progress between checks resets the counter" "block/0" "$(decision)/$(sget '.run.unchanged_gates')"

echo "rule 5: errors -> fail open"
use_state base.json
echo '{"run": {"status": "running"' >"$STATE"
gate
assert_eq "corrupt state: exit 0" "0" "$RC"
assert_empty "corrupt state: no decision" "$OUT"
use_state base.json
farm="$T_TMP/no-jq-bin"
mkdir -p "$farm"
for tool in cat dirname; do ln -sf "$(command -v "$tool")" "$farm/$tool"; done
OUT="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$BACKLOG_LOOP_ROOT" | PATH="$farm" "$(command -v bash)" "$S/stop-gate.sh")"
RC=$?
assert_eq "missing jq: exit 0" "0" "$RC"
assert_empty "missing jq: no decision" "$OUT"
BACKLOG_LOOP_GATE_SECONDS=0 gate
assert_eq "timeout: exit 0" "0" "$RC"
assert_empty "timeout: no decision" "$OUT"
assert_contains "timeout is logged" "gate deadline" "$(cat "$STATE_DIR/run.log")"
use_state base.json
OUT="$(printf 'this is not json' | "$S/stop-gate.sh")"
RC=$?
assert_eq "garbage hook input: exit 0" "0" "$RC"

echo "rule 6: work remains and state changed -> block with the next action"
use_state base.json
gate
assert_eq "exit status is 0 when blocking" "0" "$RC"
assert_eq "decision is block" "block" "$(decision)"
reason="$(printf '%s' "$OUT" | jq -r '.reason')"
assert_contains "reason carries the next.sh action" '"action": "implement_batch"' "$reason"
assert_contains "reason carries concrete commands" "state.sh record worker-started 1" "$reason"
assert_eq "the gate call counts as an iteration" "1" "$(sget '.run.total_iterations')"
assert_eq "permission mode is recorded" "auto" "$(sget '.run.permission_mode')"

echo "background workers and the block cap"
use_state base.json '.batches |= map(if .id < 3 then .status = "in-progress" | .phase = "working" | .worker_started_at = 1990 else . end)'
gate '{"background_tasks": [{"id": "t1", "type": "subagent", "status": "running"}]}'
assert_eq "workers in the background: allowed" "allow" "$(decision)"
assert_eq "waiting for workers is not a stall" "running/0" "$(sget '"\(.run.status)/\(.run.unchanged_gates)"')"
gate '{"background_tasks": []}'
assert_eq "no worker actually running: blocks" "block" "$(decision)"
use_state base.json
export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=3
gate
"$S/state.sh" record worker-started 1 >/dev/null
gate '{"stop_hook_active": true}'
assert_eq "second consecutive block is below the cap" "block/2" "$(decision)/$(sget '.run.gate_blocks')"
"$S/state.sh" record worker-failed 1 --reason x >/dev/null
gate '{"stop_hook_active": true}'
assert_eq "the block that would hit the cap is not issued" "allow" "$(decision)"
assert_eq "the run stays resumable" "running" "$(sget '.run.status')"
assert_contains "the user is told how to resume" "/backlog-loop" "$(printf '%s' "$OUT" | jq -r '.systemMessage')"
export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=0
use_state base.json '.run.gate_blocks = 50'
gate '{"stop_hook_active": true}'
assert_eq "cap 0 disables the limit" "block" "$(decision)"
unset CLAUDE_CODE_STOP_HOOK_BLOCK_CAP

t_summary
