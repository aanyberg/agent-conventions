#!/usr/bin/env bash
# report.sh: print the run summary and write it to report.md.
# shellcheck disable=SC2016
set -u
BL_SELF=report
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bl_paths || bl_die "not inside a git repository"
bl_state_ok || bl_die "no usable state to report on"

text="$(jq -r --arg dir ".planning/backlog-loop" '
  def ref($i): (if .config.source == "github" then "#" else "" end) + $i;
  . as $s
  | (if .config.source == "github" then "#" else "" end) as $p
  | [.items[] | select(.status == "merged")] as $merged
  | [.items[] | select(.status == "blocked")] as $blocked
  | [.batches[] | select(.status == "pr-ready")] as $ready
  | [$ready[].items[]] as $ready_items
  | [.items[] | select(.status == "todo" or .status == "in-progress") | select(.id as $i | any($ready_items[]; . == $i) | not)] as $left
  | [.batches | sort_by(.id)[] | select(.pr != null and (.status == "merged" or .status == "pr-ready"))] as $prs
  | (if .run.status == "done" then "Backlog loop finished: done"
     elif .run.status == "running" then "Backlog loop status: running"
     else "Backlog loop \(.run.status): \(.run.halt_reason // "no reason recorded")" end),
    "Items:   \($merged | length) merged, \($blocked | length) blocked, \($left | length) remaining"
      + (if ($ready_items | length) > 0 then ", \($ready_items | length) awaiting your merge" else "" end),
    (if ($prs | length) > 0
     then "PRs:     " + ($prs | map("#\(.pr)") | join(" ")) + " (\($prs | length) PRs for \([$prs[] | select(.kind != "status") | .items[]] | length) items)"
     else "PRs:     none" end),
    (if ($ready | length) > 0 then "Merge:   " + ($ready | map("#\(.pr)") | join(" ")) + " are green and wait for you" else empty end),
    ($blocked[] | "Blocked: \($p)\(.id) \"\(.title)\"",
        "         Reason: \(.blocked_reason.why // "unknown")",
        (if .blocked_reason.needs then "         Needs:  \(.blocked_reason.needs)" else empty end)),
    (.items[] | select(.needs_review) | "Review:  \($p)\(.id) decided with low confidence, see \(.decision)"),
    ([.batches | sort_by(.id)[] | select(.fixes > 0 or .ci_reruns > 0 or .requeues > 0)
        | "batch \(.id) (" + ([ (if .fixes > 0 then "\(.fixes) fix" + (if .fixes > 1 then "es" else "" end) else empty end),
                               (if .ci_reruns > 0 then "\(.ci_reruns) CI rerun" + (if .ci_reruns > 1 then "s" else "" end) else empty end),
                               (if .requeues > 0 then "\(.requeues) re-queue" else empty end) ] | join(", ")) + ")"]
      | if length > 0 then "Retries: " + join(", ") else empty end),
    "Report:  \($dir)/report.md"' "$BL_STATE")" || bl_die "could not build the report"

{
  printf '# Backlog loop report\n\n'
  printf 'Run %s, started %s, %s iterations. Written %s.\n\n' "$(bl_get '.run.id')" \
    "$(bl_get '.run.started_iso')" "$(bl_get '.run.total_iterations')" "$(bl_iso)"
  printf '```text\n%s\n```\n\n## Batches\n\n' "$text"
  jq -r "$BL_JQ_MODEL"'.config as $cfg | .batches | sort_by(.id)[]
    | "- Batch \(.id) \"\(.theme)\" (\(tier_model($cfg; batch_tier))): \(.status)"
    + (if .pr then ", PR #\(.pr)" else "" end)
    + (if .revert_pr then ", reverted in PR #\(.revert_pr)" else "" end)
    + (if .last_error and .status != "merged" then ". Last error: \(.last_error)" else "" end)' "$BL_STATE"
} >"$BL_DIR/report.md"

bl_log "report written status=$(bl_get '.run.status')"
printf '%s\n' "$text"
# A finished run keeps its report and state, not its logs and working files.
"$BL_SCRIPT_DIR/state.sh" purge-logs
