#!/usr/bin/env bash
# loop.sh: the backlog-loop harness. It owns the run's state and does every
# mechanical step itself: integrate, push, open the pull request, poll CI,
# rerun, update from base, merge, verify. The orchestrating agent only gets
# the steps that need judgement, one action at a time, from `next`.
#
#   loop.sh start [--session ID] [--no-merge] [plan] [BATCH...]
#   loop.sh next
#   loop.sh plan-apply
#   loop.sh record started <item>... | --batch <batch>
#   loop.sh record item <item> [--unclear Q | --blocker TEXT | --failed TEXT]
#   loop.sh record decision <item> --confidence high|medium|low [--needs TEXT]
#   loop.sh record applied <item> [--failed TEXT]
#   loop.sh record marked <batch> [--failed TEXT]
#   loop.sh record fixed <batch> [--failed TEXT]
#   loop.sh prompt item|apply|research <item>
#   loop.sh prompt fix|conflict|status <batch>
#   loop.sh report | status
# shellcheck disable=SC2016
set -u

# Logical paths, so that the commands printed for the agent match the path the
# skill was installed under (often a symlink) and its permission rules.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SELF="$SCRIPT_DIR/loop.sh"

POLL="${BACKLOG_LOOP_POLL_SECONDS:-20}"
SLICE="${BACKLOG_LOOP_SLICE_SECONDS:-100}"
SETTLE="${BACKLOG_LOOP_SETTLE_SECONDS:-30}"
GRACE="${BACKLOG_LOOP_CI_GRACE_SECONDS:-300}"
LOCK_STALE="${BACKLOG_LOOP_LOCK_STALE_SECONDS:-900}"
ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
CHANGED=0
FAILED_CHECKS=""

die() {
  printf 'backlog-loop: %s\n' "$*" >&2
  exit 1
}

now() { date +%s; }

paths() {
  local top common
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
  common="$(git -C "$top" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$top/$common" ;; esac
  GIT_COMMON="$common"
  ROOT="$(cd "$common/.." && pwd -P)"
  DIR="$ROOT/.planning/backlog-loop"
  STATE="$DIR/state.json"
  LOG="$DIR/run.log"
  LOCK="$DIR/lock"
}

log() {
  if [ -d "$DIR" ]; then printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"; fi
}

g() { git -C "$ROOT" "$@"; }
st() { jq -r "$@" "$STATE"; }

up() {
  if jq "$@" "$STATE" >"$STATE.tmp.$$"; then
    mv -f "$STATE.tmp.$$" "$STATE"
  else
    rm -f "$STATE.tmp.$$"
    die "could not update the state file"
  fi
}

# bget <batch> <filter>; bup <batch> <update> [jq args]; same for items.
bget() { st --arg b "$1" ".batches[] | select(.name == \$b) | $2"; }
bup() {
  local b="$1" f="$2"
  shift 2
  up --arg b "$b" "$@" "(.batches[] | select(.name == \$b)) |= ($f)"
}
iget() { st --arg i "$1" ".items[\$i] | $2"; }
iup() {
  local i="$1" f="$2"
  shift 2
  up --arg i "$i" "$@" ".items[\$i] |= ($f)"
}
lim() { st ".config.limits.$1"; }

load() {
  paths
  [ -f "$STATE" ] || die "no backlog-loop state here. Start with /backlog-loop."
  jq -e . "$STATE" >/dev/null 2>&1 || die "the state file is not valid JSON: $STATE"
  BASE="$(st .config.base)"
  METHOD="$(st .config.merge_method)"
  SOURCE="$(st '.config.source // "github"')"
}

running() { [ "$(st .run.status)" = "running" ]; }
need_running() { running || die "no run is active. Start one with /backlog-loop."; }

# --- lock -----------------------------------------------------------------

lock_write() { printf '%s\n%s\n' "$1" "$(now)" >"$LOCK"; }
lock_touch() {
  local owner
  [ -f "$LOCK" ] || return 0
  owner="$(sed -n 1p "$LOCK")"
  lock_write "$owner"
}
lock_fresh() {
  local t
  [ -f "$LOCK" ] || return 1
  t="$(sed -n 2p "$LOCK")"
  case "$t" in '' | *[!0-9]*) return 1 ;; esac
  [ $(($(now) - t)) -lt "$LOCK_STALE" ]
}

# --- configuration --------------------------------------------------------

# Lines "- key: value" of the "## Backlog loop" section in the project docs.
config_lines() {
  local f
  for f in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
    [ -f "$ROOT/$f" ] || continue
    awk '
      /^##[ \t]/ { on = (tolower($0) ~ /^##[ \t]+backlog loop[ \t]*$/); next }
      on && /^[ \t]*-[ \t]*[a-z-]+:/ { sub(/^[ \t]*-[ \t]*/, ""); print }
    ' "$ROOT/$f"
  done
}

cfg() {
  # cfg <key> [default]
  local v
  v="$(printf '%s\n' "$CONFIG_LINES" | awk -v k="$1" '
    index($0, k ":") == 1 { v = substr($0, length(k) + 2); gsub(/^[ \t`]+|[ \t`]+$/, "", v); print v; exit }')"
  printf '%s' "${v:-${2:-}}"
}

cfg_num() {
  local v
  v="$(cfg "$1" "$2")"
  case "$v" in '' | *[!0-9]*) die "configuration: $1 must be a number, got '$v'" ;; esac
  printf '%s' "$v"
}

build_config() {
  local repo base method ci
  CONFIG_LINES="$(config_lines)"
  repo="$(gh repo view --json nameWithOwner,defaultBranchRef 2>/dev/null)" ||
    die "gh cannot read this repository. Check 'gh auth status' and the origin remote."
  base="$(cfg base-branch "$(printf '%s' "$repo" | jq -r '.defaultBranchRef.name // "main"')")"
  method="$(cfg merge-method squash)"
  case "$method" in squash | merge | rebase) ;; *) die "configuration: merge-method must be squash, merge or rebase" ;; esac
  ci="$(cfg ci required)"
  case "$ci" in required | optional) ;; *) die "configuration: ci must be required or optional" ;; esac
  jq -n \
    --arg repo "$(printf '%s' "$repo" | jq -r .nameWithOwner)" --arg base "$base" --arg method "$method" \
    --arg ci "$ci" --arg source "$(cfg source)" --arg backlog "$(cfg path)" \
    --arg ml "$(cfg model-light haiku)" --arg ms "$(cfg model-standard sonnet)" \
    --arg mc "$(cfg model-complex opus)" --arg mr "$(cfg model-research sonnet)" \
    --argjson pb "$(cfg_num parallel-batches 3)" --argjson pw "$(cfg_num parallel-workers 6)" \
    --argjson ma "$(cfg_num max-attempts 2)" --argjson mf "$(cfg_num max-fixes 2)" \
    --argjson cm "$(cfg_num ci-wait-minutes 45)" --argjson wm "$(cfg_num worker-minutes 90)" \
    --argjson vm "$(cfg_num verify-minutes 20)" --argjson mh "$(cfg_num max-hours 12)" \
    '{repo: $repo, base: $base, merge_method: $method, ci: $ci,
      source_cfg: (if $source == "" then null else $source end),
      backlog_cfg: (if $backlog == "" then null else $backlog end),
      models: {light: $ml, standard: $ms, complex: $mc, research: $mr},
      limits: {parallel_batches: $pb, parallel_workers: $pw, max_attempts: $ma, max_fixes: $mf,
               ci_minutes: $cm, worker_minutes: $wm, verify_minutes: $vm, max_hours: $mh}}'
}

# --- GitHub ---------------------------------------------------------------

pr_json() { gh pr view "$1" --json state,mergeable,headRefOid,mergeCommit 2>/dev/null; }

# pr_checks <pr>: green | red | pending | none. Sets FAILED_CHECKS.
pr_checks() {
  local out
  out="$(gh pr checks "$1" --json name,bucket 2>/dev/null)"
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || out='[]'
  FAILED_CHECKS="$(printf '%s' "$out" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")')"
  printf '%s' "$out" | jq -r '
    if length == 0 then "none"
    elif any(.[]; .bucket == "pending") then "pending"
    elif any(.[]; .bucket == "fail" or .bucket == "cancel") then "red"
    else "green" end'
}

# commit_checks <sha>: the same four answers for CI on a commit of the base branch.
commit_checks() {
  local out
  out="$(gh api "repos/$(st .config.repo)/commits/$1/check-runs" 2>/dev/null)"
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || out='{}'
  printf '%s' "$out" | jq -r '
    (.check_runs // []) as $r
    | if ($r | length) == 0 then "none"
      elif any($r[]; .status != "completed") then "pending"
      elif any($r[]; .conclusion as $c | ["failure", "timed_out", "cancelled", "startup_failure", "action_required"] | index($c)) then "red"
      else "green" end'
}

rerun_failed() {
  # rerun_failed <sha>: rerun the failed jobs of every failed run on a commit.
  local ids id
  ids="$(gh run list --commit "$1" --json databaseId,conclusion \
    --jq '.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled") | .databaseId' 2>/dev/null)"
  [ -n "$ids" ] || return 1
  for id in $ids; do
    gh run rerun "$id" --failed >/dev/null 2>&1 || return 1
  done
}

# --- run and item transitions ---------------------------------------------

write_report() { cmd_report >"$DIR/report.md" 2>/dev/null || true; }

finish_run() {
  up '.run.status = "done" | .run.reason = null'
  rm -f "$LOCK"
  log "run done"
  write_report
  CHANGED=1
}

halt_run() {
  up --arg r "$1" '.run.status = "halted" | .run.reason = $r'
  rm -f "$LOCK"
  log "run halted: $1"
  write_report
  CHANGED=1
}

aside_item() {
  # aside_item <item> <why> [needs]
  local id="$1" why="$2" needs="${3:-}"
  iup "$id" '.status = "aside" | .applied = false | .reason = $r | .needs = (if $n == "" then null else $n end) | .since = null' \
    --arg r "$why" --arg n "$needs"
  log "item $id set aside: $why"
  if [ "$SOURCE" = "github" ]; then
    case "$id" in
      *[!0-9]*) ;;
      *) gh issue comment "$id" --body "backlog-loop set this item aside.

Why: $why${needs:+
Needs: $needs}" >/dev/null 2>&1 || log "could not comment on issue $id" ;;
    esac
  fi
}

fail_item() {
  # fail_item <item> <why>: count an attempt; set aside when none are left.
  local id="$1" why="$2" attempts
  attempts=$(($(iget "$id" .attempts) + 1))
  iup "$id" '.attempts = $a | .since = null' --argjson a "$attempts"
  log "item $id failed (attempt $attempts): $why"
  if [ "$attempts" -ge "$(lim max_attempts)" ]; then
    aside_item "$id" "$attempts attempts failed. Last: $why" "a look at why the worker cannot finish it"
  else
    iup "$id" '.status = "todo"'
  fi
}

# item_commit <item>: prints the sha when the item's branch holds exactly one
# commit on top of the base branch that carries the item's trailer.
item_commit() {
  local branch
  branch="$(iget "$1" '.branch // empty')"
  [ -n "$branch" ] || return 1
  g rev-parse -q --verify "refs/heads/$branch" >/dev/null || return 1
  [ "$(g rev-list --count "origin/$BASE..$branch")" = "1" ] || return 1
  g log -1 --format=%B "$branch" | grep -Fqx "Backlog-Item: $1" || return 1
  g rev-parse "$branch"
}

batch_aside() {
  # batch_aside <batch> <why>
  local b="$1" why="$2" pr
  pr="$(bget "$b" '.pr // empty')"
  bup "$b" '.status = "aside" | .phase = null | .worker_since = null | .reason = $r' --arg r "$why"
  log "batch $b set aside: $why"
  if [ -n "$pr" ]; then
    gh pr comment "$pr" --body "backlog-loop set this batch aside: $why" >/dev/null 2>&1 || true
  fi
  CHANGED=1
}

enter_ci() {
  local t
  t="$(now)"
  bup "$1" '.phase = "ci" | .worker_since = null | .ci_since = $t | .ci_deadline = ($t + $m * 60) | .reruns = 0 | .rerun_until = 0' \
    --argjson t "$t" --argjson m "$(lim ci_minutes)"
  CHANGED=1
}

to_fix() {
  # to_fix <batch> <what failed>
  local b="$1" why="$2" fixes
  fixes="$(bget "$b" .fixes)"
  if [ "$fixes" -ge "$(lim max_fixes)" ]; then
    batch_aside "$b" "CI is still red after $fixes fix attempts: $why"
    return
  fi
  bup "$b" '.phase = "fix" | .error = $e | .fix_base = $s | .worker_since = null' \
    --arg e "$why" --arg s "$(g rev-parse -q --verify "refs/remotes/origin/$(bget "$b" .branch)" 2>/dev/null)"
  log "batch $b needs a fix: $why"
  CHANGED=1
}

to_conflict() {
  local b="$1"
  if [ "$(bget "$b" .conflicts)" -ge 1 ]; then
    batch_aside "$b" "it conflicts with the base branch again after one resolution"
    return
  fi
  bup "$b" '.phase = "conflict" | .conflicts += 1 | .fix_base = $s | .worker_since = null' \
    --arg s "$(g rev-parse -q --verify "refs/remotes/origin/$(bget "$b" .branch)" 2>/dev/null)"
  log "batch $b conflicts with $BASE"
  CHANGED=1
}

batch_items() {
  # batch_items <batch> <jq condition on the item>: ids in plan order
  st --arg b "$1" ". as \$s | .batches[] | select(.name == \$b) | .items[] | \$s.items[.] | select($2) | .id"
}

# --- advancing a batch ----------------------------------------------------

integrate() {
  # Put the built items of a batch onto a fresh batch branch and push it.
  local b="$1" tries branch tmp wt id sha head fails
  tries=$(($(bget "$b" .tries) + 1))
  branch="backlog-loop/$b/batch-t$tries"
  g fetch -q origin "$BASE" 2>/dev/null
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/backlog-loop.XXXXXX")"
  wt="$tmp/w"
  if ! g worktree add -q --detach "$wt" "origin/$BASE" >/dev/null 2>&1; then
    rm -rf "$tmp"
    log "batch $b: could not create the integration worktree"
    return
  fi
  for id in $(batch_items "$b" '.status == "built"'); do
    sha="$(iget "$id" .sha)"
    if git -C "$wt" cherry-pick "$sha" >/dev/null 2>&1; then
      iup "$id" '.applied = true'
    else
      git -C "$wt" cherry-pick --abort >/dev/null 2>&1
      iup "$id" '.status = "conflict" | .applied = false'
      log "batch $b: item $id conflicts with the items before it"
    fi
  done
  head="$(git -C "$wt" rev-parse HEAD)"
  g worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "$tmp"
  g branch -q -f "$branch" "$head"
  bup "$b" '.tries = $t | .branch = $br' --argjson t "$tries" --arg br "$branch"
  if ! g push -q origin "$branch" >/dev/null 2>&1; then
    fails=$(($(bget "$b" '.push_fails // 0') + 1))
    bup "$b" '.push_fails = $f' --argjson f "$fails"
    # Items go back to "built" so the next call integrates again.
    for id in $(batch_items "$b" '.status == "conflict" or .applied'); do iup "$id" '.status = "built" | .applied = false'; done
    log "batch $b: push of $branch failed ($fails)"
    [ "$fails" -lt 3 ] || halt_run "cannot push to origin (branch $branch). Check your access, then run /backlog-loop."
    return
  fi
  bup "$b" '.phase = "apply"'
  g fetch -q origin "$branch" 2>/dev/null
  log "batch $b integrated on $branch"
  CHANGED=1
}

adv_implement() {
  local b="$1"
  [ -z "$(batch_items "$b" '.status == "todo" or .status == "working" or .status == "researching"')" ] || return 0
  if [ -z "$(batch_items "$b" '.status == "built"')" ]; then
    batch_aside "$b" "none of its items could be built"
    return
  fi
  integrate "$b"
}

adv_apply() {
  local b="$1"
  [ -z "$(batch_items "$b" '.status == "conflict"')" ] || return 0
  if [ -z "$(batch_items "$b" '.applied')" ]; then
    batch_aside "$b" "none of its items could be built"
    return
  fi
  if [ "$SOURCE" = "file" ] && [ "$(bget "$b" '.marked // false')" = "false" ]; then
    bup "$b" '.phase = "status" | .worker_since = null'
  else
    bup "$b" '.phase = "pr" | .worker_since = null'
  fi
  CHANGED=1
}

pr_body() {
  # pr_body <batch> [ids to leave out]
  st --arg b "$1" --arg skip "${2:-}" '
    . as $s | (.batches[] | select(.name == $b)) as $bt
    | [$bt.items[] | $s.items[.] | select(.id as $i | ($skip | split(" ") | index($i)) | not)] as $its
    | (if ($bt.rationale // "") != "" then $bt.rationale, "" else empty end),
      "## Items", "",
      ($its[] | select(.applied)
        | if $s.config.source == "github" and (.id | test("^[0-9]+$")) then "- Closes #\(.id): \(.title)" else "- \(.id): \(.title)" end),
      (if any($its[]; .applied and .decision != null) then
         "", "## Decided by research", "",
         ($its[] | select(.applied and .decision != null) | "- \(.id) (\(.decision) confidence): \(.choice // "see the decision record")")
       else empty end),
      "", "Batch \($b) of the backlog loop."'
}

adv_pr() {
  local b="$1" body url pr fails
  body="$DIR/pr-body.$$"
  pr_body "$b" >"$body"
  if url="$(gh pr create --base "$BASE" --head "$(bget "$b" .branch)" --title "$(bget "$b" .title)" --body-file "$body" 2>>"$LOG")"; then
    rm -f "$body"
    pr="${url##*/}"
    case "$pr" in '' | *[!0-9]*) halt_run "gh pr create printed no pull request number: $url"; return ;; esac
    bup "$b" '.pr = $pr' --argjson pr "$pr"
    log "batch $b: opened PR #$pr"
    enter_ci "$b"
  else
    rm -f "$body"
    fails=$(($(bget "$b" '.pr_fails // 0') + 1))
    bup "$b" '.pr_fails = $f' --argjson f "$fails"
    [ "$fails" -lt 3 ] || halt_run "could not open the pull request for batch $b. See $LOG."
  fi
}

adv_ci() {
  local b="$1" pr branch pj state checks t since
  pr="$(bget "$b" .pr)"
  branch="$(bget "$b" .branch)"
  t="$(now)"
  since="$(bget "$b" .ci_since)"
  pj="$(pr_json "$pr")" || return 0
  state="$(printf '%s' "$pj" | jq -r .state)"
  case "$state" in
    MERGED) bup "$b" '.phase = "verify" | .verify_since = $t' --argjson t "$t"; CHANGED=1; return ;;
    CLOSED) batch_aside "$b" "its pull request #$pr was closed"; return ;;
  esac
  [ $((t - since)) -ge "$SETTLE" ] || return 0
  g fetch -q origin "$branch" 2>/dev/null
  # Checks count only for the commit that is on the branch now.
  [ "$(printf '%s' "$pj" | jq -r .headRefOid)" = "$(g rev-parse -q --verify "refs/remotes/origin/$branch")" ] || return 0
  checks="$(pr_checks "$pr")"
  case "$checks" in
    green)
      bup "$b" '.phase = "merge"'
      CHANGED=1
      ;;
    pending)
      [ "$t" -lt "$(bget "$b" .ci_deadline)" ] || to_fix "$b" "CI did not finish within $(lim ci_minutes) minutes"
      ;;
    none)
      [ $((t - since)) -ge "$GRACE" ] || return 0
      if [ "$(st .config.ci)" = "optional" ]; then
        bup "$b" '.phase = "merge" | .unchecked = true'
        CHANGED=1
      else
        halt_run "no CI checks ran on PR #$pr (batch $b). The loop merges only what CI has checked. Add CI for pull requests, or add '- ci: optional' to the '## Backlog loop' section, then run /backlog-loop."
      fi
      ;;
    red)
      [ "$t" -ge "$(bget "$b" .rerun_until)" ] || return 0
      if [ "$(bget "$b" .reruns)" -lt 1 ] && rerun_failed "$(printf '%s' "$pj" | jq -r .headRefOid)"; then
        bup "$b" '.reruns += 1 | .rerun_until = $u' --argjson u $((t + SETTLE))
        log "batch $b: reran the failed jobs of PR #$pr"
        CHANGED=1
      else
        to_fix "$b" "failing checks: ${FAILED_CHECKS:-unknown}"
      fi
      ;;
  esac
}

# A batch that is behind the base branch updates only when no earlier batch is
# still on its way to a merge: otherwise it would be behind again right after.
merge_turn() {
  st --arg b "$1" '
    (.batches | map(.name) | index($b)) as $i
    | any(.batches[:$i][]; .status == "active" and (.phase == "ci" or .phase == "merge" or .phase == "verify")) | not'
}

adv_merge() {
  local b="$1" pr branch pj state sha out fails t
  pr="$(bget "$b" .pr)"
  branch="$(bget "$b" .branch)"
  t="$(now)"
  g fetch -q origin "$BASE" "$branch" 2>/dev/null
  pj="$(pr_json "$pr")" || return 0
  state="$(printf '%s' "$pj" | jq -r .state)"
  case "$state" in
    MERGED) bup "$b" '.phase = "verify" | .verify_since = $t' --argjson t "$t"; CHANGED=1; return ;;
    CLOSED) batch_aside "$b" "its pull request #$pr was closed"; return ;;
  esac
  if ! g merge-base --is-ancestor "origin/$BASE" "origin/$branch"; then
    [ "$(merge_turn "$b")" = "true" ] || return 0
    if gh pr update-branch "$pr" >/dev/null 2>&1; then
      log "batch $b: updated PR #$pr from $BASE"
      enter_ci "$b"
    else
      to_conflict "$b"
    fi
    return
  fi
  if [ "$(printf '%s' "$pj" | jq -r .mergeable)" = "CONFLICTING" ]; then
    to_conflict "$b"
    return
  fi
  if [ "$(st .run.no_merge)" = "true" ]; then
    bup "$b" '.status = "ready" | .phase = null'
    log "batch $b: PR #$pr is green and waits for the user"
    CHANGED=1
    return
  fi
  sha="$(g rev-parse "origin/$branch")"
  if out="$(gh pr merge "$pr" "--$METHOD" --match-head-commit "$sha" 2>&1)"; then
    bup "$b" '.phase = "verify" | .verify_since = $t' --argjson t "$t"
    log "batch $b: merged PR #$pr"
    CHANGED=1
  else
    fails=$(($(bget "$b" '.merge_fails // 0') + 1))
    bup "$b" '.merge_fails = $f' --argjson f "$fails"
    log "batch $b: merge of PR #$pr failed ($fails): $out"
    [ "$fails" -lt 3 ] || batch_aside "$b" "GitHub refused to merge PR #$pr: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  fi
}

finish_merged() {
  local b="$1" id branch
  for id in $(batch_items "$b" '.applied'); do
    branch="$(iget "$id" '.branch // empty')"
    iup "$id" '.status = "merged" | .since = null'
    [ -z "$branch" ] || g branch -q -D "$branch" >/dev/null 2>&1
  done
  branch="$(bget "$b" .branch)"
  g branch -q -D "$branch" >/dev/null 2>&1
  g push -q origin --delete "$branch" >/dev/null 2>&1
  bup "$b" '.status = "merged" | .phase = null'
  log "batch $b merged and verified"
  CHANGED=1
}

adv_verify() {
  local b="$1" pr pj sha checks t since url id
  pr="$(bget "$b" .pr)"
  t="$(now)"
  since="$(bget "$b" .verify_since)"
  pj="$(pr_json "$pr")" || return 0
  if [ "$(printf '%s' "$pj" | jq -r .state)" != "MERGED" ]; then
    # The merge call succeeded but GitHub does not show it yet.
    [ $((t - since)) -lt 120 ] || { bup "$b" '.phase = "merge"'; CHANGED=1; }
    return 0
  fi
  g fetch -q origin "$BASE" 2>/dev/null
  sha="$(printf '%s' "$pj" | jq -r '.mergeCommit.oid // empty')"
  checks="none"
  [ -z "$sha" ] || checks="$(commit_checks "$sha")"
  case "$checks" in
    green) finish_merged "$b" ;;
    none)
      # No CI on the base branch: the green pull request result stands.
      [ $((t - since)) -lt "$SETTLE" ] || finish_merged "$b"
      ;;
    pending)
      [ $((t - since)) -lt $(($(lim verify_minutes) * 60)) ] || finish_merged "$b"
      ;;
    red)
      url="$(gh pr revert "$pr" 2>>"$LOG")" || url=""
      for id in $(batch_items "$b" '.applied'); do
        aside_item "$id" "merged in PR #$pr, after which $BASE went red" "the revert, then a fix for what broke $BASE"
      done
      batch_aside "$b" "$BASE went red after its merge"
      if [ -n "$url" ]; then
        halt_run "URGENT: $BASE is red after PR #$pr (batch $b) merged. Revert PR opened: $url. Merge it, then run /backlog-loop."
      else
        halt_run "URGENT: $BASE is red after PR #$pr (batch $b) merged, and the revert PR could not be opened. Run: gh pr revert $pr"
      fi
      ;;
  esac
}

advance_batch() {
  case "$(bget "$1" .phase)" in
    implement) adv_implement "$1" ;;
    apply) adv_apply "$1" ;;
    pr) adv_pr "$1" ;;
    ci) adv_ci "$1" ;;
    merge) adv_merge "$1" ;;
    verify) adv_verify "$1" ;;
  esac
}

start_wave() {
  local names wave
  names="$(st --argjson k "$(lim parallel_batches)" '
    . as $s
    | [.batches[] | select(.status == "todo")
       | select(.name as $n | $s.run.selected | index($n))
       | select(all(.needs[]; . as $n | any($s.batches[]; .name == $n and .status == "merged")))
       | .name] | .[:$k] | join(" ")')"
  if [ -z "$names" ]; then
    finish_run
    return
  fi
  wave=$(($(st '.run.wave // 0') + 1))
  up --arg names "$names" --argjson w "$wave" '
    .run.wave = $w | .run.id as $r
    | (.batches[] | select(.name as $n | ($names | split(" ")) | index($n))) |= (.status = "active" | .phase = "implement" | .wave = $w | .run = $r)'
  log "wave $wave: $names"
  CHANGED=1
}

advance_all() {
  local pass=0 b
  while [ "$pass" -lt 12 ]; do
    pass=$((pass + 1))
    CHANGED=0
    running || return 0
    for b in $(st '.batches[] | select(.status == "active") | .name'); do
      advance_batch "$b"
      running || return 0
    done
    if [ "$(st '[.batches[] | select(.status == "active")] | length')" = "0" ]; then start_wave; fi
    [ "$CHANGED" = "1" ] || break
  done
}

# Workers that never reported count as failed once their deadline passes.
expire_workers() {
  local limit id b
  limit=$(($(now) - $(lim worker_minutes) * 60))
  for id in $(st --argjson l "$limit" '.items[] | select((.status == "working" or .status == "researching") and (.since // 0) < $l) | .id'); do
    fail_item "$id" "the worker did not report within $(lim worker_minutes) minutes"
  done
  for b in $(st --argjson l "$limit" '.batches[] | select(.status == "active" and .worker_since != null and .worker_since < $l) | .name'); do
    log "batch $b: worker past its deadline in phase $(bget "$b" .phase)"
    case "$(bget "$b" .phase)" in
      fix | conflict) record_fixed "$b" "the worker did not report in time" ;;
      status) record_marked "$b" "the worker did not report in time" ;;
      apply)
        id="$(batch_items "$b" '.status == "conflict"' | sed -n 1p)"
        [ -z "$id" ] || record_applied "$id" "the worker did not report in time"
        ;;
    esac
  done
}

# --- the next action ------------------------------------------------------

pick_action() {
  jq -c --arg self "$SELF" --arg dir "$DIR" '
    . as $s
    | [.batches[] | select(.status == "active")] as $active
    | [$active[] | .items[] | $s.items[.]] as $items
    | ([$items[] | select(.status == "working" or .status == "researching")] | length) as $busy_items
    | ([$active[] | select(.worker_since != null)] | length) as $busy_batches
    | ($s.config.limits.parallel_workers - $busy_items - $busy_batches) as $free
    | ($s.config.models) as $m
    | def top($b): [$b.items[] | $s.items[.].tier] as $t
        | $m[if ($t | index("complex")) then "complex" elif ($t | index("standard")) then "standard" else "light" end];
      def worker_steps($kind; $b; $ok; $fail): [
        "Run: \($self) record started --batch \($b.name)",
        "Start one Agent: isolation \"worktree\", subagent_type \"general-purpose\", model \"\(top($b))\". Its prompt is the verbatim output of: \($self) prompt \($kind)",
        "When it reports success, run: \($ok)",
        "When it reports failure or returns nothing useful, run: \($fail)",
        "Then run: \($self) next"];
    if .run.status == "done" then
      {action: "done", steps: ["Run: \($self) report", "Show its output unchanged and stop."]}
    elif .run.status != "running" then
      {action: "halt", reason: .run.reason, steps: ["Run: \($self) report", "Show its output unchanged and stop. Do not restart the loop yourself."]}
    elif .run.replan then
      {action: "plan", summary: "Split the open backlog items into named batches.",
       steps: [
         "Read \($self | sub("/scripts/loop.sh$"; ""))/reference/planning.md.",
         "Read the backlog the way this repository keeps it, and the current plan with: \($self) status",
         "Write the plan to \($dir)/plan.json",
         "Run: \($self) plan-apply   (fix what it rejects and run it again)",
         "Then run: \($self) next"]}
    elif any($active[]; (.phase == "fix" or .phase == "conflict") and .worker_since == null) then
      first($active[] | select((.phase == "fix" or .phase == "conflict") and .worker_since == null)) as $b
      | if $b.phase == "fix" then
          {action: "fix", batch: $b.name, pr: $b.pr, branch: $b.branch, error: $b.error,
           summary: "CI is red on PR #\($b.pr) (batch \($b.name)): \($b.error)",
           steps: (["Read the evidence first: gh pr checks \($b.pr) ; gh run list --branch \($b.branch) --limit 5 ; gh run view <run id> --log-failed"]
             + worker_steps("fix \($b.name)   followed by your diagnosis and the failing log lines"; $b;
                 "\($self) record fixed \($b.name)"; "\($self) record fixed \($b.name) --failed \"<why>\""))}
        else
          {action: "conflict", batch: $b.name, pr: $b.pr, branch: $b.branch,
           summary: "PR #\($b.pr) (batch \($b.name)) conflicts with \($s.config.base).",
           steps: worker_steps("conflict \($b.name)"; $b;
             "\($self) record fixed \($b.name)"; "\($self) record fixed \($b.name) --failed \"<why>\"")}
        end
    elif any($active[]; .phase == "apply" and .worker_since == null and any(.items[]; $s.items[.].status == "conflict")) then
      first($active[] | select(.phase == "apply" and .worker_since == null and any(.items[]; $s.items[.].status == "conflict"))) as $b
      | first($b.items[] | $s.items[.] | select(.status == "conflict")) as $i
      | {action: "apply", batch: $b.name, item: $i.id,
         summary: "Item \($i.id) conflicts with other items of batch \($b.name); one worker applies it by hand.",
         steps: worker_steps("apply \($i.id)"; $b;
           "\($self) record applied \($i.id)"; "\($self) record applied \($i.id) --failed \"<why>\"")}
    elif any($active[]; .phase == "status" and .worker_since == null) then
      first($active[] | select(.phase == "status" and .worker_since == null)) as $b
      | {action: "mark_backlog", batch: $b.name,
         summary: "Mark the items of batch \($b.name) in the backlog file, inside its pull request.",
         steps: worker_steps("status \($b.name)"; $b;
           "\($self) record marked \($b.name)"; "\($self) record marked \($b.name) --failed \"<why>\"")}
    else
      [$active[] | select(.phase == "implement") | .name as $bn | .items[] | $s.items[.] | select(.status == "todo") | . + {batch: $bn}] as $todo
      | [$todo[] | select(.question != null and .decision == null)] as $unclear
      | [$todo[] | select(.question == null or .decision != null)] as $ready
      | if $free > 0 and ($unclear | length) > 0 then
          ($unclear[:$free]) as $pick
          | {action: "research",
             summary: "Research \($pick | length) unclear item(s) instead of asking the user.",
             items: [$pick[] | {id, batch, title, question, subagent_type: "Explore", model: $m.research, prompt_command: "\($self) prompt research \(.id)"}],
             steps: [
               "Run: \($self) record started \([$pick[].id] | join(" "))",
               "In one message, start one Agent per item: subagent_type and model as listed, prompt = the verbatim output of its prompt_command.",
               "For each report, write the decision record \($dir)/decisions/<id>.md (template: reference/workers.md), then run: \($self) record decision <id> --confidence high|medium|low [--needs \"<the one input a human must give>\"]",
               "Low confidence sets the item aside. Do not guess to avoid that.",
               "Then run: \($self) next"]}
        elif $free > 0 and ($ready | length) > 0 then
          ($ready[:$free]) as $pick
          | {action: "implement",
             summary: "Wave \($s.run.wave): implement \($pick | length) item(s) of batch(es) \([$pick[].batch] | unique | join(", ")).",
             items: [$pick[] | {id, batch, title, subagent_type: "general-purpose", model: $m[.tier], prompt_command: "\($self) prompt item \(.id)"}],
             steps: [
               "Run: \($self) record started \([$pick[].id] | join(" "))",
               "In one message, start one Agent per item: isolation \"worktree\", subagent_type and model as listed, prompt = the verbatim output of its prompt_command.",
               "When a worker reports, run: \($self) record item <id>   (add --unclear \"<its question>\", --blocker \"<what is missing>\" or --failed \"<why>\" when its report says so)",
               "Then run: \($self) next"]}
        else
          {action: "wait", workers: ($busy_items + $busy_batches),
           ci: [$active[] | select(.phase == "ci" or .phase == "merge" or .phase == "verify") | .name],
           steps: (if ($busy_items + $busy_batches) > 0 then
               ["Workers are still running. Record every worker that has already reported, then run: \($self) next",
                "If none has reported, end your turn. A worker notification brings you back; then run: \($self) next"]
             else ["CI is running. Run: \($self) next"] end)}
        end
    end' "$STATE"
}

cmd_next() {
  local deadline action started
  load
  if ! running; then
    pick_action
    return 0
  fi
  up '.run.ticks = ((.run.ticks // 0) + 1)'
  lock_touch
  started="$(st .run.started)"
  if [ $(($(now) - started)) -ge $(($(lim max_hours) * 3600)) ]; then
    halt_run "the run reached its limit of $(lim max_hours) hours. Run /backlog-loop to continue."
    pick_action
    return 0
  fi
  expire_workers
  deadline=$(($(now) + SLICE))
  while :; do
    if [ "$(st '.run.replan // false')" != "true" ]; then advance_all; fi
    action="$(pick_action)"
    case "$(printf '%s' "$action" | jq -r '"\(.action) \(.workers // 0)"')" in
      "wait 0")
        [ "$(now)" -lt "$deadline" ] || break
        sleep "$POLL"
        ;;
      *) break ;;
    esac
  done
  log "next: $(printf '%s' "$action" | jq -r '.action + " " + (.summary // "")')"
  printf '%s\n' "$action"
}

# --- start ----------------------------------------------------------------

# Decide which batches this run works on. Prints the problem and fails when
# a batch named by the user cannot run.
resolve_selection() {
  local err
  err="$(st '
    . as $s | (.run.requested // []) as $req
    | def status($n): first($s.batches[] | select(.name == $n) | .status) // null;
      [ $req[] | . as $n | status($n) as $st
        | if $st == null then "there is no batch named \($n). Batches: \([$s.batches[].name] | join(", "))"
          elif $st == "merged" then "batch \($n) is already merged"
          elif $st == "aside" then "batch \($n) was set aside. Run /backlog-loop plan to queue its items again"
          else empty end ]
      + [ $s.batches[] | select(.name as $n | $req | index($n)) | select(.status == "todo") | .name as $b
          | .needs[] | . as $n | status($n) as $st
          | select($st != "merged" and (($req | index($n)) | not))
          | "batch \($b) needs \($n), which is not merged (\($st // "unknown")). Run /backlog-loop \($n) \($b)" ]
      | .[]')"
  if [ -n "$err" ]; then
    printf '%s\n' "$err"
    return 1
  fi
  up '
    (.run.requested // []) as $req
    | .run.selected = [.batches[] | select(.status == "active" or .status == "ready" or (.status == "todo" and (($req | length) == 0 or (.name as $n | $req | index($n))))) | .name]'
}

# Bring the state in line with what happened while no session was watching.
reconcile() {
  local takeover="$1" b pr id sha
  for b in $(st '.batches[] | select(.status == "ready") | .name'); do
    pr="$(bget "$b" .pr)"
    if [ "$(pr_json "$pr" | jq -r '.state // empty' 2>/dev/null)" = "MERGED" ]; then
      for id in $(batch_items "$b" '.applied'); do iup "$id" '.status = "merged"'; done
      bup "$b" '.status = "merged"'
      log "batch $b: PR #$pr was merged by the user"
    fi
  done
  [ "$takeover" = "true" ] || return 0
  # Workers of the previous session are gone. Keep what they committed.
  for id in $(st '.items[] | select(.status == "working") | .id'); do
    if sha="$(item_commit "$id")"; then
      iup "$id" '.status = "built" | .sha = $s | .since = null' --arg s "$sha"
    else
      iup "$id" '.status = "todo" | .since = null'
    fi
  done
  up '(.items[] | select(.status == "researching")) |= (.status = "todo" | .since = null)
    | (.batches[] | select(.worker_since != null)) |= (.worker_since = null)'
}

cmd_start() {
  local session="unknown" no_merge="" plan_only=false names="" cfg owner prev takeover=false tool
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session="${2:-unknown}"; shift 2 ;;
      --no-merge) no_merge=true; shift ;;
      plan) plan_only=true; shift ;;
      status) cmd_report; exit 0 ;;
      -*) die "unknown option $1. Usage: /backlog-loop [--no-merge] [plan | status | BATCH...]" ;;
      *)
        printf '%s' "$1" | grep -Eq "$ID_RE" || die "'$1' is not a batch name"
        names="$names $1"
        shift
        ;;
    esac
  done
  for tool in git gh jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
  paths
  gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
  g remote get-url origin >/dev/null 2>&1 || die "this repository has no 'origin' remote"
  mkdir -p "$DIR/decisions"
  if ! g check-ignore -q "$DIR/state.json"; then
    mkdir -p "$GIT_COMMON/info"
    printf '.planning/backlog-loop/\n' >>"$GIT_COMMON/info/exclude"
  fi
  if [ -f "$LOCK" ]; then
    owner="$(sed -n 1p "$LOCK")"
    if [ "$owner" != "$session" ] && lock_fresh; then
      die "another session ($owner) is running the loop here. If it is gone, wait $((LOCK_STALE / 60)) minutes or delete $LOCK."
    fi
  fi
  cfg="$(build_config)" || exit 1
  BASE="$(printf '%s' "$cfg" | jq -r .base)"
  g fetch -q origin "$BASE" 2>/dev/null || die "cannot fetch '$BASE' from origin"
  if [ ! -f "$STATE" ]; then
    jq -n '{version: 3, config: {}, items: {}, batches: [], run: {status: "none"}}' >"$STATE"
  fi
  [ "$(st '.version // 0')" = "3" ] || die "the state in $DIR is from an older backlog-loop. Move it away and start again."
  up --argjson c "$cfg" '.config = $c + {source: ($c.source_cfg // .config.source // null), backlog: ($c.backlog_cfg // .config.backlog // null)}'
  load
  if [ "$(commit_checks "$(g rev-parse "origin/$BASE")")" = "red" ]; then
    die "CI is red on $BASE. The base branch must be green before the loop adds to it."
  fi

  if running; then
    prev="$(st '.run.session // ""')"
    [ "$prev" = "$session" ] || takeover=true
    up --arg s "$session" --arg names "$names" --arg nm "$no_merge" '
      .run.session = $s
      | .run.requested = (if (.run.requested | length) == 0 then [] else (.run.requested + ($names | split(" ") | map(select(. != ""))) | unique) end)
      | (if $nm == "true" then .run.no_merge = true else . end)'
    printf 'Resuming the unfinished run %s.\n' "$(st .run.id)"
  else
    up --arg s "$session" --arg names "$names" --arg nm "$no_merge" --argjson po "$plan_only" --argjson t "$(now)" '
      ([.batches[] | select(.status == "todo" or .status == "active")] | length) as $open
      | .run = {id: ($t | strftime("%Y%m%d-%H%M%S")), status: "running", reason: null, session: $s, started: $t,
                no_merge: ($nm == "true"), plan_only: $po, wave: 0, ticks: 0,
                requested: ($names | split(" ") | map(select(. != ""))), selected: [],
                replan: ($po or (($open == 0) and ($names == "")))}'
    printf 'Started run %s.\n' "$(st .run.id)"
  fi
  lock_write "$session"
  reconcile "$takeover"
  if [ "$(st .run.replan)" != "true" ]; then
    if ! cfg="$(resolve_selection)"; then
      up '.run.status = "none"'
      rm -f "$LOCK"
      die "$cfg"
    fi
    printf 'Batches in this run: %s\n' "$(st '.run.selected | join(", ")')"
  fi
  log "start: session=$session requested='${names# }' no_merge=$(st .run.no_merge) replan=$(st .run.replan)"
  printf 'Base branch %s, merge method %s. Next: %s next\n' "$BASE" "$METHOD" "$SELF"
}

# --- plan -----------------------------------------------------------------

cmd_plan_apply() {
  local f errs
  load
  need_running
  [ "$(st '[.batches[] | select(.status == "active")] | length')" = "0" ] ||
    die "batches are in progress. A new plan can be applied when they are merged or set aside."
  f="$DIR/plan.json"
  jq -e 'type == "object" and (.batches | type == "array")' "$f" >/dev/null 2>&1 ||
    die "$f is missing, is not valid JSON, or has no \"batches\" array"
  errs="$(st --slurpfile plan "$f" --arg re "$ID_RE" '
    $plan[0] as $p | . as $s
    | [.batches[] | select(.status == "merged" or .status == "ready") | .name] as $kept
    | $p.batches as $bs
    | [ ($bs[] | select(((.name // "") | tostring | test($re)) | not) | "batch name \"\(.name // "")\" is not valid: use letters, digits, dot, dash or underscore"),
        ($bs | group_by(.name)[] | select(length > 1) | "batch name \(.[0].name) is used more than once"),
        ($bs[] | select(.name as $n | $kept | index($n)) | "batch \(.name) already exists as a merged or waiting batch; pick another name"),
        ($bs[] | select((.theme // "") == "") | "batch \(.name) has no theme"),
        ($bs[] | select(((.items // []) | length) == 0) | "batch \(.name) has no items"),
        ($bs[] | select((.tier // "standard") as $t | ["light", "standard", "complex"] | index($t) | not) | "batch \(.name): tier must be light, standard or complex"),
        ($bs | to_entries[] | .key as $i | .value as $b | ($b.needs // [])[] | . as $n
          | select(((($bs[:$i] | map(.name)) + $kept) | index($n)) | not)
          | "batch \($b.name) needs \($n), which is not an earlier batch of the plan or a merged one"),
        ($bs[] | .name as $bn | (.items // [])[]
          | if type != "object" or ((.id // "") | tostring) == "" or (.title // "") == "" then "batch \($bn): every item needs an id and a title"
            elif ((.id | tostring) | test($re)) | not then "item id \"\(.id)\" is not valid: use letters, digits, dot, dash or underscore"
            elif (.tier // "standard") as $t | ["light", "standard", "complex"] | index($t) | not then "item \(.id): tier must be light, standard or complex"
            elif $s.items[.id | tostring].status == "merged" then "item \(.id) is already merged"
            else empty end),
        ([$bs[] | (.items // [])[] | select(type == "object") | (.id // "") | tostring] | group_by(.)[] | select(length > 1) | "item \(.[0]) is in more than one batch")
      ] | unique | .[]')"
  if [ -n "$errs" ]; then
    printf 'plan.json was rejected:\n' >&2
    printf '%s\n' "$errs" | sed 's/^/  - /' >&2
    exit 1
  fi
  up --slurpfile plan "$f" '
    $plan[0] as $p
    | [.batches[] | select(.status == "merged" or .status == "ready")] as $keep
    | ([$keep[].items[]]) as $kept_items
    | ([$p.batches[] | .name as $bn | (.tier // "standard") as $bt | .items[]
        | {key: (.id | tostring), value: {id: (.id | tostring), title, batch: $bn, tier: (.tier // $bt),
            question: (.question // null), decision: null, choice: null, status: "todo", attempts: 0, tries: 0,
            branch: null, sha: null, applied: false, reason: null, needs: null, since: null}}] | from_entries) as $new
    | .batches = $keep + [$p.batches[] | {name, theme, title: (.title // .theme), rationale: (.rationale // ""),
        needs: (.needs // []), tier: (.tier // "standard"), items: [.items[] | .id | tostring],
        status: "todo", phase: null, wave: null, run: null, pr: null, branch: null, worker_since: null,
        tries: 0, fixes: 0, conflicts: 0, reruns: 0, rerun_until: 0, marked: false, error: null, reason: null}]
    | .items = ((.items | with_entries(select(.key as $k | ($kept_items | index($k)) or .value.status == "merged" or .value.status == "aside"))
                 | map_values(if .status == "aside" then .batch = null else . end)) + $new)
    | .config.source = (.config.source_cfg // $p.source // .config.source // "github")
    | .config.backlog = (.config.backlog_cfg // $p.backlog // .config.backlog // "BACKLOG.md")
    | .run.replan = false'
  load
  case "$SOURCE" in github | file) ;; *) die "plan.json: source must be \"github\" or \"file\"" ;; esac
  log "plan applied: $(st '[.batches[] | select(.status == "todo") | .name] | join(" ")')"
  printf 'Plan applied: %s batch(es), %s item(s) to do.\n' \
    "$(st '[.batches[] | select(.status == "todo")] | length')" "$(st '[.items[] | select(.status == "todo")] | length')"
  if [ "$(st .run.plan_only)" = "true" ]; then
    finish_run
  elif ! errs="$(resolve_selection)"; then
    halt_run "$errs"
  fi
  cmd_report
}

# --- record ---------------------------------------------------------------

reason_arg() {
  # reason_arg <flag> <args...>: the value after a flag, or nothing.
  local flag="$1"
  shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$flag" ]; then
      [ -n "${2:-}" ] || die "$flag needs a text"
      printf '%s' "$2"
      return 0
    fi
    shift
  done
  return 0
}

has_flag() {
  local flag="$1"
  shift
  while [ $# -gt 0 ]; do
    [ "$1" != "$flag" ] || return 0
    shift
  done
  return 1
}

need_item() { [ -n "$(st --arg i "$1" '.items[$i].id // empty')" ] || die "there is no item $1"; }
need_batch() { [ -n "$(bget "$1" .name)" ] || die "there is no batch $1"; }

record_started() {
  local id b t status tries slug
  t="$(now)"
  if [ "${1:-}" = "--batch" ]; then
    b="${2:-}"
    need_batch "$b"
    [ "$(bget "$b" .status)" = "active" ] || die "batch $b is not in progress"
    bup "$b" '.worker_since = $t' --argjson t "$t"
    echo "Batch $b: worker started."
    return 0
  fi
  [ $# -gt 0 ] || die "record started needs item ids, or --batch <batch>"
  for id in "$@"; do
    need_item "$id"
    status="$(iget "$id" .status)"
    b="$(iget "$id" '.batch // empty')"
    [ "$status" = "todo" ] || die "item $id is not waiting to start (status: $status)"
    if [ -z "$b" ] || [ "$(bget "$b" .status)" != "active" ]; then die "item $id is not in a batch of this wave"; fi
    if [ "$(iget "$id" '.question != null and .decision == null')" = "true" ]; then
      iup "$id" '.status = "researching" | .since = $t' --argjson t "$t"
      echo "Item $id: research started."
    else
      tries=$(($(iget "$id" .tries) + 1))
      slug="$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-')"
      iup "$id" '.status = "working" | .since = $t | .tries = $n | .branch = $br | .sha = null' \
        --argjson t "$t" --argjson n "$tries" --arg br "backlog-loop/$b/item-$slug-t$tries"
      echo "Item $id: worker started on $(iget "$id" .branch)."
    fi
  done
}

record_item() {
  local id="${1:-}" sha q text
  [ -n "$id" ] || die "record item needs an item id"
  shift
  need_item "$id"
  [ "$(iget "$id" .status)" = "working" ] || die "item $id has no worker running (status: $(iget "$id" .status))"
  g fetch -q origin "$BASE" 2>/dev/null
  if has_flag --unclear "$@"; then
    q="$(reason_arg --unclear "$@")"
    if [ "$(iget "$id" '.decision != null')" = "true" ]; then
      aside_item "$id" "still unclear after research: $q" "$q"
    else
      iup "$id" '.status = "todo" | .question = $q | .since = null' --arg q "$q"
      log "item $id is unclear: $q"
    fi
  elif has_flag --blocker "$@"; then
    text="$(reason_arg --blocker "$@")"
    aside_item "$id" "the worker cannot do it without: $text" "$text"
  elif has_flag --failed "$@"; then
    fail_item "$id" "$(reason_arg --failed "$@")"
  elif sha="$(item_commit "$id")"; then
    iup "$id" '.status = "built" | .sha = $s | .since = null' --arg s "$sha"
    log "item $id built: $sha"
  else
    echo "Item $id: no commit with the trailer 'Backlog-Item: $id' on $(iget "$id" .branch) (exactly one commit on top of $BASE is required)."
    fail_item "$id" "no commit with its trailer on $(iget "$id" .branch)"
  fi
  echo "Item $id: $(iget "$id" .status)."
}

record_decision() {
  local id="${1:-}" conf file h choice q needs
  [ -n "$id" ] || die "record decision needs an item id"
  shift
  need_item "$id"
  [ "$(iget "$id" .status)" = "researching" ] || die "item $id is not being researched (status: $(iget "$id" .status))"
  conf="$(reason_arg --confidence "$@")"
  case "$conf" in high | medium | low) ;; *) die "--confidence must be high, medium or low" ;; esac
  file="$DIR/decisions/$id.md"
  [ -s "$file" ] || die "write the decision record first: $file (.planning/backlog-loop/decisions/$id.md)"
  for h in Question Options Choice Evidence Confidence; do
    grep -q "^## $h" "$file" || die "the decision record decisions/$id.md lacks the heading '## $h'"
  done
  q="$(iget "$id" .question)"
  if [ "$conf" = "low" ]; then
    needs="$(reason_arg --needs "$@")"
    aside_item "$id" "research did not settle it: $q" "${needs:-an answer to: $q}"
  else
    choice="$(awk '/^## Choice/ { on = 1; next } /^## / { on = 0 } on && NF { print; exit }' "$file")"
    iup "$id" '.status = "todo" | .decision = $c | .choice = $ch | .since = null' --arg c "$conf" --arg ch "$choice"
    log "item $id decided ($conf): $choice"
  fi
  echo "Item $id: $(iget "$id" .status)."
}

record_applied() {
  # record_applied <item> [failure text]
  local id="$1" fail="${2:-}" b branch
  b="$(iget "$id" '.batch // empty')"
  if [ -z "$b" ] || [ "$(bget "$b" .phase)" != "apply" ] || [ "$(iget "$id" .status)" != "conflict" ]; then
    die "item $id is not waiting to be applied"
  fi
  branch="$(bget "$b" .branch)"
  if [ -n "$fail" ]; then
    up --arg i "$id" --arg b "$b" --arg n "it conflicts with other items of batch $b: $fail" '
      .items[$i] |= (.status = "todo" | .batch = null | .branch = null | .sha = null | .applied = false | .note = $n)
      | (.batches[] | select(.name == $b)) |= (.items -= [$i] | .worker_since = null)'
    log "item $id left batch $b: $fail"
  else
    g fetch -q origin "$branch" 2>/dev/null
    g log --format=%B "origin/$BASE..origin/$branch" | grep -Fqx "Backlog-Item: $id" ||
      die "no commit with the trailer 'Backlog-Item: $id' on origin/$branch. Was it pushed?"
    iup "$id" '.status = "built" | .applied = true'
    bup "$b" '.worker_since = null'
    log "item $id applied on $branch"
  fi
  echo "Item $id: $(iget "$id" .status)."
}

record_marked() {
  # record_marked <batch> [failure text]
  local b="$1" fail="${2:-}" branch sha files backlog
  [ "$(bget "$b" .phase)" = "status" ] || die "batch $b is not waiting for its backlog update"
  branch="$(bget "$b" .branch)"
  if [ -n "$fail" ]; then
    bup "$b" '.marked = "skipped" | .phase = "pr" | .worker_since = null | .note = $n' --arg n "the backlog file was not updated: $fail"
    log "batch $b: backlog not marked: $fail"
  else
    backlog="$(st .config.backlog)"
    g fetch -q origin "$branch" 2>/dev/null
    sha="$(g log --format=%H --grep="^Backlog-Status: $b\$" "origin/$BASE..origin/$branch" | sed -n 1p)"
    [ -n "$sha" ] || die "no commit with the trailer 'Backlog-Status: $b' on origin/$branch. Was it pushed?"
    files="$(g diff-tree --no-commit-id --name-only -r "$sha")"
    [ "$files" = "$backlog" ] || die "the commit $sha must change only $backlog, but changes: $(printf '%s' "$files" | tr '\n' ' ')"
    bup "$b" '.marked = true | .phase = "pr" | .worker_since = null'
    log "batch $b: backlog marked in $sha"
  fi
  echo "Batch $b: backlog update recorded."
}

record_fixed() {
  # record_fixed <batch> [failure text]
  local b="$1" fail="${2:-}" phase branch sha id pr body dropped=""
  phase="$(bget "$b" .phase)"
  case "$phase" in fix | conflict) ;; *) die "batch $b is not waiting for a fix" ;; esac
  branch="$(bget "$b" .branch)"
  pr="$(bget "$b" .pr)"
  if [ -n "$fail" ]; then
    if [ "$phase" = "conflict" ]; then
      batch_aside "$b" "it conflicts with $BASE and could not be resolved: $fail"
    else
      bup "$b" '.fixes += 1 | .worker_since = null'
      [ "$(bget "$b" .fixes)" -lt "$(lim max_fixes)" ] ||
        batch_aside "$b" "CI is still red after $(bget "$b" .fixes) fix attempts: $(bget "$b" .error)"
    fi
    echo "Batch $b: $(bget "$b" '.status + " " + (.phase // "")')"
    return 0
  fi
  g fetch -q origin "$BASE" "$branch" 2>/dev/null
  sha="$(g rev-parse -q --verify "refs/remotes/origin/$branch")"
  [ "$sha" != "$(bget "$b" .fix_base)" ] || die "no new commit on origin/$branch. The worker must push its fix."
  if [ "$phase" = "conflict" ]; then
    g merge-base --is-ancestor "origin/$BASE" "origin/$branch" ||
      die "origin/$BASE is not merged into origin/$branch yet"
  else
    # A fix may take an item out of the batch with a revert commit.
    for id in $(batch_items "$b" '.applied'); do
      if g log --format=%B "origin/$BASE..origin/$branch" | grep -Fqx "Backlog-Drop: $id"; then
        dropped="$dropped${dropped:+ }$id"
      fi
    done
    if [ -n "$dropped" ]; then
      # The pull request must no longer close the dropped items.
      body="$DIR/pr-body.$$"
      pr_body "$b" "$dropped" >"$body"
      if ! gh pr edit "$pr" --body-file "$body" >/dev/null 2>&1; then
        rm -f "$body"
        die "could not update the description of PR #$pr, which still lists a dropped item. Check gh, then run this command again."
      fi
      rm -f "$body"
    fi
    bup "$b" '.fixes += 1'
    for id in $dropped; do
      aside_item "$id" "dropped from batch $b: it kept CI red" "a look at the failing check, see PR #$pr"
    done
    if [ -z "$(batch_items "$b" '.applied')" ]; then
      batch_aside "$b" "every item was dropped to get CI green"
      echo "Batch $b: aside"
      return 0
    fi
  fi
  enter_ci "$b"
  log "batch $b: new commits on $branch, back to CI"
  echo "Batch $b: back in CI."
}

cmd_record() {
  local what="${1:-}" target
  [ -n "$what" ] || die "record needs an event: started, item, decision, applied, marked, fixed"
  shift
  load
  need_running
  lock_touch
  case "$what" in
    started) record_started "$@" ;;
    item) record_item "$@" ;;
    decision) record_decision "$@" ;;
    applied | marked | fixed)
      target="${1:-}"
      [ -n "$target" ] || die "record $what needs a target"
      shift
      if has_flag --failed "$@"; then set -- "$(reason_arg --failed "$@")"; else set --; fi
      case "$what" in
        applied) need_item "$target"; record_applied "$target" "${1:-}" ;;
        marked) need_batch "$target"; record_marked "$target" "${1:-}" ;;
        fixed) need_batch "$target"; record_fixed "$target" "${1:-}" ;;
      esac
      ;;
    *) die "unknown event '$what'" ;;
  esac
}

# --- prompts --------------------------------------------------------------

section() {
  awk -v s="$1" '
    $0 == "<!-- BEGIN " s " -->" { on = 1; next }
    $0 == "<!-- END " s " -->" { on = 0 }
    on { print }' "$SKILL_DIR/reference/workers.md"
}

# Replace {{NAME}} with the value of the environment variable T_NAME.
fill() {
  awk '
    BEGIN { for (k in ENVIRON) if (k ~ /^T_/) tok[substr(k, 3)] = ENVIRON[k] }
    {
      line = $0
      for (k in tok) {
        t = "{{" k "}}"
        out = ""
        while ((i = index(line, t)) > 0) {
          out = out substr(line, 1, i - 1) tok[k]
          line = substr(line, i + length(t))
        }
        line = out line
      }
      print line
    }'
}

cmd_prompt() {
  local kind="${1:-}" target="${2:-}" b id=""
  load
  [ -n "$target" ] || die "prompt needs a kind and a target"
  case "$kind" in
    item | apply | research)
      id="$target"
      need_item "$id"
      b="$(iget "$id" '.batch // empty')"
      ;;
    fix | conflict | status)
      b="$target"
      need_batch "$b"
      ;;
    *) die "unknown prompt kind '$kind'" ;;
  esac
  (
    export T_BASE="$BASE" T_BATCH="$b" T_ITEM="$id"
    export T_BACKLOG_FILE T_THEME T_BRANCH T_PR T_ERROR T_ITEMS T_ASIDE T_TITLE T_ITEM_BRANCH T_QUESTION T_WHERE T_DECISION
    T_BACKLOG_FILE="$(st '.config.backlog // "BACKLOG.md"')"
    T_THEME="$(bget "$b" .theme)"
    T_BRANCH="$(bget "$b" '.branch // ""')"
    T_PR="$(bget "$b" '.pr // ""')"
    T_ERROR="$(bget "$b" '.error // ""')"
    T_ITEMS="$(st --arg b "$b" '. as $s | .batches[] | select(.name == $b) | .items[] | $s.items[.] | select(.applied) | "- \(.id): \(.title)"')"
    T_ASIDE="$(st --arg b "$b" '[.items[] | select(.batch == $b and .status == "aside") | "- \(.id): \(.title). Why: \(.reason)\(if .needs then ". Needs: " + .needs else "" end)"] | if length == 0 then "None." else join("\n") end')"
    T_TITLE=""
    T_ITEM_BRANCH=""
    T_QUESTION=""
    T_WHERE=""
    T_DECISION="None."
    if [ -n "$id" ]; then
      T_TITLE="$(iget "$id" .title)"
      T_ITEM_BRANCH="$(iget "$id" '.branch // ""')"
      T_QUESTION="$(iget "$id" '.question // ""')"
      if [ "$SOURCE" = "github" ]; then
        T_WHERE="GitHub issue #$id. Read it in full with: gh issue view $id --comments"
      else
        T_WHERE="the entry with id $id in $T_BACKLOG_FILE, and any task file or document it points to"
      fi
      if [ "$(iget "$id" '.decision != null')" = "true" ] && [ -f "$DIR/decisions/$id.md" ]; then
        T_DECISION="$(cat "$DIR/decisions/$id.md")"
      fi
    fi
    if [ "$kind" = "research" ]; then
      section research | fill
    else
      {
        section common
        section "$kind"
        section report
      } | fill
    fi
  )
}

# --- report ---------------------------------------------------------------

cmd_report() {
  paths
  if [ ! -f "$STATE" ] || [ "$(st '.batches | length')" = "0" ]; then
    echo "Backlog loop: no plan yet. Run /backlog-loop to plan the backlog into batches."
    return 0
  fi
  st '
    . as $s
    | def status($n): first($s.batches[] | select(.name == $n) | .status) // "unknown";
      def waits: [.needs[] | select(status(.) != "merged") | "needs \(.), which is \(status(.))"] | if length == 0 then "" else " (" + join("; ") + ")" end;
    [.batches[] | select(.run == $s.run.id and (.status == "merged" or .status == "ready"))] as $done
    | [.items[] | select(.status == "aside")] as $aside
    | [.batches[] | select(.status == "aside")] as $aside_batches
    | [.batches[] | select(.status == "todo" or .status == "active")] as $open
    | [.items[] | select(.batch == null and .status == "todo")] as $loose
    | "Backlog loop: \(if .run.status == "none" then "not running" else .run.status end)\(if .run.reason then " - " + .run.reason else "" end)",
      "",
      "Implemented in this run",
      (if ($done | length) == 0 then "  nothing" else
        ($done[] | "  Batch \(.name) \"\(.theme)\": PR #\(.pr), \(if .status == "merged" then "merged" else "green, waiting for your merge" end)",
          (.items[] as $i | $s.items[$i] | select(.status == "merged" or .applied)
            | "    \(.id): \(.title)\(if .decision then "  [decided by research, \(.decision) confidence: decisions/\(.id).md]" else "" end)"),
          (if .note then "    Note: \(.note)" else empty end))
       end),
      "",
      "Set aside",
      (if ($aside | length) + ($aside_batches | length) == 0 then "  nothing" else
        ($aside[] | "  \(.id): \(.title)", "    Why: \(.reason)", (if .needs then "    Needs: \(.needs)" else empty end)),
        ($aside_batches[] | "  Batch \(.name) \"\(.theme)\": \(.reason)\(if .pr then " (PR #\(.pr) left open)" else "" end)",
          (.items[] as $i | $s.items[$i] | select(.status != "aside") | "    \(.id): \(.title)"))
       end),
      "",
      "Remaining",
      (if ($open | length) + ($loose | length) == 0 then "  nothing" else
        ($open[] | "  Batch \(.name) \"\(.theme)\"\(if .status == "active" then " (in progress)" else waits end)",
          (.items[] as $i | $s.items[$i] | select(.status != "aside" and .status != "merged") | "    \(.id): \(.title)")),
        (if ($loose | length) > 0 then "  Not in a batch (run /backlog-loop plan):", ($loose[] | "    \(.id): \(.title)\(if .note then " - " + .note else "" end)") else empty end)
       end)'
}

# --- internal: used by hooks.sh -------------------------------------------

cmd_gate() {
  # _gate <hash> <unchanged> <blocks>
  load
  up --arg h "$1" --argjson u "$2" --argjson b "$3" '.run.gate = {hash: $h, unchanged: $u, blocks: $b}'
}

cmd_halt() {
  load
  running || return 0
  halt_run "$1"
}

main() {
  local cmd="${1:-}"
  [ $# -eq 0 ] || shift
  case "$cmd" in
    start) cmd_start "$@" ;;
    next) cmd_next ;;
    plan-apply) cmd_plan_apply ;;
    record) cmd_record "$@" ;;
    prompt) cmd_prompt "$@" ;;
    report | status) cmd_report ;;
    _gate) cmd_gate "$@" ;;
    _halt) cmd_halt "$@" ;;
    *) die "usage: loop.sh start|next|plan-apply|record|prompt|report|status" ;;
  esac
}

main "$@"
