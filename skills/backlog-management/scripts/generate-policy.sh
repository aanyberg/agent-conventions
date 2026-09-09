#!/usr/bin/env bash
# Generates <root>/.planning/policy.yml from the plugin's best-practice
# template if it does not already exist. Idempotent: never touches an
# existing file. Prints a human-readable report of what it generated.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
target="$root/.planning/policy.yml"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../../../policy.example.yml"

if [[ -f "$target" ]]; then
  echo "policy.yml already exists at $target — leaving it untouched."
  exit 0
fi

if [[ ! -f "$template" ]]; then
  echo "Template not found at $template — cannot generate policy.yml." >&2
  exit 1
fi

backend="markdown"
reason="no GitHub remote, no gh auth, or Issues not enabled"
remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
if [[ "$remote" == *github.com* ]] && gh auth status >/dev/null 2>&1; then
  if [[ "$(gh api "repos/{owner}/{repo}" --jq .has_issues 2>/dev/null)" == "true" ]]; then
    backend="github-issues"
    reason="origin is on github.com, gh is authenticated, and Issues is enabled"
  fi
fi

mkdir -p "$root/.planning"
sed "s/backend: auto/backend: $backend/" "$template" > "$target"

cat <<EOF
Generated $target — no existing policy.yml was found.

Detected:
  backlog.backend = $backend  ($reason)

Everything else uses the best-practice defaults documented inline in the
generated file (commit types, branch format, versioning, autonomous limits,
ID scheme, etc.) — none of these were detected from your repo, they are
starting points.

This file is now yours: edit any value directly at any time, nothing
regenerates or restarts it, and it will not be overwritten automatically
again.
EOF
