# Global Configuration

## When to Load Skills

| Trigger | Skill |
|---------|-------|
| Listing, creating, claiming, releasing, de-duplicating work items; checking what is in flight; any "add to backlog" or "update status" | `backlog-management` |
| Creating/managing tasks, checking merge readiness, running autonomously as an agent or subagent | `task-workflow` |
| A new feature, capability, or behaviour change is proposed | `value-gate`, then `behavior-spec`, then `test-driven-development` |
| Architectural decisions, new services/modules, tech choices | `architecture-planning` |
| Committing, branching, PRs, worktrees, git operations | `git-conventions` |
| Reviewing a PR or branch, acting as independent reviewer | `code-review` |
| Writing/reviewing code, linting | `code-standards` + the language guideline skill |
| Writing/updating docs, READMEs, changelogs, role/layer docs | `docs-standards` |
| Auditing code health, prioritising refactors | `tech-debt` |

## Quick Reference

**Repository first:** Skills follow the repository's existing instructions,
tooling, tracker, documentation layout, and Git history. Loading a skill never
creates a policy, backlog, task hierarchy, ADR system, branch, or pull request.

**Backlog:** `backlog-management` first honors explicit instructions, then
looks for an established `BACKLOG.md` or GitHub Issues work-item structure. If
the choice remains ambiguous, ask whether to use GitHub Issues, `BACKLOG.md`, or
no persistent backlog. Never silently switch backends after a failure.

**Tasks:** Structured `.planning/tasks/` files are used only when already
present or explicitly requested. Backlog tracking is independent.
**New behaviour:** Runs through three stages in order: `value-gate` (a human
decides whether it is worth building, exploring first when the value is
unknown), `behavior-spec` (Given/When/Then scenarios become the acceptance
criteria and can be recorded as a backlog item), then
`test-driven-development` (a failing test per scenario before any production
code). Bug fixes,
refactors, chores, and documentation-only changes skip the first two.
**Git:** Follow repository documentation and history; use the skill's
Conventional Commit and branch formats only as fallbacks.
**Git snapshots:** Commit every stable, working state to Git as a snapshot, so
there is always a known-good point to recover from. Whenever the code is in a
verified working state (builds, tests pass, feature works), make a commit
before moving on to the next change.
**Architecture:** Follow existing decision-record conventions, including
required ADRs. Create a new architecture/ADR convention or location only after
an explicit request and confirmation.

Always surface structural, public API, schema, dependency, and product
decisions instead of guessing. Never force push, edit branch protection, add a
dependency, or delete a test without human authorization.
