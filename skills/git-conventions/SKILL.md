---
name: git-conventions
description: Use when committing, creating branches, opening pull requests, or managing worktrees. Discovers and follows repository-native Git conventions, with conservative fallbacks when none exist.
---

# Git Conventions

## 1. Discover repository conventions

Before a Git operation, inspect `AGENTS.md`, `CONTRIBUTING.md`, pull request
templates, release documentation, CI, and recent history. Established
repository conventions always take precedence.

Do not create configuration, a backlog item, or a task file merely to perform
a Git operation. If the repository has no convention, use the fallbacks below.

## 2. Commit fallback

Use Conventional Commits when the repository has no established format:

```text
<type>(<scope>): <imperative summary>
```

Suggested types: `feat`, `fix`, `chore`, `docs`, `refactor`, and `test`.
Keep the summary lowercase after the colon, omit the final period, and use `!`
for a breaking change. Keep each commit focused on one logical change.

## 3. Branch fallback

Use:

```text
<type>/<short-kebab-description>
```

If a selected backlog backend and repository convention use work-item IDs,
include the ID in the established position. Do not require an ID otherwise.

## 4. Pull requests

- Follow the repository's pull request template and required checks.
- Link a work item only when a backlog backend has been selected for the work.
- Include structured task merge-readiness evidence only when that task workflow
  is in use.
- For autonomous work, open a draft PR early when the repository supports it.
- Require human review for dependency changes, public API or schema changes,
  migrations, CI/release workflows, or other repository-designated protected
  paths.

## 5. Versioning

Follow the repository's documented release process and version source of
truth. Do not bump a version in a feature branch unless that process requires
it. When no release convention exists, keep versioning out of unrelated
changes.

## 6. Safety

- Never commit directly to a protected branch.
- Never force push or rewrite shared history without explicit authorization.
- Do not edit branch protection or rulesets.
- Do not add or upgrade dependencies, or delete or skip tests, without explicit
  human authorization.
- Delete branches after merge only when the repository's workflow expects it.

## 7. Worktrees

Use a worktree only for concurrent work. Prefer repository-provided worktree
scripts and follow their documented arguments.

If no helper exists, use at most one raw fallback worktree:

```bash
git worktree add ../<repo>-<work-id> <branch>
git worktree remove ../<repo>-<work-id>
git worktree prune
```

Use an existing work-item ID as `<work-id>` when available; otherwise use a
unique task slug or run identifier. Do not create a backlog just to name a
worktree.

Never share ports, database names, or environment files between concurrent
worktrees. Remove task-created worktrees before reporting completion.
