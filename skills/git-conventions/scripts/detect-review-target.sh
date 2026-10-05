#!/bin/sh
# Detect the code review system behind a Git remote and the commit strategy
# to use for follow-up work. Read-only: never modifies the repository.
#
# Usage: detect-review-target.sh [--remote <name>] [--branch <name>]
#
# Prints key=value lines:
#   review_system    gerrit | github | gitlab | bitbucket | unknown
#   signals          comma-separated evidence for the review system
#   remote           remote used for review pushes
#   target_branch    branch the change targets
#   ahead            commits on HEAD not in <remote>/<target_branch>, or unknown
#   change_id        Change-Id trailer of HEAD, if any
#   commit_msg_hook  installed | missing | n/a
#   commit_strategy  amend | new-commit | ask
#   push_command     suggested push command
#   reason           short explanation of commit_strategy
#   warnings         comma-separated warnings, if any

set -u

remote=""
branch=""

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) remote="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "not a git repository" >&2
  exit 2
fi

top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
signals=""
warnings=""

add_signal() { signals="${signals:+$signals,}$1"; }
add_warning() { warnings="${warnings:+$warnings,}$1"; }
remote_exists() { git remote | grep -qx "$1"; }

gitreview_get() {
  [ -f "$top/.gitreview" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$top/.gitreview" \
    | head -n 1 | tr -d '\r'
}

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
upstream_remote=""
upstream_branch=""
if [ -n "$upstream" ]; then
  for r in $(git remote); do
    case "$upstream" in
      "$r"/*) upstream_remote="$r"; upstream_branch="${upstream#"$r"/}" ;;
    esac
  done
fi

if [ -z "$remote" ]; then
  review_remote=$(gitreview_get defaultremote)
  for candidate in "$review_remote" gerrit "$upstream_remote" origin; do
    if [ -n "$candidate" ] && remote_exists "$candidate"; then
      remote="$candidate"
      break
    fi
  done
  [ -n "$remote" ] || remote=$(git remote | head -n 1)
fi

url=""
[ -n "$remote" ] && url=$(git remote get-url --push "$remote" 2>/dev/null || true)
host=$(printf '%s\n' "$url" \
  | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#[:/].*$##' \
  | tr '[:upper:]' '[:lower:]')

# Gerrit evidence.
[ -f "$top/.gitreview" ] && add_signal gitreview-file
case "$url" in *:29418/*|*:29418) add_signal gerrit-ssh-port ;; esac
case "$host" in *gerrit*) add_signal gerrit-hostname ;; esac
if [ -n "$remote" ] && git config --get-all "remote.$remote.push" 2>/dev/null \
  | grep -q 'refs/for/'; then
  add_signal refs-for-push-refspec
fi
git config --get-regexp '^gerrit\.' >/dev/null 2>&1 && add_signal gerrit-config

hooks_dir=$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks)
hook_has_change_id=false
if [ -x "$hooks_dir/commit-msg" ] && grep -q 'Change-Id' "$hooks_dir/commit-msg"; then
  hook_has_change_id=true
  add_signal change-id-commit-msg-hook
fi

change_id=$(git log -1 --format=%B HEAD 2>/dev/null \
  | git interpret-trailers --parse 2>/dev/null \
  | sed -n 's/^Change-Id:[[:space:]]*//p' | tail -n 1)

if [ -n "$signals" ]; then
  review_system=gerrit
  # A Change-Id trailer alone is not proof: changes are often cherry-picked
  # from Gerrit into other hosts. Record it only as supporting evidence.
  [ -n "$change_id" ] && add_signal head-change-id-trailer
else
  case "$host" in
    github.com|*.github.com|github.*|*.ghe.com) review_system=github ;;
    gitlab.com|gitlab.*|*.gitlab.com) review_system=gitlab ;;
    bitbucket.org|bitbucket.*) review_system=bitbucket ;;
    *) review_system=unknown ;;
  esac
  [ "$review_system" != unknown ] && add_signal "remote-host-$host"
fi

if [ -z "$branch" ]; then
  branch=$(gitreview_get defaultbranch)
  if [ -z "$branch" ] && [ -n "$upstream_remote" ] && [ "$upstream_remote" = "$remote" ]; then
    branch="$upstream_branch"
  fi
  if [ -z "$branch" ] && [ -n "$remote" ]; then
    branch=$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null \
      | sed "s#^$remote/##")
  fi
  if [ -z "$branch" ] && [ -n "$remote" ]; then
    for candidate in main master; do
      if git rev-parse --verify --quiet "refs/remotes/$remote/$candidate" >/dev/null; then
        branch="$candidate"
        break
      fi
    done
  fi
fi

ahead=unknown
if [ -n "$remote" ] && [ -n "$branch" ] \
  && git rev-parse --verify --quiet "refs/remotes/$remote/$branch" >/dev/null; then
  ahead=$(git rev-list --count "refs/remotes/$remote/$branch..HEAD" 2>/dev/null || echo unknown)
else
  add_warning target-ref-not-fetched
fi

if [ "$review_system" = gerrit ]; then
  if $hook_has_change_id; then commit_msg_hook=installed; else commit_msg_hook=missing; fi
  push_command="git push $remote HEAD:refs/for/${branch:-<branch>}"
  [ "$commit_msg_hook" = missing ] && add_warning install-gerrit-commit-msg-hook
  if [ "$ahead" = unknown ]; then
    commit_strategy=ask
    reason="cannot tell whether HEAD is already merged; fetch $remote and rerun"
  elif [ "$ahead" -eq 0 ]; then
    commit_strategy=new-commit
    reason="HEAD is already in $remote/$branch; new work starts a new change"
  elif [ -z "$change_id" ]; then
    commit_strategy=ask
    reason="unmerged HEAD has no Change-Id; confirm it is the change being revised"
    add_warning head-missing-change-id
  else
    commit_strategy=amend
    reason="unmerged HEAD carries a Change-Id; amend to upload a new patchset"
    [ "$ahead" -gt 1 ] && add_warning "chain-of-$ahead-changes-amend-updates-only-head"
  fi
else
  commit_msg_hook=n/a
  commit_strategy=new-commit
  reason="branch-based review; add follow-up commits instead of rewriting pushed history"
  if [ -n "$remote" ]; then push_command="git push $remote HEAD"; else push_command=""; fi
fi

printf 'review_system=%s\n' "$review_system"
printf 'signals=%s\n' "$signals"
printf 'remote=%s\n' "$remote"
printf 'target_branch=%s\n' "$branch"
printf 'ahead=%s\n' "$ahead"
printf 'change_id=%s\n' "$change_id"
printf 'commit_msg_hook=%s\n' "$commit_msg_hook"
printf 'commit_strategy=%s\n' "$commit_strategy"
printf 'push_command=%s\n' "$push_command"
printf 'reason=%s\n' "$reason"
printf 'warnings=%s\n' "$warnings"
