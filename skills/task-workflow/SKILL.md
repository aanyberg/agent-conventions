---
name: task-workflow
description: Use when creating or managing task records, checking merge readiness, or autonomously implementing an assigned item. Preserves repository-native workflow and uses structured task files only when requested or already established.
---

# Task Workflow

## 1. Select the task model

Use the repository's existing task and delivery process by default. Loading
this skill does not create `.planning/`, a task file, a backlog item, or a
branch.

The structured task-file workflow below is active only when at least one of
these is true:

- the user explicitly requests it;
- the repository already contains `.planning/tasks/` or `.planning/planned/`;
- the assigned work references an existing structured task file.

Otherwise keep the goal, acceptance criteria, and plan in the repository's
existing work item or the conversation, and use its normal completion checks.

Backlog tracking is independent. Use **backlog-management** only when a backend
has already been resolved for the current conversation or the user asks to
record or update work. Never create a backlog merely because task files are in
use.

Do not migrate legacy task or architecture files automatically. If a migration
would help, describe the affected paths and obtain confirmation first.

## 2. Structured task lifecycle

Preserve an existing task layout. If the user explicitly requests structured
task files in a repository with no layout, use:

| State | Location | Purpose |
|---|---|---|
| `planned` | `<root>/.planning/planned/<category>/` | Definition only; no implementation branch |
| `active` | `<root>/.planning/tasks/` | Approved implementation work |

**Filename:** `<type>_<short-description>.md`

Promoting planned to active means moving the file, setting `Status: active`,
and adding `Started` and `Branch` before implementation. If a backlog backend
and item are already selected, claim the item in the same step.

## 3. Task file structure

```markdown
# <Title>

**Status:** planned | active
**Backlog:** <optional existing work-item ID>
**Created:** <datetime>
**Started:** <datetime>      # active only

## Branch                    # active only
`<format selected by git-conventions>`

## Goal
One paragraph: what and why.

## Acceptance Criteria
- [ ] Criterion one
- [ ] Criterion two

## Plan
Ordered implementation steps written before code.

## Log                       # active only
- `HH:MM` - What was done

## Blockers
Open questions needing a decision.

## Summary                   # appended before completion
What was built and any deviation from the plan.
```

Use the repository's existing branch format. If none exists,
**git-conventions** supplies a fallback. Include a backlog ID only when the
selected backend and repository convention use one.

Interactive work refines acceptance criteria with the user until they are
specific and testable. Autonomous work copies criteria from the assigned item
without silently changing scope.

## 4. Structured merge-readiness gate

For repositories using structured task files, do not call a branch merge-ready
until each applicable row has current-session evidence:

| # | Item | Evidence |
|---|---|---|
| 1 | Acceptance criteria met | Each criterion checked against the implementation |
| 2 | Tests cover changed behavior | Relevant test command and result |
| 3 | Lint and type checks pass | Repository-configured commands and results |
| 4 | Pre-commit passes | Configured hooks, or N/A when absent |
| 5 | User-facing docs and changelog updated | Diff, or N/A under repository conventions |
| 6 | Version handled | Repository release policy, or N/A |
| 7 | Task summary appended | Summary reflects the delivered change |
| 8 | Leftovers recorded | Selected backlog IDs, repository-native records, or none |
| 9 | Work item linked | Link when a persistent backend is in use, otherwise N/A |
| 10 | Task file finalized | Remove or archive it according to the established task convention |
| 11 | Branch current | Repository-required base synchronization check |
| 12 | Independent review | Fresh reviewer approval when required by the repository or caller |
| 13 | Autonomous safety | Autonomous restrictions below satisfied, or N/A for interactive work |

State each result as pass, fail, or N/A with a reason. Stop on failures, fix
them, and re-run the relevant check. Update a selected backlog item only after
the repository's merge or completion requirements are satisfied.

## 5. Autonomous mode

This section applies when the caller explicitly delegates autonomous execution
or the agent runs without a human in the loop. It does not activate task files
or a backlog.

1. **Assignment first.** Work only on an explicitly assigned item. Self-select
   only when the caller authorizes it and the selected backlog marks the item
   safe for agents.
2. **Criteria are read-only.** Do not invent or broaden acceptance criteria.
   If they are not testable, record a blocker through the selected work system
   or report it directly.
3. **Re-verify evidence.** Confirm cited files, symbols, and reproduction steps
   before planning.
4. **Do not guess structural choices.** Public API, schema, dependency,
   architecture, and product decisions require human approval.
5. **Keep work bounded.** Honor repository or caller limits. Without explicit
   limits, finish the smallest coherent change and report follow-ups rather
   than expanding into unrelated work.
6. **Protect sensitive paths.** Changes to CI workflows, migrations, dependency
   manifests, public APIs, or schemas require human review.
7. **Forbidden without explicit human authorization:** force push, rewriting
   shared history, editing branch protection, adding or upgrading a
   dependency, and deleting or skipping a test.
8. **Isolate parallel work.** Follow the repository's worktree tooling. Never
   share ports, database names, or environment files between concurrent
   worktrees.
9. **Report truthfully.** List completed work, checks, blockers, and follow-ups
   using the repository's existing task or backlog system when available.

## 6. Structured task discipline

- Write the task plan before implementation and log significant scope changes.
- Keep changes within the stated goal and acceptance criteria.
- Record unresolved decisions as blockers rather than guessing.
- Do not require a backlog item when the repository does not use one.
