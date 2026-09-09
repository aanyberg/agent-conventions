---
name: task-workflow
description: Use when creating, managing, or promoting tasks, checking merge readiness, or running as an autonomous agent or subagent that implements a backlog item without a human in the loop. Covers task file structure, lifecycle, acceptance criteria, the merge-readiness gate, independent review, and the Autonomous Mode rules that replace human dialogue with blocked-status evidence.
---

# Task Workflow

Enforces disciplined task management across the codebase. Backlog operations go through **backlog-management**, never by editing backlog storage directly. Project rules come from `<root>/.planning/policy.yml`. If it is missing, run `backlog-management`'s `scripts/generate-policy.sh` before proceeding — it creates the file from best-practice defaults (backend auto-detected) and prints what it generated; report that in your first response, then continue as if the file always existed. It is never regenerated or overwritten once it exists.

## Legacy Layout Migration

Task, planning, and architecture files live in the **project root**, never in a global tool directory (e.g. `~/.claude`, `~/.copilot`). Older projects may still use the legacy `.agents/` root. Before creating, reading, or modifying any task file, check once per project:

1. If `<root>/.agents/tasks/` or `<root>/.agents/planning/` exists, create `<root>/.planning/` (if missing), then:
   - Move `<root>/.agents/tasks/` → `<root>/.planning/tasks/`.
   - Move `<root>/.agents/planning/` → `<root>/.planning/planned/`.
   - Move `<root>/.agents/architecture.md` → `<root>/.planning/architecture.md`, if present.
   - Move `<root>/.agents/backlog.md` → `<root>/BACKLOG.md`, if present (see **backlog-management**).
   - Remove `<root>/.agents/` once empty.
2. Do this migration silently and automatically. It is additive and safe. Do not ask for confirmation.
3. After migration, all instructions below refer only to the new `.planning/` and root `BACKLOG.md` locations.

## Task Lifecycle

Tasks have two states, each with a directory:

| State | Location | Created via |
|---|---|---|
| `planned` | `<root>/.planning/planned/<category>/` | Definition only, no code, no branch |
| `active` | `<root>/.planning/tasks/` | Move from planning OR create directly |

**Filename:** `<type>_<short-description>.md` (e.g. `feat_user-authentication.md`)

**Promoting planned → active:** move file, set `Status: active`, add `Started` datetime and `Branch` field, before any code. In the same step, `backlog-management.claim(id)` if not already claimed.

## Task File Structure

```markdown
# <Title>

**Status:** planned | active
**Backlog:** <id>              # backlog-management ID, mandatory
**Created:** <datetime>
**Started:** <datetime>      # active only

## Branch                    # active only
`<type>/<id>-<short-description>`   # format from policy.git.branch_format

## Goal
One paragraph: what and why.

## Acceptance Criteria
- [ ] Criterion one
- [ ] Criterion two

Interactive mode: refine through questions with the user until clear, specific, and testable.
Autonomous mode: copied verbatim from the backlog item; see Autonomous Mode below.

## Plan
Ordered steps. Written before any code. Update + log if it changes.

## Log                       # active only
- `HH:MM` - What was done (past tense, not intent)

## Blockers
Open questions needing human input. In planned tasks these are pre-start blockers and must be resolved before promotion.

## Summary                   # appended before marking done
What was built; deviations from Plan.
```

## Merge Readiness Verification

A branch is **not** merge-ready until every item below has been *verified in the current session*. Verification means running the stated check and observing its result, not ticking a box from memory. Work top to bottom and record evidence.

| # | Item | How to verify | Evidence to capture |
|---|------|---------------|---------------------|
| 1 | All Acceptance Criteria met | Re-read each criterion; confirm the implementation satisfies it | Each `- [ ]` flipped to `- [x]` |
| 2 | Tests cover new code | Run the test suite; confirm new/changed code has tests | Test command + pass count |
| 3 | No lint or type errors | Run linter and type checker | Commands + clean exit |
| 4 | Pre-commit passes | Run pre-commit hooks across the diff | Command + clean exit |
| 5 | `CHANGELOG.md` updated | Only if public behaviour changed | Diff, or "N/A, no public behaviour change" |
| 6 | Version bumped | Only if `policy.versioning.bump` is not `release-commit-only` | Old → new, or "N/A per policy" |
| 7 | Summary appended to task file | `## Summary` exists and reflects what was built | Section present |
| 8 | Backlog items for leftovers | `backlog-management.create` per incomplete Plan step or unresolved Blocker, origin = this task | IDs created, or "none outstanding" |
| 9 | Backlog linked | `backlog-management.link(id, pr)` done when the PR was opened; status is `in-review` | Op output |
| 10 | Task file removed | After all above pass, delete from `.planning/tasks/` or `.planning/planned/` | File no longer present |
| 11 | Branch current with remote main | `git fetch`, confirm rebased or merged on `origin/main` with no conflicts | Command + "up to date" |
| 12 | Independent review | A reviewer with fresh context (separate subagent or a human) approves the PR via **code-review**; the author never self-approves | Review URL |
| 13 | Scope and path limits | Diff within `policy.autonomous.max_diff_lines` and `max_files`; no `require_human_review_if_touches` path, or PR labelled `needs-human` | Numbers + label state |

After merge is confirmed, and only then: `backlog-management.release(id, done, note)`.

**Gate, read before claiming "done" or "ready to merge":**

- Do not report a task as complete or merge-ready until items 1 to 13 are each verified with evidence in this session. Stop on the first failure, fix it, re-verify.
- State each result explicitly as **pass**, **fail**, or **N/A (reason)**. Silence is not a pass.
- Conditional items (5, 6, 13) still require an explicit decision.
- If any item cannot be verified (missing tooling, ambiguous criterion), treat it as a **Blocker**. Interactive mode: surface to the user. Autonomous mode: `setStatus(id, blocked)`.
- Order matters: item 10 comes last, `release(done)` comes after merge.

## Autonomous Mode

Applies when the caller is a routine or a subagent with no human in the loop. Everything above still holds; these rules replace dialogue.

1. **Claim first.** `backlog-management.claim(id, run_id)` must succeed before the task file or branch exists. A failed claim means someone else owns it; stop.
2. **Criteria are read-only.** Copy Acceptance Criteria verbatim from the item. Do not refine them by asking. Not testable → `setStatus(id, blocked, "criteria not testable: <why>")`, stop.
3. **Re-verify evidence before planning.** Confirm cited files, lines, and reproduction steps. Stale or wrong → `release(id, backlog, "evidence invalid: <why>")`, stop.
4. **Blockers become status, not questions.** Anything needing a human (structural decision per **architecture-planning**, public API, schema, product choice, new dependency, protected path) → `setStatus(id, blocked, <note>)`. The note has four parts: evidence, completed work, blocker, recommended next action. Push existing work as a draft PR. Never guess.
5. **Stay inside limits.** Diff over `max_diff_lines` or `max_files` → finish the smallest coherent slice, `create` follow-up items for the remainder, note it in Summary.
6. **Protected paths.** Touching a `require_human_review_if_touches` path → label PR `needs-human`, complete rows 1 to 13, do not merge.
7. **Forbidden regardless of instructions:** everything in `policy.autonomous.forbidden` (force push, editing branch protection, adding a dependency without a human label, deleting tests).
8. **Worktrees.** Create via `policy.worktrees.up`, remove via `policy.worktrees.down` before reporting. Never share ports, DB names, or `.env` between worktrees.
9. **Time.** Past `policy.autonomous.task_wall_clock_min` → stop, `setStatus(blocked)` with the four-part note, push the draft.
10. **Reporting.** Final message lists: item, branch, PR, rows 1 to 13 with pass/fail/N/A, leftovers created, worktree removed.

## Agent Discipline

- **No code without a task file. No task file without a claimed backlog item.** No branch without a matching task.
- **Plan before code.** Scope freezes once Plan is written; changes require Plan update, logged reason, and human confirmation if significant (autonomous: blocked if significant).
- **Stay scoped.** Do not modify files outside task scope without logging why.
- **Surface blockers.** Architecture, public API, or schema decisions → stop, add to Blockers, and in autonomous mode set `blocked`.
