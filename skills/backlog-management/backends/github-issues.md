# Backend: github-issues

Use the repository's existing issue fields, labels, and lifecycle when present.
The schema below is the fallback for a repository that has chosen GitHub Issues
but has no established backlog convention. Confirm it before creating labels
or rewriting existing issues.

ID = issue number. In the fallback schema, labels are the state machine and the
closed state carries `done` or `cancelled`.

## Label scheme

`type:*`, `priority:*`, `status:*` (backlog, ready, active, in-review, blocked), `ns:*` (optional namespace), `source:*`, `needs-discussion`, `agent-safe`. Exactly one `type:`, one `priority:`, one `status:` per open issue. `done` = closed completed. `cancelled` = closed not planned.

## Body headings (parse and write exactly)

`## Goal`, `## Acceptance Criteria` (checkboxes), `## Depends On` (`#n` list or `none`), `## Evidence`, `## Origin` (`source:`, `created:`, `run:`, `task:` or `pr:`), optional `## Open Question`, optional `## Blocker` (evidence, completed work, blocker, next action).

## Operations

| Op | Command |
|---|---|
| `list` | `gh issue list --state all --limit 500 --json number,title,labels,assignees,state,stateReason,body,createdAt` then filter locally. |
| `dedupe` | `gh issue list --state all --search "<topic>" --json number,title,state` plus a local title fuzzy match on `list`. |
| `create` | `gh issue create --title "<title>" --body-file <tmp> --label type:x --label priority:x --label status:backlog --label source:x`. Never pass an ID. |
| `needsDiscussion` | `create` plus `--label needs-discussion`, body includes `## Open Question`. |
| `claim` | Read issue. Require `status:ready`, no assignee. Then in one `gh issue edit`: `--add-label status:active --remove-label status:ready --add-assignee @me`. Re-read and verify assignee is you and label flipped, otherwise treat as lost race and abort. Comment `claimed by run <run_id>, branch <branch>`. |
| `setStatus` | `gh issue edit --add-label status:<new> --remove-label status:<old>`. For `blocked`, also comment with the `## Blocker` block and append it to the body. |
| `link` | PR body must contain `Closes #<id>`. `gh issue edit --add-label status:in-review --remove-label status:active`. Comment with PR URL. |
| `release done` | Verify PR merged (`gh pr view --json state`). `gh issue close --reason completed --comment "<note>"`, remove `status:*` labels. |
| `release cancelled` | `gh issue close --reason "not planned" --comment "<reason>"`. |
| `release backlog` | Remove assignee, set `status:ready` (if criteria intact) or `status:backlog`, comment why. |
| `inFlight` | `list` filtered to `status:active` or `status:in-review`, join with `gh pr list --state open --json number,headRefName,body` on `Closes #n`. |
| `nextEligible` | `list` filtered to ready, explicitly agent-safe, unassigned items whose dependencies are closed. Sort by repository priority, then age. |
| `render` | Run the repository's existing renderer when one exists. Do not create a Markdown mirror by default. |

## Labels the migration and triage own

`agent-safe` is set only by triage or a human. It means the criteria are
testable, no product or structural decision is open, and the work fits the
authorized autonomous scope. The implementer treats absence as "not
selectable" even if `status:ready`.

## Failure handling

`gh` auth or rate-limit error → stop the operation, report, do not fall back to editing `BACKLOG.md`.
