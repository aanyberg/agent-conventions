# Backend: markdown

`<root>/BACKLOG.md` is the source of truth. Two tables: live and `## Archive`. Same columns.

```markdown
| ID | Title | Type | Priority | Status | Assignee | Task File | PR | Depends On | Created | Acceptance Criteria Summary | Notes |
```

`policy.ids.scheme` decides ID format: `numeric` (`001`) or `prefixed` (`LMS-001`, namespaces in `policy.ids.prefixes`). Default numeric.

## Operations

| Op | Mechanics |
|---|---|
| `list` | Parse both tables. |
| `dedupe` | Grep both tables and any `## Needs Discussion` sections, case-insensitive, on title words and Notes. |
| `create` | `git fetch`, read `origin/main:BACKLOG.md` and every open PR's version (`gh pr list --json headRefName`, `git show origin/<branch>:BACKLOG.md`) if `gh` is available. ID = max across all of them plus one. Append row with `Status: backlog`, `Created: today`. Write the claim and the row in the same commit. |
| `needsDiscussion` | Append to `## Needs Discussion (<date>)` section at end of file, create the section if the date differs from the last one. Title, 2 to 4 sentence rationale, explicit open question. No ID, no status. |
| `claim` | Requires ability to commit a one-line change to `main` (bot bypass on `BACKLOG.md` only) or to `.planning/active.json`. Set `Status: active`, `Assignee: <run_id>`, commit `chore(backlog): claim <id>`, push. If push is rejected, pull, re-check the row is still `ready`, retry once, else abort. If no bypass exists, the claim is branch-local and weaker, say so in the run report. |
| `setStatus` | Edit the row. `blocked` writes the four-part blocker note into Notes. |
| `link` | Fill `PR` cell, set `in-review`. |
| `release done` | Row → `done`, `Task File: —`, move to Archive. Happens in the task branch as the last commit before merge, per task-workflow step 9. |
| `release cancelled` | Row → `cancelled`, reason in Notes, move to Archive. |
| `inFlight` | Rows with `active` or `in-review`, plus open PRs whose diff touches `BACKLOG.md`. |
| `nextEligible` | Rows `ready`, no Assignee, `Depends On` all in Archive, ordered priority then Created. |
| `render` | No-op. |

## Known limits

ID collisions and claims are best-effort. If two branches allocate the same ID, the later merge renumbers and fixes cross-references. Prefer the github-issues backend for repos with more than one concurrent agent.

## Compatibility with the sweep's old sectioned layout

A file organised as `## <Topic>` sections with `done` rows in place is a legacy layout. Read it as one live table across sections. Do not restructure it during normal operations; restructuring is its own backlog item.
