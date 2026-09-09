---
name: backlog-management
description: Single interface for every backlog operation. Use whenever work items are listed, created, claimed, released, linked to a PR, de-duplicated, or marked done, cancelled, or blocked, including when another skill or routine says "add to backlog", "update status", "check what is in flight", or "record a follow-up". Resolves the storage backend (GitHub Issues or BACKLOG.md) from `.planning/policy.yml`, never lets callers touch the backend directly.
---

# Backlog Management

One interface, two backends. Callers use the operations in this file. Backend files hold the mechanics.

## 1. Resolve the backend (once per session)

If `<root>/.planning/policy.yml` does not exist, run `scripts/generate-policy.sh` first — it creates the file from best-practice defaults (backend auto-detected the same way as step 2 below) and prints what it generated. Report that generation in your first response. It never overwrites an existing file, so this is safe to run unconditionally.

Then run `scripts/detect-backend.sh` from the project root, or apply the same order by hand:

1. `.planning/policy.yml` → `backlog.backend`. Explicit value wins.
2. Auto-detect `github-issues` only if all hold: `git remote get-url origin` matches `github.com`; `gh auth status` succeeds; `gh api repos/{owner}/{repo} --jq .has_issues` is `true`.
3. Otherwise `markdown`.
4. Neither usable → stop, report, do nothing.

State the resolved backend in your first report line. Load `backends/<backend>.md` for mechanics.

## 2. Status model

```
backlog → ready → active → in-review → done
   ↘ blocked ↙        ↘ cancelled
```

| Status | Meaning | Who sets it |
|---|---|---|
| `backlog` | Identified, criteria may be thin | sweep, humans, agents recording leftovers |
| `ready` | Criteria clear and testable, no open decisions | triage or human only |
| `active` | Claimed, task file and branch exist | claimant |
| `in-review` | PR open, verification pending | claimant |
| `blocked` | Needs a human decision or an external dependency; evidence recorded | anyone |
| `done` | Merged, criteria verified | releaser, after merge-readiness passes |
| `cancelled` | Will not be done, reason recorded | human or triage |

Rules: no `backlog → done`. Autonomous agents select only `ready` (see `policy.yml` `statuses.agent_selectable`). `blocked` is a side state, it keeps the previous state's evidence.

## 3. Operations

| Op | Contract |
|---|---|
| `list(filter)` | Returns items with id, title, type, priority, status, depends_on, assignee, pr. Filters: status, type, label, text. |
| `dedupe(topic)` | Search titles and bodies across all states including done/cancelled. Returns matches. Callers must not create when a match exists. |
| `create(item)` | Fields: title, type, priority (default medium), goal, acceptance_criteria[], depends_on[], evidence, origin. Returns id. Never assigns an ID by guessing, see backend. |
| `needsDiscussion(item, question)` | Same as create but marked needs-discussion, status backlog, no `ready`. `question` is mandatory. |
| `claim(id, run_id)` | Atomic: verify status is `ready` and unassigned, set `active`, assign, record run_id and branch. Fails if already claimed. |
| `setStatus(id, status, note)` | Any non-terminal transition. `blocked` requires a note with evidence, completed work, blocker, next action. |
| `link(id, pr)` | Attach PR to item and item to PR. Sets `in-review`. |
| `release(id, done\|cancelled\|backlog, note)` | Terminal or unclaim. `done` only from `in-review` and only after task-workflow merge readiness passed. |
| `inFlight()` | All `active` and `in-review` items plus their branches and PRs. Used before selecting work. |
| `nextEligible(n, policy)` | `ready` items, none of whose `depends_on` are open, ordered by priority then age, excluding types outside `policy.autonomous.allowed_types`. |
| `render()` | Regenerate the human view (`policy.backlog.render_file`). No-op for markdown backend. |

## 4. Item content standard (both backends)

Every item has: a one-paragraph Goal, testable Acceptance Criteria as checkboxes, Depends On, Evidence (file paths, line numbers, function names, PR links), Origin (source, created date, originating task or PR). Items without evidence are not `ready`.

## 5. Discipline

- Every piece of identified work gets an item, including small chores and leftovers from merge readiness.
- IDs are permanent, never reused or renumbered.
- Claim before branch. A branch without a claimed item is a defect.
- Record leftovers via `create` with origin pointing at the finishing task or PR.
- Needs-discussion items expire per `policy.backlog.needs_discussion_expiry_days`, triage cancels them with note `stale`.
- Staleness review: when asked, or when open `backlog` exceeds `policy.backlog.max_open_backlog`, list oldest items for the human to promote, cancel, or reprioritise.

## 6. Legacy migration

If `<root>/.agents/backlog.md` exists and `<root>/BACKLOG.md` does not, move it. If `policy.yml` says `github-issues` but `BACKLOG.md` still contains hand-written tables and `.planning/backlog-migration.json` is absent, the migration is incomplete: treat backend as `markdown` for this session and report it.
