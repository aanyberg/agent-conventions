#!/usr/bin/env bash
# hooks.sh: the two hooks of backlog-loop. Both do nothing unless a run is
# active in the repository, and both fail open: an error allows the action.
#
#   hooks.sh stop    Stop hook. Sends the agent back to `loop.sh next` while
#                    the run is unfinished and no background worker is running.
#   hooks.sh guard   PreToolUse hook. Denies what only the loop may do, or
#                    nobody: merging, force-pushing, pushing to the base
#                    branch, editing or deleting the run's state.
# shellcheck disable=SC2016
set -u

mode="${1:-}"
input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$SCRIPT_DIR/loop.sh"

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" 2>/dev/null || exit 0; fi
top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "$common" in /*) ;; *) common="$top/$common" ;; esac
ROOT="$(cd "$common/.." 2>/dev/null && pwd -P)" || exit 0
STATE="$ROOT/.planning/backlog-loop/state.json"
[ -f "$STATE" ] || exit 0
[ "$(jq -r '.run.status // empty' "$STATE" 2>/dev/null)" = "running" ] || exit 0

stop_hook() {
  local session owner hash last unchanged blocks active cap
  session="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  owner="$(jq -r '.run.session // empty' "$STATE")"
  if [ -n "$session" ] && [ -n "$owner" ] && [ "$owner" != "unknown" ] && [ "$owner" != "$session" ]; then
    exit 0
  fi
  # A background worker's notification brings the agent back.
  if [ "$(printf '%s' "$input" | jq '[.background_tasks[]? | select(.status != "completed" and .status != "failed")] | length')" -gt 0 ]; then
    exit 0
  fi

  # Stalled: the agent tried to stop three times without `next` having run.
  hash="$(jq -c '[.items, .batches, .run.status, .run.ticks]' "$STATE" | cksum | cut -d' ' -f1)"
  last="$(jq -r '.run.gate.hash // ""' "$STATE")"
  unchanged="$(jq -r '.run.gate.unchanged // 0' "$STATE")"
  blocks="$(jq -r '.run.gate.blocks // 0' "$STATE")"
  if [ "$hash" = "$last" ]; then unchanged=$((unchanged + 1)); else unchanged=0; fi
  if [ "$unchanged" -ge 3 ]; then
    "$LOOP" _halt "stalled: the loop was not advanced across $unchanged stop checks, usually because a command keeps being denied. See .planning/backlog-loop/run.log, then run /backlog-loop execute." >/dev/null 2>&1
    jq -n '{systemMessage: "backlog-loop stalled and was halted. Run /backlog-loop execute to continue."}'
    exit 0
  fi

  # Claude Code ends the turn after a number of Stop hook blocks in a row.
  # Stay one below, and leave the run resumable.
  active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false')"
  if [ "$active" = "true" ]; then blocks=$((blocks + 1)); else blocks=1; fi
  cap="${CLAUDE_CODE_STOP_HOOK_BLOCK_CAP:-8}"
  case "$cap" in '' | *[!0-9]*) cap=8 ;; esac
  if [ "$cap" -gt 0 ] && [ "$blocks" -ge "$cap" ]; then
    "$LOOP" _gate "$hash" "$unchanged" 0 >/dev/null 2>&1
    jq -n '{systemMessage: "backlog-loop paused: the Stop hook block cap was reached while work remains. Run /backlog-loop execute to continue."}'
    exit 0
  fi
  "$LOOP" _gate "$hash" "$unchanged" "$blocks" >/dev/null 2>&1 || exit 0

  jq -n --arg r "backlog-loop: the run is not finished. Run: $LOOP next
Do what it returns, and repeat until it returns done or halt." '{decision: "block", reason: $r}'
}

deny() {
  jq -n --arg r "backlog-loop guard: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

strip() {
  # Remove surrounding quotes from a word.
  local w="$1"
  w="${w#[\"\']}"
  w="${w%[\"\']}"
  printf '%s' "$w"
}

check_push() {
  # $@: the words after "git push".
  local w remote="" refs="" dst base
  base="$(jq -r '.config.base // "main"' "$STATE")"
  for w in "$@"; do
    w="$(strip "$w")"
    case "$w" in
      --force | --force-with-lease* | --force-if-includes | --mirror)
        deny "force-push is not allowed. Add a new commit instead." ;;
      --all | --branches) deny "pushing all branches would push $base directly" ;;
      --delete | -d) return 0 ;;
      --*) continue ;;
      -*)
        case "$w" in *f*) deny "force-push is not allowed. Add a new commit instead." ;; esac
        continue
        ;;
    esac
    if [ -z "$remote" ]; then remote="$w"; else refs="$refs $w"; fi
  done
  [ -n "$refs" ] || refs=" $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  for w in $refs; do
    case "$w" in +*) deny "force-push (+refspec) is not allowed" ;; esac
    dst="${w##*:}"
    [ "$dst" != "HEAD" ] || dst="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    dst="${dst#refs/heads/}"
    [ "$dst" != "$base" ] || deny "direct push to the base branch '$base' is not allowed. Changes reach it through the batch's pull request."
  done
}

check_segment() {
  local seg="$1" first w
  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      command | builtin | sudo | env | time | nohup | exec | xargs | then | do | else | "{" | "!") shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  first="$(strip "$1")"
  case "${first##*/}" in
    git)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          -C | -c | --git-dir | --work-tree) shift; [ $# -eq 0 ] || shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      case "$(strip "${1:-}")" in
        push) shift; check_push "$@" ;;
        clean)
          for w in "$@"; do
            case "$w" in -*[xX]*) deny "git clean -x would delete the run's state in .planning/backlog-loop" ;; esac
          done
          ;;
      esac
      ;;
    gh)
      if [ "$(strip "${2:-}")" = "pr" ] && [ "$(strip "${3:-}")" = "merge" ]; then
        deny "the loop merges a pull request itself, after it has verified it. Run: $LOOP next"
      fi
      case "$seg" in
        *api*/pulls/*/merge*) deny "the loop merges a pull request itself, after it has verified it. Run: $LOOP next" ;;
      esac
      ;;
    rm | rmdir | mv | unlink | truncate)
      shift
      for w in "$@"; do
        w="$(strip "$w")"
        case "${w%/}" in
          .planning | */.planning | .planning/backlog-loop | */.planning/backlog-loop | *backlog-loop/state.json | *backlog-loop/lock)
            deny "the run's state in .planning/backlog-loop must stay while a run is active" ;;
        esac
      done
      ;;
  esac
  return 0
}

guard_hook() {
  local tool cmd file segments segment
  tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
  case "$tool" in
    Edit | Write | NotebookEdit)
      file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
      case "$file" in
        */.planning/backlog-loop/state.json) deny "state.json is written by loop.sh only. Record results with: $LOOP record <event>" ;;
      esac
      exit 0
      ;;
    Bash) ;;
    *) exit 0 ;;
  esac
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
  [ -n "$cmd" ] || exit 0
  if printf '%s' "$cmd" | grep -Eq '>[>|]?[[:space:]]*[^[:space:]]*backlog-loop/state\.json'; then
    deny "state.json is written by loop.sh only. Record results with: $LOOP record <event>"
  fi
  # Split on shell separators. Not quote-aware on purpose: a false positive is
  # a denied command that can be rephrased, a false negative is a force-push.
  segments="$(printf '%s\n' "$cmd" | sed -e 's/\$(/\
/g' -e 's/[;&|`()]/\
/g')"
  while IFS= read -r segment; do
    case "$segment" in *[![:space:]]*) check_segment "$segment" ;; esac
  done <<EOT
$segments
EOT
}

case "$mode" in
  stop) stop_hook ;;
  guard) guard_hook ;;
esac
exit 0
