#!/usr/bin/env bash
# guard.sh: PreToolUse hook. While a run is active in this repository, deny
#   - force-push in any form
#   - direct push to the base branch
#   - gh pr merge with --admin, or for a PR that is not verified green
#   - deleting or hand-editing .planning/backlog-loop/state.json
# Exits 0 without a decision when no run is active.
# shellcheck disable=SC2016
set -u
BL_SELF=guard

input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" 2>/dev/null || exit 0; fi
bl_paths 2>/dev/null || exit 0
bl_run_active || exit 0
bl_lock_touch

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"

deny() {
  bl_log "denied: $1 :: $(printf '%s' "${cmd:-$tool}" | tr '\n' ' ' | cut -c1-200)"
  jq -n --arg r "backlog-loop guard: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# File tools: state.json is written by state.sh only.
case "$tool" in
  Edit | Write | NotebookEdit)
    file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    case "$file" in
      */.planning/backlog-loop/state.json) deny "state.json is written by state.sh only. Record results with: $BL_SCRIPT_DIR/state.sh record <event>" ;;
    esac
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac
[ -n "$cmd" ] || exit 0

base="$(bl_cfg base_branch)"

strip() {
  # Remove surrounding quotes from a word.
  local w="$1"
  w="${w#[\"\']}"
  w="${w%[\"\']}"
  printf '%s' "$w"
}

check_push() {
  # $@: words after "push". GIT_DIR_ARG holds a -C directory, if any.
  local w remote="" refs="" dst flags_done=0 current
  for w in "$@"; do
    w="$(strip "$w")"
    if [ "$flags_done" -eq 0 ]; then
      case "$w" in
        --) flags_done=1; continue ;;
        --force | --force-with-lease* | --force-if-includes | --mirror)
          deny "force-push is not allowed. Update a branch with a new commit, or with: gh pr update-branch <pr>" ;;
        --all | --branches) deny "pushing all branches would push $base directly" ;;
        --no-*) continue ;;
        --*) continue ;;
        -*)
          case "$w" in *f*) deny "force-push is not allowed. Update a branch with a new commit, or with: gh pr update-branch <pr>" ;; esac
          continue
          ;;
      esac
    fi
    if [ -z "$remote" ]; then remote="$w"; else refs="$refs $w"; fi
  done
  if [ -z "$refs" ]; then
    current="$(git ${GIT_DIR_ARG:+-C "$GIT_DIR_ARG"} rev-parse --abbrev-ref HEAD 2>/dev/null)"
    refs=" $current"
  fi
  for w in $refs; do
    case "$w" in +*) deny "force-push (+refspec) is not allowed" ;; esac
    dst="${w##*:}"
    if [ "$dst" = "HEAD" ]; then dst="$(git ${GIT_DIR_ARG:+-C "$GIT_DIR_ARG"} rev-parse --abbrev-ref HEAD 2>/dev/null)"; fi
    dst="${dst#refs/heads/}"
    if [ "$dst" = "$base" ]; then
      deny "direct push to the base branch '$base' is not allowed. Changes reach $base through a pull request."
    fi
  done
}

check_merge() {
  # $@: words after "gh pr merge".
  local w sel="" pr checks b verified
  for w in "$@"; do
    w="$(strip "$w")"
    case "$w" in
      --admin) deny "gh pr merge --admin bypasses branch protection and is not allowed" ;;
      -*) ;;
      *) [ -n "$sel" ] || sel="$w" ;;
    esac
  done
  if [ "$(bl_get '.run.flags.no_merge')" = "true" ]; then
    deny "this run uses --no-merge: pull requests are merged by the user"
  fi
  if [ -n "$sel" ]; then
    pr="$(gh pr view "$sel" --json number --jq .number 2>/dev/null)"
  else
    pr="$(gh pr view --json number --jq .number 2>/dev/null)"
  fi
  [ -n "$pr" ] || deny "could not identify the pull request to merge, so its checks cannot be verified"
  b="$(jq -r --argjson pr "$pr" '.batches[] | select(.pr == $pr) | .id' "$BL_STATE" | head -n 1)"
  if [ -n "$b" ]; then
    verified="$(jq -r --argjson b "$b" '.batches[] | select(.id == $b) | .premerge_sha // empty' "$BL_STATE")"
    if [ -z "$verified" ] || [ "$verified" != "$(bl_pr_field "$pr" headRefOid)" ]; then
      deny "PR #$pr (batch $b) is not verified for merge. Run: $BL_SCRIPT_DIR/verify-batch.sh $b pre-merge"
    fi
  fi
  checks="$(bl_pr_checks "$pr")"
  if [ "$checks" != "green" ]; then
    deny "checks on PR #$pr are $checks, not green. Wait with: $BL_SCRIPT_DIR/ci-wait.sh"
  fi
}

check_state_access() {
  # $1: first word, $2: whole segment
  local first="$1" seg="$2"
  case "$first" in
    "$BL_SCRIPT_DIR"/*.sh | */backlog-loop/scripts/*.sh) return 0 ;;
  esac
  case "${first##*/}" in
    cat | jq | head | tail | less | more | wc | grep | rg | ls | stat | test | "[" | cksum | shasum | file | diff | cmp | echo | printf)
      case "$seg" in *">"*) ;; *) return 0 ;; esac
      ;;
  esac
  deny "state.json is written by state.sh only. Record results with: $BL_SCRIPT_DIR/state.sh record <event>"
}

check_segment() {
  local seg="$1" first w n
  # Drop leading assignments and wrappers.
  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      command | builtin | sudo | env | time | nohup | nice | exec | xargs | then | do | else | "{" | "!") shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  first="$(strip "$1")"

  case "$seg" in
    *backlog-loop/state.json*) check_state_access "$first" "$seg" ;;
  esac

  case "${first##*/}" in
    git)
      shift
      GIT_DIR_ARG=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -C) GIT_DIR_ARG="$(strip "${2:-}")"; shift; [ $# -gt 0 ] && shift ;;
          -c | --git-dir | --work-tree | --namespace | --exec-path) shift; [ $# -gt 0 ] && shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      case "$(strip "${1:-}")" in
        push) shift; check_push "$@" ;;
        clean)
          for w in "$@"; do
            case "$w" in -*[xX]*) deny "git clean -x would delete the ignored run state in .planning/backlog-loop" ;; esac
          done
          ;;
      esac
      ;;
    gh)
      if [ "$(strip "${2:-}")" = "pr" ] && [ "$(strip "${3:-}")" = "merge" ]; then
        shift 3
        check_merge "$@"
      elif [ "$(strip "${2:-}")" = "api" ]; then
        case "$seg" in
          */pulls/*/merge*) deny "merge pull requests with gh pr merge so the checks can be verified" ;;
        esac
      fi
      ;;
    rm | rmdir | mv | unlink | shred | truncate)
      n=0
      for w in "$@"; do
        n=$((n + 1))
        [ "$n" -gt 1 ] || continue
        w="$(strip "$w")"
        w="${w%/}"
        case "$w" in
          .planning | */.planning | .planning/backlog-loop | */.planning/backlog-loop | "$BL_DIR")
            deny "the run state in .planning/backlog-loop must not be removed while a run is active" ;;
        esac
      done
      ;;
  esac
  return 0
}

# Redirects into the state file, wherever they appear.
if printf '%s' "$cmd" | grep -Eq '>[>|]?[[:space:]]*[^[:space:]]*backlog-loop/state\.json'; then
  deny "state.json is written by state.sh only. Record results with: $BL_SCRIPT_DIR/state.sh record <event>"
fi

# Split on shell separators. Not quote-aware on purpose: a false positive is a
# denied command that can be rephrased, a false negative is a force-push.
segments="$(printf '%s\n' "$cmd" | sed -e 's/\$(/\
/g' -e 's/[;&|`()]/\
/g')"
while IFS= read -r segment; do
  case "$segment" in *[![:space:]]*) check_segment "$segment" ;; esac
done <<EOT
$segments
EOT
exit 0
