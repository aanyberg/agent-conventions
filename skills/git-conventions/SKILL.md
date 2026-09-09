---
name: git-conventions
description: Use when committing, creating branches, opening PRs, or managing git workflow, including worktrees for parallel agents. Covers Conventional Commits, branch naming tied to backlog IDs, one-change-per-branch discipline, worktree isolation scripts, versioning policy, and actions agents must never take.
---

# Git Conventions

Enforces Conventional Commits and disciplined branching across all projects. Values marked *policy* come from `<root>/.planning/policy.yml`, generated on first use from best-practice defaults if the file doesn't exist (see **backlog-management**'s `scripts/generate-policy.sh`); the defaults stated below apply for any individual key still missing from an existing file.

## Commit Format

```
<type>(<scope>): <imperative verb>

Optional longer description explaining why, not what.
```

**Types:** *policy* `git.commit_types`, default `feat`, `fix`, `chore`, `docs`, `refactor`, `test`. The set matches backlog item types so every item can have a matching branch.

**Examples:**
- `feat(auth): add JWT refresh rotation`
- `fix(search): resolve partial index corruption`
- `refactor(courses): extract pagination helper`
- `test(enrolment): cover duplicate enrolment path`
- `chore(deps): bump typescript to 5.1`
- `docs(api): clarify retry backoff behavior`

**Rules:**
- Imperative mood only: "add", not "added" or "adds"
- Lowercase after colon, no period at end
- Scope optional but preferred
- Breaking changes get `!` before colon: `feat!: remove legacy API`
- Backlog-only commits use scope `backlog`: `chore(backlog): claim 231`

## Branch Naming

*policy* `git.branch_format`, default:

```
<type>/<id>-<short-kebab-description>
```

`<id>` is the backlog-management ID. It lets tooling join branches, PRs, and items without parsing titles.

**Examples:**
- `feat/231-user-authentication`
- `fix/244-cache-invalidation-race`
- `docs/250-api-endpoint-reference`
- `chore/backlog-sweep-2026-09-03-a1b2c3d` (routine branches carry a run ID instead)

Match the branch type to the commit type. Legacy branches without an ID are allowed only for work predating the backlog claim rule.

## Pull Requests

- Body contains `Closes #<id>` (github-issues backend) or the item ID in the first line (markdown backend).
- Body sections: Summary, Verification (the merge-readiness rows with pass/fail), Backlog link.
- Label `needs-human` when the diff touches any *policy* `autonomous.require_human_review_if_touches` path. Such PRs are never merged by an agent.
- Draft PR as soon as the branch exists when working autonomously. It doubles as a visible claim.

## Versioning

*policy* `versioning.bump`:
- `release-commit-only` (default): never bump `package.json` or `pyproject.toml` in a feature branch. Releases are cut in their own commit with `CHANGELOG.md`.
- `per-branch`: bump in the branch per **code-standards**.

## Discipline

- **One logical change per branch.** No "WIP" or "misc" commits on shared branches. Squash or amend first.
- **Delete branches once merged.**
- **Never commit to protected branches directly.**
- **Forbidden without a human present:** force push, rewriting shared history, editing branch protection or rulesets, adding or upgrading a dependency, deleting or skipping a test. Mirrors *policy* `autonomous.forbidden`.

## Worktrees (parallel work only)

Use a worktree only when agents work concurrently on the same repo. Sequential single-agent work uses a plain branch.

Use the project scripts, *policy* `worktrees.up` and `worktrees.down`:

```bash
scripts/worktree-up.sh <id> <branch>   # creates ../<repo>-<id>, allocates a port block,
                                       # a DB name per id, writes .env, runs migrations
cd ../<repo>-<id>                      # commit + push from here
git push -u origin <branch>
scripts/worktree-down.sh <id>          # drops DB, removes worktree, git worktree prune
```

If the scripts do not exist, do not improvise: create a `chore` backlog item for them and run at most one worktree until they are merged. Raw fallback for that single worktree:

```bash
git worktree add ../<repo>-<id> <branch>
git worktree remove ../<repo>-<id>     # add --force to discard changes
git worktree prune
```

**Rules:** no two worktrees share ports, DB names, or `.env`. Remove the worktree before declaring the task done. Run `git worktree list` to audit stragglers at the end of every run.
