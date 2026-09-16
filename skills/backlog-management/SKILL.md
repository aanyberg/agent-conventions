---
name: backlog-management
description: Single interface for listing, creating, claiming, linking, and updating work items. Reuses the repository's tracker and asks the user to choose a backend only when existing evidence is ambiguous.
---

# Backlog Management

One interface with optional GitHub Issues and Markdown adapters. Loading this
skill never creates configuration or chooses a tracker by itself.

## 1. Resolve the backend

Resolve the backend once per conversation, before the first backlog operation:

1. Honor an explicit selection in the user's request: GitHub Issues,
   `BACKLOG.md`, or no persistent backlog.
2. Read repository instructions such as `AGENTS.md`, `CONTRIBUTING.md`, and the
   README for any of the same three selections. Any documented selection is
   authoritative.
3. Only when neither the request nor repository instructions select an option,
   inspect existing state without modifying it:
   - `BACKLOG.md` with work-item records is evidence for the Markdown backend.
   - A clearly established GitHub Issues work-item structure, including
     repository-specific labels, fields, projects, or statuses, is evidence for
     the GitHub Issues backend.
   - A GitHub remote or enabled Issues feature alone is not a backend choice.
4. If an explicit or documented selection exists, use it and stop resolution.
   No persistent backlog means conversation-only tracking. Otherwise, if
   exactly one backend is established, use it. If neither or both are
   plausible, ask the user to choose:
   - GitHub Issues
   - `BACKLOG.md`
   - no persistent backlog
5. State the selection. Load `backends/<backend>.md` only for GitHub Issues or
   Markdown.

Do not create a policy or private configuration file to remember the answer.
Keep it for the current conversation. If the user wants a durable choice,
record it only in an existing repository instruction file they select.

If no persistent backlog is selected, return or maintain the work list in the
conversation and do not perform mutation operations.

## 2. Adapt to the repository

The backend files describe the supported fallback schema. Existing repository
labels, fields, statuses, ID formats, and contribution rules take precedence.
Map the operations below onto those conventions rather than creating a second
lifecycle.

If the selected backend exists but has no established schema, show the fallback
schema from its adapter and get confirmation before creating labels, tables, or
other persistent structure.

## 3. Fallback status model

Use this model only when the selected backend has no existing lifecycle and the
user confirms it:

```text
backlog -> ready -> active -> in-review -> done
   \-> blocked          \-> cancelled
```

| Status | Meaning | Who sets it |
|---|---|---|
| `backlog` | Identified; criteria may be incomplete | Humans or agents recording follow-up work |
| `ready` | Criteria are clear and testable | Human or repository triage |
| `active` | Assigned and being implemented | Claimant |
| `in-review` | Change is under review | Claimant |
| `blocked` | Needs a decision or external dependency | Anyone, with evidence |
| `done` | Completion evidence is verified | Releaser |
| `cancelled` | Work will not be done | Human or repository triage |

Do not skip directly from `backlog` to `done`. Preserve the repository's
existing transitions when they differ.

## 4. Operations

| Operation | Contract |
|---|---|
| `list(filter)` | Return items with the fields supported by the backend. |
| `dedupe(topic)` | Search open and terminal items before creating a duplicate. |
| `create(item)` | Record a goal, testable acceptance criteria, dependencies, evidence, and origin. Let the backend assign or derive the ID. |
| `needsDiscussion(item, question)` | Record the item as unresolved with an explicit question; do not mark it ready. |
| `claim(id, run_id)` | Verify the item is available, assign it atomically when possible, and re-read to detect races. |
| `setStatus(id, status, note)` | Apply a valid repository transition. A blocked state includes evidence, completed work, blocker, and next action. |
| `link(id, change)` | Link the item and pull request/change in both directions when supported. |
| `release(id, outcome, note)` | Mark done, cancelled, or unclaimed only after the repository's completion requirements are satisfied. |
| `inFlight()` | Return assigned or review-stage items and their branches or changes. |
| `nextEligible(n)` | Return ready, unassigned, dependency-free items only when the user has authorized autonomous selection. |
| `render()` | Refresh a human-readable mirror only when the repository already maintains one. |

## 5. Item quality

New items should contain a concise goal, testable acceptance criteria,
dependencies, evidence, and origin. Do not fabricate evidence or identifiers.

Autonomous agents select work only when the user or calling routine explicitly
authorizes selection and the repository marks the item safe for agents. If the
repository has no such marker, do not self-select.

## 6. Failure handling

- Authentication, authorization, or rate-limit failures stop the operation.
  Never silently switch backends.
- Do not migrate legacy files or labels automatically. Report the discovered
  state and ask before moving or restructuring persistent backlog data.
- Record follow-up work only after a backend has been resolved. Otherwise
  return the follow-up in the response.
