# Backend: markdown

`<root>/BACKLOG.md` is the source of truth. Two tables: live and `## Archive`. Same columns.

```markdown
| ID | Title | Type | Priority | Status | Assignee | Task File | PR | Depends On | Created | Acceptance Criteria Summary | Notes |
```

Preserve the existing ID format. For a new file, ask whether IDs should be
numeric (`001`) or prefixed (`LMS-001`) before creating its first item.

## Operations

| Op | Mechanics |
|---|---|
| `list` | Parse both tables. |
| `dedupe` | Grep both tables and any `## Needs Discussion` sections, case-insensitive, on title words and Notes. |
| `create` | Read the local file and relevant remote/open-change versions when available. ID = max across all of them plus one using the established format. Append a row with `Status: backlog` and `Created: today`. |
| `needsDiscussion` | Append to `## Needs Discussion (<date>)` section at end of file, create the section if the date differs from the last one. Title, 2 to 4 sentence rationale, explicit open question. No ID, no status. |
| `claim` | Re-read the row, require `ready` and no assignee, then set `Status: active` and `Assignee: <run_id>` using the repository's normal change process. Re-read after synchronization; if another claimant won, abort. Report when the backend cannot provide an atomic claim. |
| `setStatus` | Edit the row. `blocked` writes the four-part blocker note into Notes. |
| `link` | Fill `PR` cell, set `in-review`. |
| `release done` | Row → `done`, clear obsolete task references, move to Archive, and record completion evidence in Notes. |
| `release cancelled` | Row → `cancelled`, reason in Notes, move to Archive. |
| `inFlight` | Rows with `active` or `in-review`, plus open PRs whose diff touches `BACKLOG.md`. |
| `nextEligible` | Rows `ready`, no Assignee, `Depends On` all in Archive, ordered priority then Created. |
| `render` | No-op. |

## Known limits

ID collisions and claims are best-effort. If two branches allocate the same ID, the later merge renumbers and fixes cross-references. Prefer the github-issues backend for repos with more than one concurrent agent.

## Compatibility with the sweep's old sectioned layout

A file organised as `## <Topic>` sections with `done` rows in place is a legacy layout. Read it as one live table across sections. Do not restructure it during normal operations; restructuring is its own backlog item.
