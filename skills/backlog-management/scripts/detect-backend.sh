#!/usr/bin/env bash
# Prints: github-issues | markdown | none
set -euo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
policy="$root/.planning/policy.yml"

if [[ -f "$policy" ]]; then
  # POSIX classes, not \s: BSD sed (macOS) treats \s as a literal 's', which
  # leaves the value padded and makes `backend: auto` read as an explicit backend.
  explicit="$(grep -E '^[[:space:]]*backend:' "$policy" | head -1 \
    | sed -E 's/.*backend:[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]+$//' || true)"
  if [[ -n "${explicit:-}" && "$explicit" != "auto" ]]; then
    if [[ "$explicit" == "github-issues" && -f "$root/BACKLOG.md" && ! -f "$root/.planning/backlog-migration.json" ]] \
       && grep -qE '^\| *(LMS|INFRA|DEV|[0-9]{3})' "$root/BACKLOG.md"; then
      echo "markdown  # policy says github-issues but migration incomplete" >&2
      echo markdown; exit 0
    fi
    echo "$explicit"; exit 0
  fi
fi

remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
if [[ "$remote" == *github.com* ]] && gh auth status >/dev/null 2>&1; then
  if [[ "$(gh api "repos/{owner}/{repo}" --jq .has_issues 2>/dev/null)" == "true" ]]; then
    echo github-issues; exit 0
  fi
fi

if [[ -f "$root/BACKLOG.md" ]]; then echo markdown; exit 0; fi
echo none; exit 1
