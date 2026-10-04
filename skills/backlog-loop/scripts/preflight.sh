#!/usr/bin/env bash
# preflight.sh: check everything the loop needs, before anything is changed.
#
#   preflight.sh [--plan-only] [--resume] [--no-merge] [--gitignore] [--session ID]
#   preflight.sh --probes     print the commands Claude must be allowed to run
#
# Every check runs, failures are collected and printed together with a fix.
# On failure nothing is changed and the exit status is 1. On success the state
# directory is ignored, the resolved configuration is written, and the run is
# created (or resumed when an unfinished run exists).
# shellcheck disable=SC2016
set -u
BL_SELF=preflight
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN_ONLY=0
RESUME=0
NO_MERGE=0
GITIGNORE=0
PROBES=0
SESSION="unknown"
while [ $# -gt 0 ]; do
  case "$1" in
    --plan-only) PLAN_ONLY=1 ;;
    --resume) RESUME=1 ;;
    --no-merge) NO_MERGE=1 ;;
    --gitignore) GITIGNORE=1 ;;
    --probes) PROBES=1 ;;
    --session) SESSION="${2:-unknown}"; shift ;;
    *) printf 'preflight: ignoring unknown argument %s\n' "$1" >&2 ;;
  esac
  shift
done

PASSED=0
FAILED=0
WARNED=0
REPORT=""
NL='
'
pass() { PASSED=$((PASSED + 1)); }
fail() {
  FAILED=$((FAILED + 1))
  REPORT="${REPORT}FAIL  $1: $2${NL}      Fix: $3${NL}"
}
warn() {
  WARNED=$((WARNED + 1))
  REPORT="${REPORT}WARN  $1: $2${NL}"
}

finish() {
  printf 'Preflight: %s passed, %s failed, %s warning%s\n' "$PASSED" "$FAILED" "$WARNED" "$([ "$WARNED" -eq 1 ] || printf s)"
  printf '%s' "$REPORT"
  if [ "$FAILED" -gt 0 ]; then
    echo "Nothing was changed."
    exit 1
  fi
}

# --- Tools ---------------------------------------------------------------------

missing=""
for tool in git gh jq; do
  bl_have "$tool" || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  fail "Tools" "not installed:$missing" "install$missing and make sure they are on PATH"
  finish
fi
pass

if ! bl_paths; then
  fail "Working tree" "not inside a git repository" "run /backlog-loop from the repository you want to work on"
  finish
fi
cd "$BL_ROOT" || exit 1

# --- Config (section 4) ----------------------------------------------------------

CONFIG_SECTION='## Backlog loop

- source: github          (or: file)
- label: backlog          (github only)
- path: BACKLOG.md        (file only)
- base-branch: main
- test: <command>
- lint: <command, or none>
- build: <command, or none>
- merge-method: squash    (or: merge, rebase)'

section_text=""
for f in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
  if [ -f "$f" ] && grep -qiE '^##[[:space:]]+backlog loop[[:space:]]*$' "$f"; then
    section_text="$(awk '
      tolower($0) ~ /^##[ \t]+backlog loop[ \t]*$/ { on = 1; next }
      /^##[ \t]/ { on = 0 }
      on { print }' "$f")"
    break
  fi
done

cfg_raw() {
  printf '%s\n' "$section_text" |
    sed -n "s/^[[:space:]]*[-*]\{0,1\}[[:space:]]*\`\{0,1\}$1\`\{0,1\}[[:space:]]*:[[:space:]]*//p" |
    head -n 1 | sed -e 's/[[:space:]]*$//' -e 's/^`\(.*\)`$/\1/'
}

detect_cmd() {
  # detect_cmd <test|lint|build>
  local class="$1" pm script
  if [ -f package.json ]; then
    script="$(jq -r --arg c "$class" '.scripts[$c] // empty' package.json 2>/dev/null)"
    case "$script" in
      "" | *"no test specified"*) ;;
      *)
        pm=npm
        [ -f pnpm-lock.yaml ] && pm=pnpm
        [ -f yarn.lock ] && pm=yarn
        if [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun; fi
        if [ "$class" = "test" ]; then echo "$pm test"; else echo "$pm run $class"; fi
        return 0
        ;;
    esac
  fi
  if [ -f Makefile ] && grep -qE "^$class:" Makefile; then
    echo "make $class"
    return 0
  fi
  if [ -f Cargo.toml ]; then
    case "$class" in
      test) echo "cargo test" ;;
      lint) echo "cargo clippy -- -D warnings" ;;
      build) echo "cargo build" ;;
    esac
    return 0
  fi
  if [ -f go.mod ]; then
    case "$class" in
      test) echo "go test ./..." ;;
      lint) echo "go vet ./..." ;;
      build) echo "go build ./..." ;;
    esac
    return 0
  fi
  if [ -f pyproject.toml ]; then
    case "$class" in
      test) if grep -q pytest pyproject.toml; then echo "pytest"; return 0; fi ;;
      lint) if grep -q ruff pyproject.toml; then echo "ruff check ."; return 0; fi ;;
    esac
  fi
  return 1
}

limit() {
  # limit <config key> <default>
  local v
  v="$(cfg_raw "$1")"
  case "$v" in '' | *[!0-9]*) echo "$2" ;; *) echo "$v" ;; esac
}

REPO_JSON="$(gh repo view --json nameWithOwner,viewerPermission,defaultBranchRef,squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,hasIssuesEnabled 2>/dev/null)"
REPO="$(printf '%s' "$REPO_JSON" | jq -r '.nameWithOwner // empty' 2>/dev/null)"

C_SOURCE="$(cfg_raw source)"
C_LABEL="$(cfg_raw label)"
C_PATH="$(cfg_raw path)"
C_BASE="$(cfg_raw base-branch)"
C_TEST="$(cfg_raw test)"
C_LINT="$(cfg_raw lint)"
C_BUILD="$(cfg_raw build)"
C_METHOD="$(cfg_raw merge-method)"
C_CI="$(cfg_raw ci)"
[ -n "$C_LABEL" ] || C_LABEL="backlog"
[ -n "$C_PATH" ] || C_PATH="BACKLOG.md"
[ -n "$C_METHOD" ] || C_METHOD="squash"
[ -n "$C_CI" ] || C_CI="required"
[ -n "$C_BASE" ] || C_BASE="$(printf '%s' "$REPO_JSON" | jq -r '.defaultBranchRef.name // empty' 2>/dev/null)"
[ -n "$C_BASE" ] || C_BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
[ -n "$C_TEST" ] || C_TEST="$(detect_cmd test)"
[ -n "$C_LINT" ] || C_LINT="$(detect_cmd lint)"
[ -n "$C_BUILD" ] || C_BUILD="$(detect_cmd build)"

config_errors=""
if [ -z "$C_SOURCE" ]; then
  has_file=0
  has_issues=0
  [ -f "$C_PATH" ] && has_file=1
  if [ -n "$REPO" ] && [ "$(gh issue list --label "$C_LABEL" --state open --limit 1 --json number --jq length 2>/dev/null)" = "1" ]; then
    has_issues=1
  fi
  if [ "$has_file" -eq 1 ] && [ "$has_issues" -eq 0 ]; then
    C_SOURCE="file"
  elif [ "$has_file" -eq 0 ] && [ "$has_issues" -eq 1 ]; then
    C_SOURCE="github"
  elif [ "$has_file" -eq 1 ]; then
    config_errors="$config_errors source is ambiguous ($C_PATH and issues labelled '$C_LABEL' both exist);"
  else
    config_errors="$config_errors no backlog found (no $C_PATH, no open issues labelled '$C_LABEL');"
  fi
fi
case "$C_SOURCE" in github | file | "") ;; *) config_errors="$config_errors source must be github or file, not '$C_SOURCE';" ;; esac
case "$C_METHOD" in squash | merge | rebase) ;; *) config_errors="$config_errors merge-method must be squash, merge or rebase;" ;; esac
case "$C_CI" in required | none) ;; *) config_errors="$config_errors ci must be required or none;" ;; esac
[ -n "$C_BASE" ] || config_errors="$config_errors base-branch could not be detected;"
[ -n "$C_TEST" ] || config_errors="$config_errors test command could not be detected;"
[ -n "$C_LINT" ] || config_errors="$config_errors lint command could not be detected (set it, or 'none');"
[ -n "$C_BUILD" ] || config_errors="$config_errors build command could not be detected (set it, or 'none');"
[ "$C_TEST" != "none" ] || config_errors="$config_errors test must be a real command;"

config_errors="${config_errors# }"

if [ "$PROBES" -eq 1 ]; then
  # One harmless command per class. Claude runs each as its own Bash call, so
  # a missing permission shows up now and not hours into an unattended run.
  echo "git status --short"
  echo "gh auth status"
  for c in "$C_TEST" "$C_LINT" "$C_BUILD"; do
    case "$c" in "" | none) ;; *) echo "$c" ;; esac
  done
  exit 0
fi

# An unfinished run is resumed with the configuration it started with.
UNFINISHED=0
if bl_state_ok; then
  case "$(bl_get '.run.status')" in running | halted | stalled) UNFINISHED=1 ;; esac
fi

if [ "$UNFINISHED" -eq 1 ]; then
  pass
elif [ -n "$config_errors" ]; then
  fail "Config" "${config_errors%;}" "add this section to CLAUDE.md and fill it in:${NL}${NL}${CONFIG_SECTION}${NL}"
else
  pass
fi

if [ "$RESUME" -eq 1 ] && [ "$UNFINISHED" -eq 0 ]; then
  fail "Filesystem" "--resume was given but there is no unfinished run in $BL_DIR" "run /backlog-loop without --resume to start a new run"
fi

# --- GitHub auth, repo rights ---------------------------------------------------

if ! auth_out="$(gh auth status 2>&1)"; then
  fail "GitHub auth" "gh is not logged in" "run: gh auth login"
else
  scopes="$(printf '%s\n' "$auth_out" | sed -n 's/.*Token scopes: //p' | head -n 1)"
  if [ -n "$scopes" ] && ! printf '%s' "$scopes" | grep -q "'repo'"; then
    fail "GitHub auth" "token scopes ($scopes) lack 'repo'" "run: gh auth refresh -s repo"
  else
    pass
    if [ -n "$scopes" ] && ! printf '%s' "$scopes" | grep -q "'workflow'"; then
      warn "GitHub auth" "token lacks the 'workflow' scope; items that change .github/workflows cannot be pushed"
    fi
  fi
fi

perm="$(printf '%s' "$REPO_JSON" | jq -r '.viewerPermission // empty' 2>/dev/null)"
case "$perm" in
  ADMIN | MAINTAIN | WRITE) pass ;;
  "") fail "Repo rights" "could not read the repository from GitHub" "check the origin remote and run: gh repo view" ;;
  *) fail "Repo rights" "your permission on $REPO is $perm" "ask for write access to $REPO" ;;
esac

# --- Filesystem: state directory, lock -------------------------------------------

parent="$BL_ROOT"
[ -d "$BL_ROOT/.planning" ] && parent="$BL_ROOT/.planning"
[ -d "$BL_DIR" ] && parent="$BL_DIR"
if [ ! -w "$parent" ]; then
  fail "Filesystem" "$parent is not writable" "make it writable for your user"
elif [ -f "$BL_LOCK" ] && [ "$(bl_lock_owner)" != "$SESSION" ] && bl_lock_fresh "${BACKLOG_LOOP_LOCK_STALE_MINUTES:-15}"; then
  fail "Filesystem" "another session ($(bl_lock_owner)) is running the loop in this repository" \
    "wait for it, or if that session is gone delete $BL_LOCK"
else
  pass
fi
NEEDS_IGNORE=0
git check-ignore -q "$BL_DIR/state.json" 2>/dev/null || NEEDS_IGNORE=1

apply_ignore() {
  [ "$NEEDS_IGNORE" -eq 1 ] || return 0
  if [ "$GITIGNORE" -eq 1 ]; then
    printf '\n.planning/backlog-loop/\n' >>"$BL_ROOT/.gitignore"
    echo "Added .planning/backlog-loop/ to .gitignore (commit it yourself)."
  else
    mkdir -p "$(git rev-parse --git-common-dir)/info"
    printf '.planning/backlog-loop/\n' >>"$(git rev-parse --git-common-dir)/info/exclude"
    echo "Added .planning/backlog-loop/ to .git/info/exclude."
  fi
}

if [ "$UNFINISHED" -eq 1 ]; then
  finish
  apply_ignore
  resume_args="--session $SESSION"
  [ "$PLAN_ONLY" -eq 1 ] && resume_args="$resume_args --plan-only"
  [ "$NO_MERGE" -eq 1 ] && resume_args="$resume_args --no-merge"
  # shellcheck disable=SC2086
  "$BL_SCRIPT_DIR/state.sh" resume $resume_args || exit 1
  echo "Preflight passed (quick checks for a resumed run). Run next.sh."
  exit 0
fi

# --- Working tree -----------------------------------------------------------------

tree_ok=1
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  fail "Working tree" "tracked files have uncommitted changes" "commit or stash them, then start again"
  tree_ok=0
fi
current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -n "$C_BASE" ] && [ "$current" != "$C_BASE" ]; then
  fail "Working tree" "the checkout is on '$current', not on the base branch '$C_BASE'" "run: git checkout $C_BASE"
  tree_ok=0
fi
if [ -n "$C_BASE" ]; then
  if ! git fetch -q origin "$C_BASE" 2>/dev/null; then
    fail "Working tree" "could not fetch $C_BASE from origin" "check the origin remote and your network"
    tree_ok=0
  elif [ "$current" = "$C_BASE" ] && [ "$(git rev-parse HEAD)" != "$(git rev-parse "refs/remotes/origin/$C_BASE" 2>/dev/null)" ]; then
    fail "Working tree" "$C_BASE differs from origin/$C_BASE" "run: git pull --ff-only  (and push or drop local commits)"
    tree_ok=0
  fi
fi
[ "$tree_ok" -eq 0 ] || pass
if git status --porcelain 2>/dev/null | grep '^??' | grep -qv ' \.planning/'; then
  warn "Working tree" "untracked files are present; workers do not see them"
fi

# --- Push: real probe -------------------------------------------------------------

probe="backlog-loop/preflight-probe-$(date +%s)"
if push_out="$(git push -q origin "HEAD:refs/heads/$probe" 2>&1)"; then
  git push -q origin --delete "$probe" >/dev/null 2>&1 ||
    warn "Push" "probe branch $probe could not be deleted; delete it by hand"
  pass
else
  fail "Push" "cannot push a branch to origin: $(printf '%s' "$push_out" | tail -n 1)" "fix your push credentials or branch creation rules"
fi

# --- PR and merge -------------------------------------------------------------------

if [ -n "$REPO_JSON" ]; then
  case "$C_METHOD" in
    squash) allowed="$(printf '%s' "$REPO_JSON" | jq -r '.squashMergeAllowed')" ;;
    merge) allowed="$(printf '%s' "$REPO_JSON" | jq -r '.mergeCommitAllowed')" ;;
    *) allowed="$(printf '%s' "$REPO_JSON" | jq -r '.rebaseMergeAllowed')" ;;
  esac
  if [ "$NO_MERGE" -eq 1 ] || [ "$allowed" = "true" ]; then
    # Auto-merge is never used: the loop merges itself after verifying checks.
    pass
  else
    fail "PR and merge" "merge method '$C_METHOD' is not allowed on $REPO" \
      "enable it in the repository settings, or set merge-method in the Backlog loop section"
  fi
fi

# --- Branch rules -------------------------------------------------------------------

if [ -n "$REPO" ] && [ -n "$C_BASE" ]; then
  rules="$(gh api "repos/$REPO/rules/branches/$C_BASE" 2>/dev/null)"
  protection="$(gh api "repos/$REPO/branches/$C_BASE/protection" 2>/dev/null)"
  printf '%s' "$rules" | jq -e 'type == "array"' >/dev/null 2>&1 || rules="[]"
  printf '%s' "$protection" | jq -e '.url' >/dev/null 2>&1 || protection="{}"
  approvals="$(jq -n --argjson r "$rules" --argjson p "$protection" '
    [($r[] | select(.type == "pull_request") | .parameters.required_approving_review_count // 0),
     ($p.required_pull_request_reviews.required_approving_review_count // 0)] | max')"
  required="$(jq -rn --argjson r "$rules" --argjson p "$protection" '
    [($r[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context),
     ($p.required_status_checks.contexts[]?), ($p.required_status_checks.checks[]?.context)] | unique | .[]')"
  rules_ok=1
  if [ "${approvals:-0}" -gt 0 ] && [ "$NO_MERGE" -eq 0 ]; then
    fail "Branch rules" "$C_BASE requires $approvals approving review$([ "$approvals" -eq 1 ] || printf s)" \
      "allow bypass for your account, or run with --no-merge"
    rules_ok=0
  fi
  if [ -n "$required" ] && [ "$C_CI" != "none" ]; then
    sha="$(git rev-parse "refs/remotes/origin/$C_BASE" 2>/dev/null)"
    reported="$(
      gh api "repos/$REPO/commits/$sha/check-runs" --jq '.check_runs[].name' 2>/dev/null
      gh api "repos/$REPO/commits/$sha/status" --jq '.statuses[].context' 2>/dev/null
    )"
    absent=""
    while IFS= read -r check; do
      [ -n "$check" ] || continue
      printf '%s\n' "$reported" | grep -qxF "$check" || absent="$absent '$check'"
    done <<EOT
$required
EOT
    if [ -n "$absent" ]; then
      fail "Branch rules" "required checks never reported on $C_BASE:$absent" \
        "make the workflows that produce these checks run on pull requests and on $C_BASE, or remove them from the rules"
      rules_ok=0
    fi
  elif [ -z "$required" ] && [ "$C_CI" != "none" ]; then
    warn "Branch rules" "$C_BASE has no required status checks; the loop still waits for every check on each PR"
  fi
  [ "$rules_ok" -eq 0 ] || pass
fi

# --- Issues or backlog file -----------------------------------------------------------

if [ "$C_SOURCE" = "github" ]; then
  if [ "$(printf '%s' "$REPO_JSON" | jq -r '.hasIssuesEnabled // false')" != "true" ]; then
    fail "Issues" "issues are disabled on $REPO" "enable issues, or use source: file"
  elif [ "$(gh issue list --label "$C_LABEL" --state open --limit 1 --json number --jq length 2>/dev/null)" != "1" ]; then
    fail "Issues" "no open issues carry the label '$C_LABEL'" "label the backlog items, or set label in the Backlog loop section"
  else
    # Write access covers commenting and labelling. Missing labels are created after preflight passes.
    pass
  fi
elif [ "$C_SOURCE" = "file" ]; then
  if [ ! -f "$C_PATH" ]; then
    fail "Issues" "backlog file $C_PATH does not exist" "create it, or set path in the Backlog loop section"
  elif ! awk -v mode=list -f "$BL_SCRIPT_DIR/backlog.awk" "$C_PATH" | grep -qv 'blocked$'; then
    fail "Issues" "$C_PATH has no open items" "add items as table rows (ID, Title, Status) or as '- [ ] ID: title' lines"
  else
    pass
  fi
fi

# --- CI ---------------------------------------------------------------------------------

if [ "$C_CI" = "none" ]; then
  pass
elif [ -n "$REPO" ]; then
  workflows=0
  for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] && grep -q "pull_request" "$wf" && workflows=$((workflows + 1))
  done
  sha="$(git rev-parse "refs/remotes/origin/$C_BASE" 2>/dev/null)"
  runs="$(gh api "repos/$REPO/commits/$sha/check-runs" --jq '.total_count' 2>/dev/null)"
  if [ "$workflows" -eq 0 ] && [ "${runs:-0}" = "0" ]; then
    fail "CI" "no workflow runs on pull requests and no checks are reported on $C_BASE" \
      "add a workflow triggered by pull_request, or set 'ci: none' in the Backlog loop section to rely on local test, lint and build"
  else
    pass
    [ "$workflows" -gt 0 ] || warn "CI" "no local workflow has a pull_request trigger; checks seem to come from an external service"
  fi
fi

# --- Worktrees ----------------------------------------------------------------------------

wt_dir="${TMPDIR:-/tmp}/backlog-loop-probe-$$"
if git worktree add -q --detach "$wt_dir" HEAD >/dev/null 2>&1; then
  git worktree remove --force "$wt_dir" >/dev/null 2>&1
  git worktree prune >/dev/null 2>&1
  pass
else
  fail "Worktrees" "git worktree add failed" "run 'git worktree prune' and check that the repository is not bare or locked"
fi

# --- Baseline ---------------------------------------------------------------------------------

if [ -z "$config_errors" ] && [ "$tree_ok" -eq 1 ]; then
  base_ok=1
  out="$(mktemp "${TMPDIR:-/tmp}/backlog-loop-baseline.XXXXXX")"
  mins="$(limit baseline-minutes 30)"
  for class in test lint build; do
    case "$class" in test) c="$C_TEST" ;; lint) c="$C_LINT" ;; *) c="$C_BUILD" ;; esac
    [ "$c" != "none" ] || continue
    bl_with_deadline $((mins * 60)) "$out" "$c"
    rc=$?
    if [ "$rc" -eq 124 ]; then
      fail "Baseline" "'$c' did not finish within $mins minutes on $C_BASE" "make it faster, or raise baseline-minutes in the Backlog loop section"
      base_ok=0
    elif [ "$rc" -ne 0 ]; then
      fail "Baseline" "'$c' fails on $C_BASE: $(tail -n 2 "$out" | tr '\n' ' ' | cut -c1-200)" "$C_BASE must be green before starting"
      base_ok=0
    fi
  done
  rm -f "$out"
  [ "$base_ok" -eq 0 ] || pass
else
  warn "Baseline" "skipped because the configuration or the working tree check failed"
fi

# --- Claude tools: deny and ask rules in settings ------------------------------------------------

RESEARCH_WEB=true
rule_matches() {
  # rule_matches <Bash rule pattern> <command>
  local pat="$1" cmd="$2"
  pat="${pat%:\*}"
  [ "$pat" = "$1" ] || pat="$pat *"
  # shellcheck disable=SC2254
  case "$cmd" in $pat) return 0 ;; esac
  case "$pat" in
    *" *")
      # shellcheck disable=SC2254
      case "$cmd" in ${pat% \*}) return 0 ;; esac
      ;;
  esac
  return 1
}

tools_ok=1
for settings in "$HOME/.claude/settings.json" "$BL_ROOT/.claude/settings.json" "$BL_ROOT/.claude/settings.local.json" \
  "/Library/Application Support/ClaudeCode/managed-settings.json" "/etc/claude-code/managed-settings.json"; do
  [ -f "$settings" ] || continue
  for kind in deny ask; do
    rules_list="$(jq -r --arg k "$kind" '.permissions[$k][]? // empty' "$settings" 2>/dev/null)"
    [ -n "$rules_list" ] || continue
    while IFS= read -r rule; do
      case "$rule" in
        Bash | "Bash(*)" | Agent | "Agent(*)" | "Agent(general-purpose)" | Edit | Write)
          fail "Claude tools" "$kind rule '$rule' in $settings stops the loop" "remove the rule for this project while the loop runs"
          tools_ok=0
          ;;
        WebFetch* | WebSearch*)
          [ "$RESEARCH_WEB" = false ] || warn "Research" "$kind rule '$rule' in $settings; research uses the codebase only"
          RESEARCH_WEB=false
          ;;
        "Agent(Explore)")
          warn "Research" "$kind rule '$rule' in $settings; research runs without the Explore agent"
          ;;
        "Bash("*")")
          pattern="${rule#Bash(}"
          pattern="${pattern%)}"
          for needed in "git push origin backlog-loop/x" "git commit -m x" "git fetch origin" "git worktree add x" \
            "gh pr create --base x" "gh pr merge 1 --squash" "gh pr checks 1" "gh issue comment 1" \
            "$C_TEST" "$C_LINT" "$C_BUILD"; do
            case "$needed" in "" | none) continue ;; esac
            if [ "$NO_MERGE" -eq 1 ] && [ "$needed" = "gh pr merge 1 --squash" ]; then continue; fi
            if rule_matches "$pattern" "$needed"; then
              fail "Claude tools" "$kind rule '$rule' in $settings matches a command the loop needs ($needed)" \
                "remove or narrow the rule for this project"
              tools_ok=0
              break
            fi
          done
          ;;
      esac
    done <<EOT
$rules_list
EOT
  done
done
[ "$tools_ok" -eq 0 ] || pass
[ "$RESEARCH_WEB" = false ] || pass

finish

# --- Everything passed: now, and only now, change things ------------------------------------------

apply_ignore
mkdir -p "$BL_DIR/decisions" "$BL_DIR/prompts"
if [ "$C_SOURCE" = "github" ]; then
  gh label create blocked --description "Blocked, needs human input (backlog-loop)" --color B60205 >/dev/null 2>&1 || true
  gh label create needs-review --description "Decided with low confidence (backlog-loop)" --color FBCA04 >/dev/null 2>&1 || true
fi
jq -n --arg source "$C_SOURCE" --arg label "$C_LABEL" --arg path "$C_PATH" --arg base "$C_BASE" \
  --arg repo "$REPO" --arg test "$C_TEST" --arg lint "$C_LINT" --arg build "$C_BUILD" \
  --arg method "$C_METHOD" --arg ci "$C_CI" --argjson web "$RESEARCH_WEB" \
  --argjson max_attempts "$(limit max-attempts 3)" --argjson ci_reruns "$(limit ci-reruns 1)" \
  --argjson ci_wait "$(limit ci-wait-minutes 45)" --argjson research "$(limit research-passes 1)" \
  --argjson parallel "$(limit parallel-batches 2)" --argjson stall "$(limit stall-threshold 2)" \
  --argjson iterations "$(limit max-iterations 100)" --argjson hours "$(limit max-hours 12)" \
  --argjson worker "$(limit worker-wait-minutes 120)" --argjson baseline "$(limit baseline-minutes 30)" \
  --argjson batch_items "$(limit max-batch-items 15)" '
  { source: $source, label: $label, path: $path, base_branch: $base, repo: $repo,
    test: $test, lint: $lint, build: $build, merge_method: $method, ci: $ci, research_web: $web,
    limits: { max_attempts: $max_attempts, ci_reruns: $ci_reruns, ci_wait_minutes: $ci_wait,
              research_passes: $research, parallel_batches: $parallel, stall_threshold: $stall,
              max_iterations: $iterations, max_hours: $hours, worker_wait_minutes: $worker,
              baseline_minutes: $baseline, max_batch_items: $batch_items } }' >"$BL_CONFIG.tmp" &&
  mv -f "$BL_CONFIG.tmp" "$BL_CONFIG"

init_args="--session $SESSION"
[ "$PLAN_ONLY" -eq 1 ] && init_args="$init_args --plan-only"
[ "$NO_MERGE" -eq 1 ] && init_args="$init_args --no-merge"
# shellcheck disable=SC2086
"$BL_SCRIPT_DIR/state.sh" init $init_args || exit 1
echo "Preflight passed. Run next.sh."
