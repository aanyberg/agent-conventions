#!/usr/bin/env bash
# Shared helpers for the backlog-loop scripts. Sourced, never executed.
# Targets bash 3.2 (macOS default) and newer; needs jq and git.

BL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL_SKILL_DIR="$(cd "$BL_SCRIPT_DIR/.." && pwd)"
export BL_SCRIPT_DIR BL_SKILL_DIR

bl_dry_run() { [ "${BACKLOG_LOOP_DRY_RUN:-0}" = "1" ]; }

# Dry-run mode puts stub `gh` and `git` (push/fetch/pull only) first on PATH.
if bl_dry_run; then
  case ":$PATH:" in
    *":$BL_SKILL_DIR/tests/stubs:"*) ;;
    *)
      BACKLOG_LOOP_REAL_GIT="${BACKLOG_LOOP_REAL_GIT:-$(command -v git)}"
      export BACKLOG_LOOP_REAL_GIT
      PATH="$BL_SKILL_DIR/tests/stubs:$PATH"
      export PATH
      ;;
  esac
fi

bl_die() {
  printf 'backlog-loop: %s\n' "$*" >&2
  exit 1
}

bl_have() { command -v "$1" >/dev/null 2>&1; }

# Root of the main checkout, also when called from a linked worktree.
bl_root() {
  if [ -n "${BACKLOG_LOOP_ROOT:-}" ]; then
    printf '%s\n' "$BACKLOG_LOOP_ROOT"
    return 0
  fi
  local top common
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) ;;
    *) common="$top/$common" ;;
  esac
  (cd "$common/.." 2>/dev/null && pwd -P)
}

bl_paths() {
  BL_ROOT="$(bl_root)" || return 1
  BL_DIR="$BL_ROOT/.planning/backlog-loop"
  BL_STATE="$BL_DIR/state.json"
  BL_CONFIG="$BL_DIR/config.json"
  BL_LOG="$BL_DIR/run.log"
  BL_LOCK="$BL_DIR/lock"
  export BL_ROOT BL_DIR BL_STATE BL_CONFIG BL_LOG BL_LOCK
}

bl_now() {
  if [ -n "${BACKLOG_LOOP_NOW:-}" ]; then
    printf '%s\n' "$BACKLOG_LOOP_NOW"
  else
    date +%s
  fi
}

bl_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

bl_log() {
  [ -d "${BL_DIR:-/nonexistent}" ] || return 0
  printf '%s [%s] %s\n' "$(bl_iso)" "${BL_SELF:-lib}" "$*" >>"$BL_LOG" 2>/dev/null || true
}

bl_state_ok() {
  [ -s "${BL_STATE:-}" ] && jq -e -s 'length == 1 and (.[0] | .run and (.items | type == "array") and (.batches | type == "array"))' "$BL_STATE" >/dev/null 2>&1
}

bl_run_active() {
  bl_state_ok && [ "$(jq -r '.run.status' "$BL_STATE" 2>/dev/null)" = "running" ]
}

# bl_get [jq options...] <filter>
bl_get() { jq -r "$@" "$BL_STATE"; }

# bl_update [jq options...] <filter>: atomic write, temp file plus rename.
bl_update() {
  local tmp="$BL_STATE.tmp.$$" err
  if jq "$@" "$BL_STATE" >"$tmp" 2>"$tmp.err" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$BL_STATE"
    rm -f "$tmp.err"
  else
    err="$(cat "$tmp.err" 2>/dev/null)"
    rm -f "$tmp" "$tmp.err"
    bl_die "state update failed: $err"
  fi
}

# Hash of everything that counts as progress. Gate bookkeeping is excluded.
bl_hash() {
  jq -cS '{items, batches, status: .run.status}' "$BL_STATE" | cksum | awk '{print $1}'
}

bl_cfg() { jq -r --arg k "$1" '.config[$k] // empty' "$BL_STATE"; }
bl_limit() { jq -r --arg k "$1" '.config.limits[$k] // empty' "$BL_STATE"; }

# Item ids are plain numbers for GitHub and free-form for BACKLOG.md.
bl_ref() {
  if [ "$(bl_cfg source)" = "github" ]; then printf '#%s' "$1"; else printf '%s' "$1"; fi
}

# --- lock -------------------------------------------------------------------

bl_lock_owner() { [ -f "$BL_LOCK" ] && sed -n '1p' "$BL_LOCK"; }

# True while the lock was touched within the last N minutes (default 15).
bl_lock_fresh() {
  [ -f "$BL_LOCK" ] || return 1
  [ -z "$(find "$BL_LOCK" -mmin +"${1:-15}" 2>/dev/null)" ]
}

bl_lock_touch() {
  if [ -f "${BL_LOCK:-}" ]; then touch "$BL_LOCK" 2>/dev/null || true; fi
}

# bl_lock_acquire <session>: 0 on success, 1 when another live session holds it.
bl_lock_acquire() {
  local session="$1" owner
  mkdir -p "$BL_DIR" || return 1
  if (set -C && printf '%s\n' "$session" >"$BL_LOCK") 2>/dev/null; then
    return 0
  fi
  owner="$(bl_lock_owner)"
  if [ "$owner" = "$session" ]; then
    touch "$BL_LOCK"
    return 0
  fi
  if bl_lock_fresh "${BACKLOG_LOOP_LOCK_STALE_MINUTES:-15}"; then
    return 1
  fi
  bl_log "taking over stale lock from session $owner"
  printf '%s\n' "$session" >"$BL_LOCK"
}

bl_lock_release() { rm -f "$BL_LOCK"; }

# --- deadlines --------------------------------------------------------------

# bl_with_deadline <seconds> <output-file> <command string>
# Returns the command status, or 124 when the deadline hits. No GNU timeout.
bl_with_deadline() {
  local secs="$1" out="$2" cmd="$3" pid start
  bash -c "$cmd" >"$out" 2>&1 &
  pid=$!
  start="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    if [ $(($(date +%s) - start)) -ge "$secs" ]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}

# --- GitHub -----------------------------------------------------------------

# bl_pr_checks <pr>: prints green | red | pending | none | error.
bl_pr_checks() {
  local out
  out="$(gh pr checks "$1" --json name,bucket 2>&1)"
  if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '
      if length == 0 then "none"
      elif any(.[]; .bucket == "fail" or .bucket == "cancel") then "red"
      elif any(.[]; .bucket == "pending") then "pending"
      else "green" end'
    return 0
  fi
  case "$out" in
    *"no checks reported"*) echo none ;;
    *) echo error ;;
  esac
}

# bl_pr_field <pr> <field>: one field of `gh pr view`, empty on error.
bl_pr_field() {
  gh pr view "$1" --json "$2" --jq ".$2" 2>/dev/null
}

# Run the project's test, lint and build commands in the current directory.
# Prints one line per failing class; returns 0 only when all pass.
bl_run_checks() {
  local class cmd rc failed=0 out mins
  mins="$(bl_limit baseline_minutes)"
  out="$BL_DIR/checks.out"
  for class in test lint build; do
    cmd="$(bl_cfg "$class")"
    case "$cmd" in "" | none) continue ;; esac
    bl_with_deadline $((${mins:-30} * 60)) "$out" "$cmd"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      failed=1
      if [ "$rc" -eq 124 ]; then
        printf '%s: "%s" hit the %s minute deadline\n' "$class" "$cmd" "${mins:-30}"
      else
        printf '%s: "%s" exited %s: %s\n' "$class" "$cmd" "$rc" "$(tail -n 3 "$out" | tr '\n' ' ')"
      fi
    fi
  done
  return "$failed"
}
