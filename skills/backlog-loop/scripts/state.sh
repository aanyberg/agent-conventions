#!/usr/bin/env bash
# state.sh: the only writer of .planning/backlog-loop/state.json.
#
#   state.sh init --session ID [--plan-only] [--no-merge]
#   state.sh resume --session ID [--plan-only] [--no-merge]
#   state.sh status | items | hash | get <jq-filter> | log <message>
#   state.sh plan-apply <plan.json>
#   state.sh record <event> [args]      (see the record_* functions)
#   state.sh pr-title <batch> | pr-body <batch> | branch <batch>
#   state.sh worker-prompt <batch> [--mode implement|fix|conflict|drop] [--item ID]
#   state.sh research-prompt <item>
#   state.sh cleanup <batch> | reconcile | sync-backlog | archive | unlock
set -u
BL_SELF=state
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
bl_paths || bl_die "not inside a git repository"

# jq helpers shared by every state transition.
JQ_DEFS='
def has_id($ids; $i): any($ids[]; . == $i);
def live: .status == "todo" or .status == "in-progress";
def batch_items($b): [.items[] | select(.batch == $b and live)];
def set_batch($b; f): .batches |= map(if .id == $b then f else . end);
def set_items($b; f): .items |= map(if .batch == $b and live then f else . end);
def set_item($i; f): .items |= map(if .id == $i then f else . end);
def new_batch($id; $theme; $items; $deps; $order): {
  id: $id, kind: "items", theme: $theme, title: null, rationale: null,
  items: $items, order: $order, depends_on: $deps,
  status: "todo", phase: null, try: 1, branch: null, old_branches: [], pushed: false,
  pr: null, revert_pr: null, head_sha: null, premerge_sha: null, merge_commit: null,
  ci_reruns: 0, ci_polls: 0, ci_started_at: null, worker_started_at: null,
  fixes: 0, failures: 0, conflict_attempts: 0, requeues: 0, merge_tries: 0,
  removed: [], retry_of: null, last_error: null };
# Count a failed attempt for every live item of a batch. Items that run out of
# attempts are blocked directly ($drop == false) or dropped from the branch
# first. When no item is left to continue with, the batch goes to "blocking".
def fail_batch($b; $msg; $max; $drop; $next):
  set_items($b; if .pending == null then .attempts += 1 | .last_error = $msg else . end)
  | (batch_items($b)) as $act
  | ([$act[] | select(.pending == null and .attempts < $max)] | length) as $left
  | set_items($b;
      if .pending == null and .attempts >= $max
      then .pending = (if $drop and $left > 0 then "drop" else "block" end)
      else . end)
  | set_batch($b; .failures += 1 | .last_error = $msg
      | if .kind == "status"
        then (if .failures >= $max then .status = "blocked" | .phase = null else .phase = $next end)
        else .phase = (if $left == 0 then "blocking" else $next end) end);
'

need_state() { bl_state_ok || bl_die "no usable state at $BL_STATE; run preflight.sh first"; }

upd() { bl_update "$@"; }

# bq <batch> <filter>: read one field of a batch.
bq() { jq -r --argjson b "$1" ".batches[] | select(.id == \$b) | $2" "$BL_STATE"; }
# iq <item> <filter>: read one field of an item.
iq() { jq -r --arg i "$1" ".items[] | select(.id == \$i) | $2" "$BL_STATE"; }

require_batch() {
  [ -n "$(bq "$1" '.id' 2>/dev/null)" ] || bl_die "unknown batch: $1"
}

require_phase() {
  local b="$1" have want
  shift
  have="$(bq "$b" '.phase // "none"')"
  for want in "$@"; do
    [ "$have" = "$want" ] && return 0
  done
  bl_die "batch $b is in phase '$have', expected: $*. Run next.sh for the current action."
}

max_attempts() { bl_limit max_attempts; }

# --- backlog source ----------------------------------------------------------

load_items() {
  local source label path raw
  source="$(jq -r '.source' "$BL_CONFIG")"
  if [ "$source" = "github" ]; then
    label="$(jq -r '.label' "$BL_CONFIG")"
    raw="$(gh issue list --label "$label" --state open --limit 500 --json number,title,labels,url 2>&1)" ||
      bl_die "gh issue list failed: $raw"
    printf '%s' "$raw" | jq '[.[] | {id: (.number | tostring), title, url,
        preblocked: any(.labels[]?; .name == "blocked")}] | sort_by(.id | tonumber)'
  else
    path="$(jq -r '.path' "$BL_CONFIG")"
    [ -f "$BL_ROOT/$path" ] || bl_die "backlog file not found: $path"
    awk -v mode=list -f "$BL_SCRIPT_DIR/backlog.awk" "$BL_ROOT/$path" |
      jq -R -s '[split("\n")[] | select(length > 0) | split("\t")
        | {id: .[0], title: .[1], url: null, preblocked: (.[2] == "blocked")}]'
  fi
}

cmd_init() {
  local session="unknown" plan_only=false no_merge=false items dupes run_id tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session="${2:-unknown}"; shift 2 ;;
      --plan-only) plan_only=true; shift ;;
      --no-merge) no_merge=true; shift ;;
      *) shift ;;
    esac
  done
  case "$session" in '' | '${'*) session="unknown" ;; esac
  [ -s "$BL_CONFIG" ] || bl_die "no config.json; run preflight.sh first"
  if bl_state_ok; then
    if [ "$(bl_get '.run.status')" = "done" ]; then
      cmd_archive
    else
      bl_die "an unfinished run exists; resume it with: state.sh resume"
    fi
  fi
  bl_lock_acquire "$session" || bl_die "another session ($(bl_lock_owner)) holds $BL_LOCK"
  items="$(load_items)" || { bl_lock_release; exit 1; }
  dupes="$(printf '%s' "$items" | jq -r '[.[].id] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")')"
  [ -z "$dupes" ] || { bl_lock_release; bl_die "duplicate backlog ids: $dupes"; }
  [ "$(printf '%s' "$items" | jq '[.[] | select(.preblocked | not)] | length')" -gt 0 ] ||
    { bl_lock_release; bl_die "the backlog has no open items"; }
  run_id="$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "$BL_DIR/decisions" "$BL_DIR/prompts"
  tmp="$BL_STATE.tmp.$$"
  jq -n --slurpfile cfg "$BL_CONFIG" --argjson items "$items" --arg run "$run_id" \
    --arg session "$session" --argjson now "$(bl_now)" --arg iso "$(bl_iso)" \
    --argjson plan_only "$plan_only" --argjson no_merge "$no_merge" '
    { version: 1,
      run: { id: $run, status: "running", session: $session,
             flags: { plan_only: $plan_only, no_merge: $no_merge },
             started_at: $now, started_iso: $iso, segment_started_at: $now,
             iterations: 0, total_iterations: 0, last_hash: null, unchanged_gates: 0,
             gate_blocks: 0, halt_reason: null, permission_mode: null },
      config: $cfg[0],
      items: [ $items[] | {
          id, title, url,
          status: (if .preblocked then "blocked" else "todo" end),
          batch: null, attempts: 0, last_error: null, pending: null,
          research: "none", research_passes: 0, question: null,
          decision: null, confidence: null, needs_review: false,
          blocked_reason: (if .preblocked then {tried: null, why: "already marked blocked before this run", needs: null} else null end),
          preblocked: .preblocked } ],
      batches: [] }' >"$tmp" || { rm -f "$tmp"; bl_lock_release; bl_die "could not build state"; }
  mv -f "$tmp" "$BL_STATE"
  bl_log "init run=$run_id session=$session items=$(bl_get '.items | length') plan_only=$plan_only no_merge=$no_merge"
  printf 'Run %s started with %s open items.\n' "$run_id" "$(bl_get '[.items[] | select(.status == "todo")] | length')"
}

cmd_resume() {
  local session="unknown" plan_only=false no_merge="" status
  need_state
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session="${2:-unknown}"; shift 2 ;;
      --plan-only) plan_only=true; shift ;;
      --no-merge) no_merge=true; shift ;;
      *) shift ;;
    esac
  done
  case "$session" in '' | '${'*) session="unknown" ;; esac
  status="$(bl_get '.run.status')"
  [ "$status" != "done" ] || bl_die "the last run already finished; start a new one"
  bl_lock_acquire "$session" || bl_die "another session ($(bl_lock_owner)) holds $BL_LOCK"
  upd --arg session "$session" --argjson now "$(bl_now)" --argjson plan_only "$plan_only" \
    --arg no_merge "$no_merge" '
    .run.status = "running" | .run.session = $session | .run.halt_reason = null
    | .run.segment_started_at = $now | .run.iterations = 0
    | .run.unchanged_gates = 0 | .run.gate_blocks = 0 | .run.last_hash = null
    | .run.flags.plan_only = $plan_only
    | (if $no_merge == "true" then .run.flags.no_merge = true else . end)'
  cmd_reconcile
  if [ "$plan_only" = true ] && [ "$(bl_get '.batches | length')" -gt 0 ]; then
    upd '.run.status = "halted" | .run.halt_reason = "plan-only"'
  fi
  bl_log "resume session=$session previous_status=$status"
  printf 'Run %s resumed (was %s).\n' "$(bl_get '.run.id')" "$status"
}

cmd_archive() {
  local id dest f
  bl_state_ok || return 0
  id="$(bl_get '.run.id')"
  dest="$BL_DIR/archive/$id"
  mkdir -p "$dest"
  for f in state.json plan.md plan.json run.log report.md decisions prompts; do
    if [ -e "$BL_DIR/$f" ]; then mv "$BL_DIR/$f" "$dest/"; fi
  done
  printf 'Archived run %s to %s\n' "$id" "$dest"
}

cmd_status() {
  if ! bl_state_ok; then
    if [ -e "$BL_STATE" ]; then echo '{"exists":true,"usable":false}'; else echo '{"exists":false}'; fi
    return 0
  fi
  jq -c '{exists: true, usable: true, run: .run.id, status: .run.status,
          halt_reason: .run.halt_reason, flags: .run.flags, iterations: .run.total_iterations,
          items: ([.items[] | .status] | group_by(.) | map({key: .[0], value: length}) | from_entries),
          batches: ([.batches[] | .status] | group_by(.) | map({key: .[0], value: length}) | from_entries)}' "$BL_STATE"
}

cmd_items() {
  need_state
  jq '[.items[] | select(.status == "todo" and .batch == null) | {id, title, url}]' "$BL_STATE"
}

# --- planning ----------------------------------------------------------------

cmd_plan_apply() {
  local file="${1:-}" errors max
  need_state
  [ -f "$file" ] || bl_die "usage: state.sh plan-apply <plan.json>"
  jq -e '.batches | type == "array"' "$file" >/dev/null 2>&1 || bl_die "plan needs a top-level \"batches\" array: $file"
  [ "$(bl_get '[.batches[] | select(.status != "todo")] | length')" = "0" ] ||
    bl_die "batches are already in flight; the plan can no longer be replaced"
  max="$(bl_limit max_batch_items)"
  errors="$(jq -r --slurpfile plan "$file" --argjson max "${max:-15}" "$JQ_DEFS"'
    $plan[0] as $p
    | [.items[] | select(.status == "todo") | .id] as $todo
    | [$p.batches[] | (.items // [])[] | tostring] as $all
    | [ (if ($p.batches | length) == 0 then "the plan has no batches" else empty end),
        ($p.batches | to_entries[]
          | (.key + 1) as $n | .value
          | (if ((.items // []) | length) == 0 then "batch \($n) has no items" else empty end),
            (if (.theme // "") == "" then "batch \($n) has no theme" else empty end),
            (if ((.items // []) | length) > $max then "batch \($n) has more than \($max) items" else empty end),
            ((.depends_on // [])[] | select(. >= $n or . < 1) | "batch \($n) may only depend on earlier batches, not \(.)")),
        ($todo[] | . as $i | ($all | map(select(. == $i)) | length) as $c
          | select($c != 1) | "item \($i) is in \($c) batches, expected exactly 1"),
        ($all[] | . as $i | select(has_id($todo; $i) | not) | "item \($i) is not an open backlog item"),
        (($p.unclear // [])[] | (.id | tostring) as $i | select(has_id($todo; $i) | not) | "unclear item \($i) is not an open backlog item")
      ] | unique | .[]' "$BL_STATE")" || bl_die "could not validate the plan"
  if [ -n "$errors" ]; then
    printf 'Plan rejected:\n%s\n' "$errors" >&2
    exit 1
  fi
  upd --slurpfile plan "$file" "$JQ_DEFS"'
    $plan[0] as $p
    | .batches = [ $p.batches | to_entries[] | (.key + 1) as $n | .value as $v
        | new_batch($n; $v.theme; [$v.items[] | tostring]; ($v.depends_on // []); $n)
        | .title = ($v.title // null) | .rationale = ($v.rationale // null) ]
    | reduce .batches[] as $b (.;
        .items |= map(. as $it | if has_id($b.items; $it.id) then .batch = $b.id else . end))
    | reduce ($p.unclear // [])[] as $u (.;
        set_item($u.id | tostring; .research = "pending" | .question = $u.question))
    | if .run.flags.plan_only then .run.status = "halted" | .run.halt_reason = "plan-only" else . end'
  write_plan_md
  bl_log "plan applied: $(bl_get '.batches | length') batches for $(bl_get '[.items[] | select(.batch != null)] | length') items"
  printf 'Plan applied: %s batches. See %s\n' "$(bl_get '.batches | length')" "$BL_DIR/plan.md"
}

write_plan_md() {
  jq -r --arg src "$(bl_cfg source)" '
    def ref($i): (if $src == "github" then "#" else "" end) + $i;
    . as $s
    | "# Backlog loop plan",
      "",
      "Run \(.run.id), base branch `\(.config.base_branch)`, \(.batches | length) batches for \([.batches[].items[]] | length) items.",
      "",
      ((.batches | sort_by(.order)[]) as $b
        | "## Batch \($b.id): \($b.theme)",
          "",
          (if ($b.depends_on | length) > 0 then "Depends on: " + ($b.depends_on | map("batch \(.)") | join(", ")) else "Depends on: nothing" end),
          (if $b.rationale then "", $b.rationale else empty end),
          "",
          ($b.items[] as $i | ($s.items[] | select(.id == $i)) as $it
            | "- \(ref($i)) \($it.title)" + (if $it.research == "pending" then " (unclear: \($it.question))" else "" end)),
          "")' "$BL_STATE" >"$BL_DIR/plan.md"
}

# --- names, PR text, prompts -------------------------------------------------

cmd_branch() {
  need_state
  require_batch "$1"
  bq "$1" '.branch // empty'
}

cmd_pr_title() {
  need_state
  require_batch "$1"
  bq "$1" '.title // "\(.theme) (backlog batch \(.id))"'
}

cmd_pr_body() {
  local b="$1" id path conf
  need_state
  require_batch "$b"
  if [ "$(bq "$b" '.kind')" = "status" ]; then
    printf 'Updates item status in `%s` after backlog-loop run %s.\n\n' "$(bl_cfg path)" "$(bl_get '.run.id')"
    jq -r '.items[] | select(.status == "merged" or .status == "blocked" or .needs_review)
      | "- \(.id): \(.status)" + (if .needs_review then " (needs review)" else "" end)' "$BL_STATE"
    return 0
  fi
  printf '## Backlog batch %s: %s\n\n' "$b" "$(bq "$b" '.theme')"
  bq "$b" '.rationale // empty'
  printf '\n### Items\n\n'
  if [ "$(bl_cfg source)" = "github" ]; then
    jq -r --argjson b "$b" "$JQ_DEFS"'batch_items($b)[] | "- Closes #\(.id): \(.title)"' "$BL_STATE"
  else
    jq -r --argjson b "$b" "$JQ_DEFS"'batch_items($b)[] | "- \(.id): \(.title)"' "$BL_STATE"
  fi
  jq -r --argjson b "$b" "$JQ_DEFS"'batch_items($b)[] | select(.decision != null) | .id' "$BL_STATE" |
    while IFS= read -r id; do
      path="$BL_DIR/$(iq "$id" '.decision')"
      conf="$(iq "$id" '.confidence')"
      printf '\n### Decision for %s (confidence: %s%s)\n\n' "$(bl_ref "$id")" "$conf" \
        "$([ "$conf" = low ] && printf ', needs review')"
      if [ -f "$path" ]; then cat "$path"; fi
    done
  printf '\n---\nOpened by backlog-loop run %s. One commit per item, so a single item can be reverted with `git revert`.\n' "$(bl_get '.run.id')"
}

# render <template> : replaces {{NAME}} tokens with the BL_T_NAME variables.
render() {
  local line name var out
  while IFS= read -r line || [ -n "$line" ]; do
    out=""
    while [[ "$line" =~ \{\{([A-Z_]+)\}\} ]]; do
      name="${BASH_REMATCH[1]}"
      var="BL_T_$name"
      out="$out${line%%"{{$name}}"*}${!var-}"
      line="${line#*"{{$name}}"}"
    done
    printf '%s\n' "$out$line"
  done <"$1"
}

# Text between "<!-- BEGIN name -->" and "<!-- END name -->" in a reference file.
section() {
  awk -v name="$2" '
    $0 == "<!-- END " name " -->" { on = 0 }
    on { print }
    $0 == "<!-- BEGIN " name " -->" { on = 1 }' "$1"
}

# The BL_T_* variables are read by render() through indirect expansion.
# shellcheck disable=SC2034
cmd_worker_prompt() {
  local b="$1" mode="implement" item="" tmpl out done_ids
  shift
  need_state
  require_batch "$b"
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --item) item="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$mode" = "implement" ] && [ "$(bq "$b" '.pushed')" = "true" ]; then mode="continue"; fi
  BL_T_BATCH="$b"
  BL_T_THEME="$(bq "$b" '.theme')"
  BL_T_BRANCH="$(bq "$b" '.branch')"
  BL_T_BASE="$(bl_cfg base_branch)"
  BL_T_TEST="$(bl_cfg test)"
  BL_T_LINT="$(bl_cfg lint)"
  BL_T_BUILD="$(bl_cfg build)"
  BL_T_PR="$(bq "$b" '.pr // "none"')"
  BL_T_ERROR="$(bq "$b" '.last_error // "none"')"
  BL_T_ITEM="$item"
  BL_T_BACKLOG_FILE="$(bl_cfg path)"
  done_ids="[]"
  if [ "$mode" = "continue" ]; then done_ids="$(trailer_ids "$b" Backlog-Item | ids_json)"; fi
  BL_T_ITEMS="$(jq -r --argjson b "$b" --arg src "$(bl_cfg source)" --argjson committed "$done_ids" "$JQ_DEFS"'
    batch_items($b)[] | select(.pending == null and .research != "pending" and (has_id($committed; .id) | not))
    | "- id \(.id): \(.title)"
      + (if $src == "github" then " (read it with: gh issue view \(.id))" else "" end)
      + (if .decision then " [decision record below]" else "" end)
      + (if .last_error then " [previous attempt failed: \(.last_error)]" else "" end)' "$BL_STATE")"
  BL_T_DECISIONS="$(jq -r --argjson b "$b" "$JQ_DEFS"'batch_items($b)[] | select(.decision != null) | "\(.id)\t\(.decision)"' "$BL_STATE" |
    while IFS="$(printf '\t')" read -r id path; do
      printf '### Decision for item %s\n\n' "$id"
      if [ -f "$BL_DIR/$path" ]; then cat "$BL_DIR/$path"; fi
      printf '\n'
    done)"
  [ -n "$BL_T_DECISIONS" ] || BL_T_DECISIONS="None."
  tmpl="$BL_DIR/prompts/.tmpl.$$"
  mkdir -p "$BL_DIR/prompts"
  {
    section "$BL_SKILL_DIR/reference/implementer.md" "common"
    section "$BL_SKILL_DIR/reference/implementer.md" "$mode"
    section "$BL_SKILL_DIR/reference/implementer.md" "report"
  } >"$tmpl"
  [ -s "$tmpl" ] || { rm -f "$tmpl"; bl_die "unknown worker mode: $mode"; }
  out="$BL_DIR/prompts/b$b-$mode.md"
  render "$tmpl" >"$out"
  rm -f "$tmpl"
  cat "$out"
}

# shellcheck disable=SC2034
cmd_research_prompt() {
  local item="$1" tmpl
  need_state
  [ -n "$(iq "$item" '.id')" ] || bl_die "unknown item: $item"
  BL_T_ITEM="$item"
  BL_T_TITLE="$(iq "$item" '.title')"
  BL_T_QUESTION="$(iq "$item" '.question // "Not stated; work out what is unclear."')"
  BL_T_REF="$(bl_ref "$item")"
  if [ "$(bl_cfg research_web)" = "false" ]; then
    BL_T_WEB="Web access is not available. Use the codebase and the issue thread only."
  else
    BL_T_WEB="External documentation may be consulted last, for the dependency versions pinned in this repository."
  fi
  if [ "$(bl_cfg source)" = "github" ]; then
    BL_T_SOURCE="Read the issue thread and linked PRs with: gh issue view $item --comments"
  else
    BL_T_SOURCE="Read the item's entry in $(bl_cfg path)."
  fi
  tmpl="$BL_DIR/prompts/.tmpl.$$"
  mkdir -p "$BL_DIR/prompts"
  section "$BL_SKILL_DIR/reference/research.md" "prompt" >"$tmpl"
  render "$tmpl" | tee "$BL_DIR/prompts/research-$item.md"
  rm -f "$tmpl"
}

# --- git and GitHub helpers --------------------------------------------------

fetch_ref() { git -C "$BL_ROOT" fetch -q origin "$@" >/dev/null 2>&1 || true; }

remote_sha() { git -C "$BL_ROOT" rev-parse -q --verify "refs/remotes/origin/$1" 2>/dev/null; }

# Ids named by a trailer ("Backlog-Item" or "Backlog-Drop") on the batch branch.
trailer_ids() {
  local b="$1" key="$2" base branch
  base="$(bl_cfg base_branch)"
  branch="$(bq "$b" '.branch // empty')"
  [ -n "$branch" ] && [ -n "$(remote_sha "$branch")" ] || return 0
  git -C "$BL_ROOT" log --format=%B "origin/$base..origin/$branch" 2>/dev/null |
    sed -n "s/^$key:[[:space:]]*//p" | sed 's/[[:space:]]*$//' | sort -u
}

ids_json() { jq -R -s '[split("\n")[] | select(length > 0)]'; }

close_pr() {
  local b="$1" why="$2" pr
  pr="$(bq "$b" '.pr // empty')"
  [ -n "$pr" ] || return 0
  gh pr close "$pr" --comment "Closed by backlog-loop: $why" >/dev/null 2>&1 ||
    bl_log "could not close PR #$pr for batch $b"
}

mirror_comment() {
  [ "$(bl_cfg source)" = "github" ] || return 0
  gh issue comment "$1" --body "$2" >/dev/null 2>&1 || bl_log "mirror: comment on #$1 failed"
}

mirror_label() {
  [ "$(bl_cfg source)" = "github" ] || return 0
  gh label create "$2" --description "Set by backlog-loop" --color "$3" >/dev/null 2>&1 || true
  gh issue edit "$1" --add-label "$2" >/dev/null 2>&1 || bl_log "mirror: label $2 on #$1 failed"
}

mirror_blocked() {
  local i="$1" body
  [ "$(iq "$i" '.preblocked')" = "true" ] && return 0
  body="$(iq "$i" '"**Blocked by backlog-loop.**\n\n- Tried: \(.blocked_reason.tried // "n/a")\n- Why it failed: \(.blocked_reason.why // "n/a")\n- Input needed: \(.blocked_reason.needs // "n/a")"')"
  mirror_label "$i" blocked B60205
  mirror_comment "$i" "$body"
}

mirror_merged() {
  local i="$1" pr="$2"
  [ "$(bl_cfg source)" = "github" ] || return 0
  if [ "$(gh issue view "$i" --json state --jq .state 2>/dev/null)" = "OPEN" ]; then
    gh issue close "$i" --reason completed --comment "Implemented in PR #$pr by backlog-loop." >/dev/null 2>&1 ||
      bl_log "mirror: closing #$i failed"
  fi
}

# Remove worktrees and local branches left over from earlier workers of a batch.
cmd_cleanup() {
  local b="$1" prefix wt="" branch old
  need_state
  require_batch "$b"
  prefix="refs/heads/backlog-loop/$(bl_get '.run.id')/b$b-"
  git -C "$BL_ROOT" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      "branch $prefix"*)
        if [ "$wt" != "$BL_ROOT" ]; then
          git -C "$BL_ROOT" worktree unlock "$wt" >/dev/null 2>&1 || true
          git -C "$BL_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || bl_log "cleanup: could not remove worktree $wt"
        fi
        ;;
    esac
  done
  git -C "$BL_ROOT" worktree prune >/dev/null 2>&1 || true
  git -C "$BL_ROOT" for-each-ref --format='%(refname:short)' "$prefix*" 2>/dev/null | while IFS= read -r branch; do
    git -C "$BL_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  done
  bq "$b" '.old_branches[]?' | while IFS= read -r old; do
    if [ -n "$(remote_sha "$old")" ]; then
      git -C "$BL_ROOT" push -q origin --delete "$old" >/dev/null 2>&1 || true
    fi
  done
  bl_log "cleanup batch=$b"
}

# Put a batch back in the queue, last, after a conflict that could not be fixed.
requeue_batch() {
  local b="$1"
  close_pr "$b" "merge conflict with the base branch; the batch is re-queued"
  upd --argjson b "$b" "$JQ_DEFS"'
    (.batches[] | select(.id == $b)) as $bt
    | ([.batches[].order] | max + 1) as $last
    | if $bt.requeues >= 1 then
        set_items($b; .pending = "block" | .last_error = "merge conflict persists after re-queueing the batch")
        | set_batch($b; .phase = "blocking" | .last_error = "merge conflict persists after re-queue")
      else
        set_items($b; .status = "todo")
        | set_batch($b; .status = "todo" | .phase = null | .requeues += 1 | .try += 1
            | .old_branches += [.branch] | .branch = null | .pr = null | .pushed = false
            | .head_sha = null | .premerge_sha = null | .conflict_attempts = 0 | .order = $last)
      end'
  bl_log "requeue batch=$b"
}

# After items left a batch: finish it when nothing is left to do in it.
settle_batch() {
  local b="$1" left
  left="$(jq -r --argjson b "$b" "$JQ_DEFS"'batch_items($b) | length' "$BL_STATE")"
  [ "$left" = "0" ] || return 0
  case "$(bq "$b" '.status')" in merged | blocked | closed) return 0 ;; esac
  close_pr "$b" "no items are left in this batch"
  upd --argjson b "$b" "$JQ_DEFS"'
    (.batches[] | select(.id == $b) | .removed) as $gone
    | ([.items[] | select(.id as $i | has_id($gone; $i))
        | select(.status != "blocked" and .pending != "block")] | length) as $moved
    | set_batch($b; .status = (if $moved > 0 then "closed" else "blocked" end) | .phase = null)'
  bl_log "batch $b finished without merge: $(bq "$b" '.status')"
}

# --- record: state transitions ----------------------------------------------

record_worker_started() {
  local b="$1" status
  require_batch "$b"
  status="$(bq "$b" '.status')"
  if [ "$status" = "in-progress" ]; then require_phase "$b" implement; else
    [ "$status" = "todo" ] || bl_die "batch $b is $status and cannot be started"
  fi
  cmd_cleanup "$b"
  upd --argjson b "$b" --argjson now "$(bl_now)" --arg run "$(bl_get '.run.id')" "$JQ_DEFS"'
    set_batch($b; .status = "in-progress" | .phase = "working" | .worker_started_at = $now
      | .branch = (.branch // "backlog-loop/\($run)/b\(.id)-t\(.try)"))
    | set_items($b; .status = "in-progress")'
  bl_log "worker-started batch=$b branch=$(bq "$b" '.branch')"
  bq "$b" '.branch'
}

record_worker_done() {
  local b="$1" branch sha done_ids
  require_batch "$b"
  require_phase "$b" working
  branch="$(bq "$b" '.branch')"
  fetch_ref "$branch" "$(bl_cfg base_branch)"
  sha="$(remote_sha "$branch")"
  if [ -z "$sha" ]; then
    record_worker_failed "$b" --reason "the worker did not push branch $branch"
    return 0
  fi
  done_ids="$(trailer_ids "$b" Backlog-Item | ids_json)"
  upd --argjson b "$b" --argjson committed "$done_ids" --arg sha "$sha" \
    --argjson max "$(max_attempts)" "$JQ_DEFS"'
    set_items($b;
      if .pending != null or .research == "pending" or has_id($committed; .id) then .
      else .attempts += 1 | .last_error = "no commit with trailer Backlog-Item: \(.id) on the branch"
        | (if .attempts >= $max then .pending = "block" else . end)
      end)
    | (batch_items($b)) as $act
    | ([$act[] | select(.pending == null and (has_id($committed; .id) | not))] | length) as $open
    | ([$act[] | select(.pending == null and has_id($committed; .id))] | length) as $ready
    | set_batch($b; .pushed = true | .head_sha = $sha | .worker_started_at = null
        | .phase = (if $open == 0 and $ready > 0 then "open-pr"
                    elif $open == 0 and $ready == 0 then "blocking"
                    else "implement" end))'
  bl_log "worker-done batch=$b sha=$sha phase=$(bq "$b" '.phase') committed=$(printf '%s' "$done_ids" | jq -c .)"
  printf 'Batch %s: phase %s.\n' "$b" "$(bq "$b" '.phase')"
}

record_worker_failed() {
  local b="$1" reason="worker failed" done_ids
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="$2"; shift 2 ;; *) shift ;; esac
  done
  require_batch "$b"
  require_phase "$b" working
  fetch_ref "$(bq "$b" '.branch')"
  done_ids="$(trailer_ids "$b" Backlog-Item | ids_json)"
  upd --argjson b "$b" --argjson committed "$done_ids" --arg msg "$reason" \
    --argjson max "$(max_attempts)" "$JQ_DEFS"'
    set_items($b;
      if .pending != null or .research == "pending" or has_id($committed; .id) then .
      else .attempts += 1 | .last_error = $msg
        | (if .attempts >= $max then .pending = "block" else . end)
      end)
    | ([batch_items($b)[] | select(.pending == null)] | length) as $left
    | set_batch($b; .worker_started_at = null | .last_error = $msg
        | .pushed = (.pushed or ($committed | length) > 0)
        | .phase = (if $left == 0 then "blocking" else "implement" end))'
  bl_log "worker-failed batch=$b reason=$reason"
  printf 'Batch %s: worker failure recorded, phase %s.\n' "$b" "$(bq "$b" '.phase')"
}

record_unclear() {
  local i="$1" q=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --question) q="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$(iq "$i" '.id')" ] || bl_die "unknown item: $i"
  [ -n "$q" ] || bl_die "usage: state.sh record unclear <item> --question \"...\""
  case "$(iq "$i" '.status')" in todo | in-progress) ;; *) bl_die "item $i is $(iq "$i" '.status')" ;; esac
  if [ "$(iq "$i" '.research_passes')" -ge "$(bl_limit research_passes)" ]; then
    bl_die "item $i already used its research budget. Work from $(iq "$i" '.decision'); ambiguity is not a blocker."
  fi
  upd --arg i "$i" --arg q "$q" "$JQ_DEFS"'set_item($i; .research = "pending" | .question = $q)'
  bl_log "unclear item=$i question=$q"
  printf 'Item %s is queued for research.\n' "$i"
}

record_decision() {
  local i="$1" conf="" file heading body
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --confidence) conf="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$(iq "$i" '.id')" ] || bl_die "unknown item: $i"
  case "$conf" in high | medium | low) ;; *) bl_die "--confidence must be high, medium or low" ;; esac
  [ "$(iq "$i" '.research')" = "pending" ] || bl_die "item $i has no research pending"
  file="$BL_DIR/decisions/$i.md"
  [ -s "$file" ] || bl_die "write the decision record to $file first"
  for heading in Question Options Choice Evidence Assumptions Confidence; do
    grep -qiE "^#+[[:space:]]*$heading" "$file" || bl_die "$file has no \"$heading\" section"
  done
  upd --arg i "$i" --arg conf "$conf" "$JQ_DEFS"'
    set_item($i; .research = "done" | .research_passes += 1 | .decision = "decisions/\($i).md"
      | .confidence = $conf | .needs_review = ($conf == "low"))'
  body="$(printf '**backlog-loop decision** (confidence: %s)\n\n' "$conf"; cat "$file")"
  mirror_comment "$i" "$body"
  if [ "$conf" = "low" ]; then mirror_label "$i" needs-review FBCA04; fi
  bl_log "decision item=$i confidence=$conf"
  printf 'Decision for %s recorded (confidence %s).\n' "$i" "$conf"
}

record_hard_blocker() {
  local i="$1" reason="" b
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$(iq "$i" '.id')" ] || bl_die "unknown item: $i"
  [ -n "$reason" ] || bl_die "usage: state.sh record hard-blocker <item> --reason \"...\""
  case "$(iq "$i" '.status')" in todo | in-progress) ;; *) bl_die "item $i is $(iq "$i" '.status')" ;; esac
  b="$(iq "$i" '.batch // empty')"
  if [ -n "$b" ] && trailer_ids "$b" Backlog-Item | grep -qxF "$i"; then
    # Its commit is already on the batch branch: revert that first, then block.
    upd --arg i "$i" --arg r "hard blocker: $reason" --argjson max "$(max_attempts)" "$JQ_DEFS"'
      set_item($i; .pending = "drop" | .attempts = $max | .last_error = $r)'
  else
    upd --arg i "$i" --arg r "hard blocker: $reason" "$JQ_DEFS"'set_item($i; .pending = "block" | .last_error = $r)'
  fi
  bl_log "hard-blocker item=$i reason=$reason"
  printf 'Item %s will be blocked.\n' "$i"
}

record_pr_opened() {
  local b="$1" branch pr
  require_batch "$b"
  require_phase "$b" open-pr
  branch="$(bq "$b" '.branch')"
  pr="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
  [ -n "$pr" ] || bl_die "GitHub shows no open PR with head $branch; create it first"
  upd --argjson b "$b" --argjson pr "$pr" --argjson now "$(bl_now)" "$JQ_DEFS"'
    set_batch($b; .pr = $pr | .phase = "ci" | .ci_started_at = $now | .ci_polls = 0)'
  bl_log "pr-opened batch=$b pr=$pr"
  printf 'Batch %s: PR #%s recorded.\n' "$b" "$pr"
}

# Called by ci-wait.sh only.
record_ci() {
  local b="$1" result="$2" detail="${3:-}"
  require_batch "$b"
  require_phase "$b" ci
  case "$result" in
    poll)
      upd --argjson b "$b" "$JQ_DEFS"'set_batch($b; .ci_polls += 1)'
      return 0
      ;;
    green)
      upd --argjson b "$b" "$JQ_DEFS"'
        if .run.flags.no_merge
        then set_batch($b; .status = "pr-ready" | .phase = null)
        else set_batch($b; .phase = "merge" | .premerge_sha = null) end'
      ;;
    red)
      if [ "$(bq "$b" '.ci_reruns')" -lt "$(bl_limit ci_reruns)" ]; then
        upd --argjson b "$b" --arg d "$detail" "$JQ_DEFS"'set_batch($b; .phase = "ci-rerun" | .last_error = "CI red: \($d)")'
      else
        upd --argjson b "$b" --arg msg "CI red: $detail" --argjson max "$(max_attempts)" \
          "$JQ_DEFS"'fail_batch($b; $msg; $max; true; "fix")'
      fi
      ;;
    timeout)
      upd --argjson b "$b" --arg msg "CI timeout: checks did not finish within $(bl_limit ci_wait_minutes) minutes" \
        --argjson max "$(max_attempts)" "$JQ_DEFS"'fail_batch($b; $msg; $max; true; "fix")'
      ;;
    *) bl_die "unknown CI result: $result" ;;
  esac
  bl_log "ci batch=$b result=$result phase=$(bq "$b" '.phase // "none"') $detail"
}

record_ci_rerun() {
  local b="$1"
  require_batch "$b"
  require_phase "$b" ci-rerun
  upd --argjson b "$b" --argjson now "$(bl_now)" "$JQ_DEFS"'
    set_batch($b; .ci_reruns += 1 | .phase = "ci" | .ci_started_at = $now | .ci_polls = 0)'
  bl_log "ci-rerun batch=$b"
}

record_ci_retry() {
  local b="$1"
  require_batch "$b"
  require_phase "$b" fix
  case "$(bq "$b" '.last_error // ""')" in
    "CI timeout"*) ;;
    *) bl_die "ci-retry is only for CI timeouts; push a fix and record fix-pushed instead" ;;
  esac
  upd --argjson b "$b" --argjson now "$(bl_now)" "$JQ_DEFS"'
    set_batch($b; .phase = "ci" | .ci_started_at = $now | .ci_polls = 0)'
  bl_log "ci-retry batch=$b"
}

record_fix_pushed() {
  local b="$1" branch sha
  require_batch "$b"
  require_phase "$b" fix
  branch="$(bq "$b" '.branch')"
  fetch_ref "$branch"
  sha="$(remote_sha "$branch")"
  [ -n "$sha" ] && [ "$sha" != "$(bq "$b" '.head_sha')" ] ||
    bl_die "branch $branch has no new commit since the failure; nothing was fixed"
  upd --argjson b "$b" --arg sha "$sha" --argjson now "$(bl_now)" "$JQ_DEFS"'
    set_batch($b; .fixes += 1 | .head_sha = $sha | .phase = "ci" | .ci_started_at = $now | .ci_polls = 0)'
  bl_log "fix-pushed batch=$b sha=$sha"
  printf 'Batch %s: fix recorded, waiting for CI.\n' "$b"
}

record_poison() {
  local b="$1" i="$2" reason="poisons the batch"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="$2"; shift 2 ;; *) shift ;; esac
  done
  require_batch "$b"
  require_phase "$b" fix ci ci-rerun merge rebase conflict
  [ "$(iq "$i" '.batch')" = "$b" ] || bl_die "item $i is not in batch $b"
  upd --argjson b "$b" --arg i "$i" --arg r "$reason" "$JQ_DEFS"'
    (.batches[] | select(.id == $b) | .failures) as $f
    | set_items($b; if .id == $i then .pending = "drop" | .last_error = $r
                    elif .pending == null then .attempts = ([.attempts - $f, 0] | max) else . end)
    | set_batch($b; .failures = 0)'
  bl_log "poison batch=$b item=$i reason=$reason"
  printf 'Item %s will be dropped from batch %s.\n' "$i" "$b"
}

record_item_dropped() {
  local i="$1" b branch sha
  [ "$(iq "$i" '.pending')" = "drop" ] || bl_die "item $i is not waiting to be dropped"
  b="$(iq "$i" '.batch')"
  branch="$(bq "$b" '.branch')"
  fetch_ref "$branch"
  trailer_ids "$b" Backlog-Drop | grep -qxF "$i" ||
    bl_die "no commit with trailer \"Backlog-Drop: $i\" on $branch; the revert was not pushed"
  sha="$(remote_sha "$branch")"
  upd --argjson b "$b" --arg i "$i" --arg sha "$sha" --argjson now "$(bl_now)" \
    --argjson max "$(max_attempts)" "$JQ_DEFS"'
    ([.batches[].id] | max + 1) as $nid
    | ([.batches[].order] | max + 1) as $last
    | (.items[] | select(.id == $i)) as $it
    | set_batch($b; .items -= [$i] | .removed += [$i] | .head_sha = $sha
        | if .pr != null then .phase = "ci" | .ci_started_at = $now | .ci_polls = 0 else . end)
    | if $it.attempts >= $max then
        set_item($i; .batch = null | .pending = "block")
      else
        set_item($i; .batch = $nid | .pending = null | .status = "todo")
        | .batches += [new_batch($nid; "Retry of \($i): \($it.title)"; [$i]; []; $last) | .retry_of = $b]
        | .batches |= map(if (.depends_on | index($b)) != null and .id != $nid then .depends_on += [$nid] else . end)
      end'
  settle_batch "$b"
  bl_log "item-dropped item=$i from batch=$b"
  printf 'Item %s dropped from batch %s.\n' "$i" "$b"
}

record_behind() {
  require_batch "$1"
  require_phase "$1" merge
  upd --argjson b "$1" "$JQ_DEFS"'set_batch($b; .phase = "rebase" | .premerge_sha = null)'
  bl_log "behind batch=$1"
}

# Checks stopped being green between the CI wait and the merge.
record_recheck() {
  require_batch "$1"
  require_phase "$1" merge
  upd --argjson b "$1" --argjson now "$(bl_now)" "$JQ_DEFS"'
    set_batch($b; .phase = "ci" | .premerge_sha = null | .ci_started_at = $now | .ci_polls = 0)'
  bl_log "recheck batch=$1"
}

record_rebased() {
  local b="$1" sha
  require_batch "$b"
  require_phase "$b" rebase
  fetch_ref "$(bq "$b" '.branch')"
  sha="$(remote_sha "$(bq "$b" '.branch')")"
  upd --argjson b "$b" --arg sha "$sha" --argjson now "$(bl_now)" "$JQ_DEFS"'
    set_batch($b; .phase = "ci" | .head_sha = $sha | .ci_started_at = $now | .ci_polls = 0)'
  bl_log "rebased batch=$b"
}

record_conflict() {
  local b="$1"
  require_batch "$b"
  require_phase "$b" rebase merge
  if [ "$(bq "$b" '.conflict_attempts')" -ge 1 ]; then
    requeue_batch "$b"
  else
    upd --argjson b "$b" "$JQ_DEFS"'set_batch($b; .phase = "conflict" | .last_error = "merge conflict with the base branch")'
  fi
  bl_log "conflict batch=$b phase=$(bq "$b" '.phase // "none"')"
}

record_conflict_resolved() {
  local b="$1" branch base sha
  require_batch "$b"
  require_phase "$b" conflict
  branch="$(bq "$b" '.branch')"
  base="$(bl_cfg base_branch)"
  fetch_ref "$branch" "$base"
  sha="$(remote_sha "$branch")"
  if [ -n "$sha" ] && git -C "$BL_ROOT" merge-base --is-ancestor "origin/$base" "origin/$branch" 2>/dev/null; then
    upd --argjson b "$b" --arg sha "$sha" --argjson now "$(bl_now)" "$JQ_DEFS"'
      set_batch($b; .conflict_attempts += 1 | .head_sha = $sha | .phase = "ci" | .ci_started_at = $now | .ci_polls = 0)'
    bl_log "conflict-resolved batch=$b"
    printf 'Batch %s: conflict resolved, waiting for CI.\n' "$b"
  else
    bl_log "conflict-resolved rejected for batch=$b: $branch does not contain origin/$base"
    requeue_batch "$b"
    printf 'Batch %s: the branch still lacks the base branch tip; the batch was re-queued.\n' "$b"
  fi
}

record_conflict_failed() {
  require_batch "$1"
  require_phase "$1" conflict
  requeue_batch "$1"
  printf 'Batch %s re-queued.\n' "$1"
}

# Called by verify-batch.sh only.
record_premerge_ok() {
  require_batch "$1"
  require_phase "$1" merge
  upd --argjson b "$1" --arg sha "$2" "$JQ_DEFS"'set_batch($b; .premerge_sha = $sha)'
  bl_log "premerge-ok batch=$1 sha=$2"
}

record_merged() {
  require_batch "$1"
  require_phase "$1" merge ci rebase post-merge
  upd --argjson b "$1" --arg c "${2:-}" "$JQ_DEFS"'set_batch($b; .phase = "post-merge" | .merge_commit = $c)'
  bl_log "merged batch=$1 commit=${2:-unknown}"
}

record_merge_failed() {
  local b="$1" reason="${2:-merge refused}"
  require_batch "$b"
  require_phase "$b" merge
  upd --argjson b "$b" --arg r "$reason" "$JQ_DEFS"'
    set_batch($b; .merge_tries += 1 | .premerge_sha = null | .last_error = $r)
    | if (.batches[] | select(.id == $b) | .merge_tries) >= 3
      then set_items($b; .pending = "block" | .last_error = "merge refused 3 times: \($r)") | set_batch($b; .phase = "blocking")
      else . end'
  bl_log "merge-failed batch=$b reason=$reason"
}

record_post_merge() {
  local b="$1" result="$2" detail="${3:-}" pr id
  require_batch "$b"
  require_phase "$b" post-merge
  pr="$(bq "$b" '.pr')"
  if [ "$result" = "pass" ]; then
    upd --argjson b "$b" "$JQ_DEFS"'
      set_items($b; .status = "merged" | .pending = null) | set_batch($b; .status = "merged" | .phase = null)'
    jq -r --argjson b "$b" '.items[] | select(.batch == $b and .status == "merged") | .id' "$BL_STATE" |
      while IFS= read -r id; do mirror_merged "$id" "$pr"; done
    git -C "$BL_ROOT" push -q origin --delete "$(bq "$b" '.branch')" >/dev/null 2>&1 || true
    cmd_cleanup "$b"
  else
    upd --argjson b "$b" --arg d "$detail" "$JQ_DEFS"'
      set_batch($b; .phase = "revert" | .last_error = "base branch red after merge: \($d)")'
  fi
  bl_log "post-merge batch=$b result=$result $detail"
}

record_revert_opened() {
  local b="$1" pr="${2:-}"
  require_batch "$b"
  require_phase "$b" revert
  case "$pr" in '' | *[!0-9]*) bl_die "usage: state.sh record revert-opened <batch> <revert-pr-number>" ;; esac
  upd --argjson b "$b" --argjson pr "$pr" "$JQ_DEFS"'set_batch($b; .revert_pr = $pr)'
  bl_log "revert-opened batch=$b pr=$pr"
}

block_batch_and_halt() {
  local b="$1" why="$2" needs="$3" halt="$4" id
  upd --argjson b "$b" --arg why "$why" --arg needs "$needs" --arg halt "$halt" "$JQ_DEFS"'
    (.batches[] | select(.id == $b)) as $bt
    | .items |= map(if .batch == $b and .status != "blocked" then .status = "blocked" | .pending = null
        | .blocked_reason = {tried: "merged in PR #\($bt.pr)", why: $why, needs: $needs} else . end)
    | set_batch($b; .status = "blocked" | .phase = null)
    | .run.status = "halted" | .run.halt_reason = $halt'
  jq -r --argjson b "$b" '.items[] | select(.batch == $b) | .id' "$BL_STATE" |
    while IFS= read -r id; do mirror_blocked "$id"; done
}

record_reverted() {
  local b="$1" rpr state
  require_batch "$b"
  require_phase "$b" revert
  rpr="$(bq "$b" '.revert_pr // empty')"
  [ -n "$rpr" ] || bl_die "no revert PR recorded; run: state.sh record revert-opened $b <pr>"
  state="$(bl_pr_field "$rpr" state)"
  [ "$state" = "MERGED" ] || bl_die "revert PR #$rpr is $state, not MERGED"
  block_batch_and_halt "$b" "$(bq "$b" '.last_error')" \
    "fix the regression and re-queue the items; the merge was reverted in PR #$rpr" \
    "base branch was red after merging batch $b (PR #$(bq "$b" '.pr')); reverted in PR #$rpr"
  bl_lock_release
  bl_log "reverted batch=$b revert_pr=$rpr; run halted"
  printf 'Batch %s reverted and blocked. The loop is halted.\n' "$b"
}

record_revert_failed() {
  local b="$1" reason="unknown"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="$2"; shift 2 ;; *) shift ;; esac
  done
  require_batch "$b"
  require_phase "$b" revert
  block_batch_and_halt "$b" "$(bq "$b" '.last_error')" \
    "revert PR #$(bq "$b" '.pr') by hand; the automatic revert failed: $reason" \
    "URGENT: base branch is red after merging batch $b (PR #$(bq "$b" '.pr')) and the revert failed: $reason"
  bl_lock_release
  bl_log "revert-failed batch=$b reason=$reason; run halted"
  printf 'Batch %s blocked. The loop is halted and the base branch needs a manual revert.\n' "$b"
}

# Called by mark-blocked.sh only.
record_blocked() {
  local i="$1" tried="" why="" needs="" b
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --tried) tried="$2"; shift 2 ;;
      --why) why="$2"; shift 2 ;;
      --needs) needs="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$(iq "$i" '.id')" ] || bl_die "unknown item: $i"
  [ "$(iq "$i" '.status')" != "merged" ] || bl_die "item $i is already merged"
  b="$(iq "$i" '.batch // empty')"
  if [ -n "$b" ] && [ "$(iq "$i" '.pending')" != "block" ] && trailer_ids "$b" Backlog-Item | grep -qxF "$i"; then
    case "$(bq "$b" '.phase // "none"')" in
      blocking | none) ;;
      *) bl_die "item $i has a commit on the batch branch. Drop it first: state.sh record poison $b $i --reason \"...\"" ;;
    esac
  fi
  upd --arg i "$i" --arg tried "$tried" --arg why "$why" --arg needs "$needs" "$JQ_DEFS"'
    (.items[] | select(.id == $i) | .batch) as $b
    | set_item($i; .status = "blocked" | .pending = null | .batch = null
        | .blocked_reason = {tried: $tried, why: $why, needs: $needs})
    | if $b != null then set_batch($b; .items -= [$i] | .removed += [$i]) else . end'
  if [ -n "$b" ]; then settle_batch "$b"; fi
  mirror_blocked "$i"
  bl_log "blocked item=$i why=$why"
}

record_run() {
  local status="$1" reason="${2:-}"
  case "$status" in halted | stalled | done) ;; *) bl_die "unknown run status: $status" ;; esac
  upd --arg s "$status" --arg r "$reason" '.run.status = $s | .run.halt_reason = (if $r == "" then null else $r end)'
  bl_lock_release
  bl_log "run status=$status $reason"
}

cmd_record() {
  local event="${1:-}"
  need_state
  [ $# -gt 0 ] || bl_die "usage: state.sh record <event> [args]"
  shift
  [ $# -gt 0 ] || bl_die "state.sh record $event: missing id"
  bl_lock_touch
  case "$event" in
    worker-started) record_worker_started "$@" ;;
    worker-done) record_worker_done "$@" ;;
    worker-failed) record_worker_failed "$@" ;;
    unclear) record_unclear "$@" ;;
    decision) record_decision "$@" ;;
    hard-blocker) record_hard_blocker "$@" ;;
    pr-opened) record_pr_opened "$@" ;;
    ci) record_ci "$@" ;;
    ci-rerun) record_ci_rerun "$@" ;;
    ci-retry) record_ci_retry "$@" ;;
    fix-pushed) record_fix_pushed "$@" ;;
    poison) [ $# -ge 2 ] || bl_die "usage: state.sh record poison <batch> <item> --reason \"...\""; record_poison "$@" ;;
    item-dropped) record_item_dropped "$@" ;;
    behind) record_behind "$@" ;;
    rebased) record_rebased "$@" ;;
    recheck) record_recheck "$@" ;;
    conflict) record_conflict "$@" ;;
    conflict-resolved) record_conflict_resolved "$@" ;;
    conflict-failed) record_conflict_failed "$@" ;;
    premerge-ok) record_premerge_ok "$@" ;;
    merged) record_merged "$@" ;;
    merge-failed) record_merge_failed "$@" ;;
    post-merge) [ $# -ge 2 ] || bl_die "usage: state.sh record post-merge <batch> pass|fail"; record_post_merge "$@" ;;
    revert-opened) record_revert_opened "$@" ;;
    reverted) record_reverted "$@" ;;
    revert-failed) record_revert_failed "$@" ;;
    blocked) record_blocked "$@" ;;
    run) record_run "$@" ;;
    *) bl_die "unknown event: $event" ;;
  esac
}

# --- resume, backlog file sync -----------------------------------------------

# Bring in-flight batches in line with what GitHub and git actually show.
cmd_reconcile() {
  local b pr phase status st
  need_state
  bl_get '.batches[] | select(.status == "in-progress" or .status == "pr-ready") | .id' | while IFS= read -r b; do
    pr="$(bq "$b" '.pr // empty')"
    phase="$(bq "$b" '.phase // "none"')"
    status="$(bq "$b" '.status')"
    if [ -z "$pr" ]; then
      if [ "$phase" = "working" ]; then
        upd --argjson b "$b" "$JQ_DEFS"'set_batch($b; .phase = "implement" | .worker_started_at = null)'
        bl_log "reconcile batch=$b: worker lost, back to implement"
      fi
      continue
    fi
    st="$(bl_pr_field "$pr" state)"
    case "$st" in
      MERGED)
        upd --argjson b "$b" "$JQ_DEFS"'set_batch($b; .status = "in-progress" | .phase = "post-merge")'
        bl_log "reconcile batch=$b: PR #$pr is merged, verifying the base branch next"
        ;;
      CLOSED)
        case "$phase" in
          revert | blocking) ;;
          *)
            upd --argjson b "$b" "$JQ_DEFS"'
              if (.batches[] | select(.id == $b) | .kind) == "status" then set_batch($b; .status = "closed" | .phase = null)
              else set_items($b; .status = "todo")
                | set_batch($b; .status = "todo" | .phase = null | .try += 1 | .old_branches += [.branch]
                    | .branch = null | .pr = null | .pushed = false | .head_sha = null | .premerge_sha = null)
              end'
            bl_log "reconcile batch=$b: PR #$pr was closed, batch reset to todo"
            ;;
        esac
        ;;
      OPEN)
        if [ "$status" = "pr-ready" ]; then
          if [ "$(bl_get '.run.flags.no_merge')" != "true" ]; then
            upd --argjson b "$b" --argjson now "$(bl_now)" "$JQ_DEFS"'
              set_batch($b; .status = "in-progress" | .phase = "ci" | .ci_started_at = $now | .ci_polls = 0)'
          fi
        elif [ "$phase" = "working" ]; then
          upd --argjson b "$b" "$JQ_DEFS"'set_batch($b; .phase = "implement" | .worker_started_at = null)'
        elif [ "$phase" = "ci" ]; then
          upd --argjson b "$b" --argjson now "$(bl_now)" "$JQ_DEFS"'set_batch($b; .ci_started_at = $now | .ci_polls = 0)'
        fi
        ;;
      *) bl_log "reconcile batch=$b: could not read PR #$pr, left as is" ;;
    esac
  done
  upd '
    ([.batches[] | select(.status == "todo") | .id]) as $todo
    | .items |= map(if .status == "in-progress" and (.batch as $b | any($todo[]; . == $b)) then .status = "todo" else . end)'
  bl_log "reconcile done"
}

# file source: put the status changes of this run on a branch, as a final PR.
cmd_sync_backlog() {
  local path base branch wt edits sha
  need_state
  [ "$(bl_cfg source)" = "file" ] || bl_die "sync-backlog is only for source: file"
  [ "$(bl_get '[.batches[] | select(.kind == "status")] | length')" = "0" ] || bl_die "a status batch already exists"
  path="$(bl_cfg path)"
  base="$(bl_cfg base_branch)"
  branch="backlog-loop/$(bl_get '.run.id')/status"
  wt="$BL_DIR/sync-worktree"
  edits="$BL_DIR/sync-edits.tsv"
  jq -r '.items[] | select(.preblocked | not)
    | if .status == "merged" then "\(.id)\tdone\t"
      elif .status == "blocked" then "\(.id)\tblocked\t\((.blocked_reason.why // "") + (if .blocked_reason.needs then " Needs: " + .blocked_reason.needs else "" end) | gsub("[\\n\\t|]"; " "))"
      else empty end' "$BL_STATE" >"$edits"
  fetch_ref "$base"
  git -C "$BL_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$BL_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  git -C "$BL_ROOT" worktree add -q -b "$branch" "$wt" "origin/$base" >/dev/null 2>&1 ||
    bl_die "could not create a worktree for the backlog status branch"
  awk -v mode=apply -v edits="$edits" -f "$BL_SCRIPT_DIR/backlog.awk" "$wt/$path" >"$wt/$path.new" &&
    mv -f "$wt/$path.new" "$wt/$path"
  if git -C "$wt" diff --quiet; then
    git -C "$BL_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$BL_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
    upd '.run.sync = "skipped"'
    bl_log "sync-backlog: nothing to change in $path"
    printf 'Nothing to update in %s.\n' "$path"
    return 0
  fi
  if ! { git -C "$wt" add "$path" &&
    git -C "$wt" commit -q -m "chore(backlog): update item status after backlog-loop run" &&
    git -C "$wt" push -q origin "$branch"; }; then
    git -C "$BL_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
    upd '.run.sync = "failed"'
    bl_die "could not commit and push the backlog status branch"
  fi
  sha="$(git -C "$wt" rev-parse HEAD)"
  git -C "$BL_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$BL_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  upd --arg branch "$branch" --arg sha "$sha" "$JQ_DEFS"'
    ([.batches[].id] | max + 1) as $id
    | ([.batches[].order] | max + 1) as $order
    | .run.sync = "opened"
    | .batches += [new_batch($id; "Backlog status update"; []; []; $order)
        | .kind = "status" | .title = "chore(backlog): update item status"
        | .status = "in-progress" | .phase = "open-pr" | .branch = $branch | .pushed = true | .head_sha = $sha]'
  bl_log "sync-backlog: pushed $branch"
  printf 'Backlog status branch pushed: %s\n' "$branch"
}

# Create the pull request of a batch, or pick up one that already exists.
cmd_open_pr() {
  local b="$1" branch body out
  need_state
  require_batch "$b"
  require_phase "$b" open-pr
  branch="$(bq "$b" '.branch')"
  if [ -z "$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)" ]; then
    body="$BL_DIR/pr-body.md"
    cmd_pr_body "$b" >"$body"
    out="$(gh pr create --base "$(bl_cfg base_branch)" --head "$branch" \
      --title "$(cmd_pr_title "$b")" --body-file "$body" 2>&1)" || bl_die "gh pr create failed: $out"
  fi
  record_pr_opened "$b"
}

# Transitions that need no agent: worker deadlines, dependencies on blocked
# batches, and batches that have nothing left to block.
cmd_housekeeping() {
  local now wait_min b
  need_state
  now="$(bl_now)"
  wait_min="$(bl_limit worker_wait_minutes)"
  jq -r --argjson now "$now" --argjson max "$((${wait_min:-120} * 60))" '
    .batches[] | select(.phase == "working" and .worker_started_at != null
      and ($now - .worker_started_at) >= $max) | .id' "$BL_STATE" | while IFS= read -r b; do
    record_worker_failed "$b" --reason "worker exceeded the ${wait_min:-120}-minute deadline" >/dev/null
  done
  upd "$JQ_DEFS"'
    [.batches[] | select(.status == "blocked" and .retry_of == null) | .id] as $dead
    | [.batches[] | select(.status == "todo") | select(any(.depends_on[]; . as $d | any($dead[]; . == $d))) | .id] as $stuck
    | .items |= map(if (.batch as $b | any($stuck[]; . == $b)) and live and .pending == null
        then .pending = "block" | .last_error = "depends on batch that is blocked" else . end)
    | reduce (.batches[] | select(.phase == "blocking") | .id) as $b (.;
        if (batch_items($b) | length) == 0 then set_batch($b; .status = "blocked" | .phase = null)
        else set_items($b; if .pending == null then .pending = "block" else . end) end)'
}

# Stop-gate bookkeeping: last hash, unchanged-gate counter, consecutive blocks.
cmd_gate() {
  need_state
  upd --arg h "$1" --argjson u "$2" --argjson g "$3" --arg mode "${4:-}" '
    .run.last_hash = $h | .run.unchanged_gates = $u | .run.gate_blocks = $g
    | (if $mode != "" then .run.permission_mode = $mode else . end)'
}

cmd_tick() {
  need_state
  upd '.run.iterations += 1 | .run.total_iterations += 1'
}

# --- entry point --------------------------------------------------------------

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  init) cmd_init "$@" ;;
  resume) cmd_resume "$@" ;;
  status) cmd_status ;;
  items) cmd_items ;;
  hash) need_state && bl_hash ;;
  get) need_state && bl_get "$@" ;;
  log) bl_log "$*" ;;
  plan-apply) cmd_plan_apply "$@" ;;
  record) cmd_record "$@" ;;
  branch) cmd_branch "$@" ;;
  pr-title) cmd_pr_title "$@" ;;
  pr-body) cmd_pr_body "$@" ;;
  worker-prompt) cmd_worker_prompt "$@" ;;
  research-prompt) cmd_research_prompt "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  reconcile) cmd_reconcile ;;
  sync-backlog) cmd_sync_backlog ;;
  open-pr) cmd_open_pr "$@" ;;
  housekeeping) cmd_housekeeping ;;
  tick) cmd_tick ;;
  gate) cmd_gate "$@" ;;
  archive) cmd_archive ;;
  unlock) bl_lock_release ;;
  *) bl_die "usage: state.sh <init|resume|status|items|hash|get|log|plan-apply|record|branch|pr-title|pr-body|worker-prompt|research-prompt|cleanup|reconcile|sync-backlog|archive|unlock>" ;;
esac
