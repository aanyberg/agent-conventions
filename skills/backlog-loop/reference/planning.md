# Planning batches and waves

The `plan` action asks you to split the open backlog items into named
batches. The plan is stored with the run's state, so `/backlog-loop D` means
the same batch tomorrow as today.

- A **batch** is one pull request. Its items are implemented at the same
  time, one worker each, and merge together after one CI run.
- A **wave** is every batch that can start now: the batches whose `needs` are
  merged. The loop forms waves itself from `needs`; you do not number them.

## Reading the backlog

Read the backlog the way this repository keeps it. Follow, in this order: the
`## Backlog loop` section of `CLAUDE.md` or `AGENTS.md`, the repository's own
instructions, then the evidence (a `BACKLOG.md`, or open GitHub issues with a
backlog label).

| Source | Open items are | Item id |
|---|---|---|
| `github` | Open issues with the configured label (default `backlog`). List them with `gh issue list --label <label> --state open --limit 200 --json number,title,labels,body`. | The issue number. |
| `file` | Entries of the backlog file that are not done, cancelled or archived. | The entry's id, exactly as the file writes it. |

Leave out:

- items that are done, cancelled or archived;
- items the backlog itself marks as blocked on something outside the
  repository (credentials, another repository, an owner decision), unless the
  user said the blocker is gone;
- items that `L status` lists under "Set aside", unless the user said what
  they needed has been supplied.

Run `L status` before you plan again. Keep the name and content of a batch
that has not changed, so that the names the user knows stay valid. Merged
batches keep their names; a new batch must not reuse one.

## What goes into one batch

1. **Independent items.** They are built at the same time from the same base.
   None may need another's code.
2. **Items that do not edit the same lines.** Their commits are combined onto
   one branch. A conflict costs an extra worker, and the item leaves the batch
   if that fails.
3. **One kind of risk.** Do not mix a schema migration with copy changes, or a
   dependency upgrade with a feature. If the batch has to be reverted, all of
   it goes.
4. **Reviewable.** One reviewer can understand the pull request in one
   sitting: as a guide, at most about eight items or 400 changed lines.

Each item must fit in one commit. Split an item that cannot.

## What goes into one wave

Batches of the same wave are built from the same base and merge one after
another. Each later one is updated from the base branch and tested again
before it merges.

- Give a batch `needs` when it builds on another batch's code, or when its
  items say "after #n". Same theme or same area is not a dependency.
- Batches without `needs` between them start together, at most
  `parallel-batches` at once (default 3).
- Keep batches of one wave in different parts of the code. Two batches that
  edit the same files conflict when the second is updated; that costs a
  worker, and the batch is set aside if it cannot be resolved. When two
  batches must touch the same files, chain them with `needs`.
- A batch whose needed batch is set aside does not run. Do not chain batches
  that are only loosely related.

## Names

Name batches `A`, `B`, `C`, … in the order they should run. Continue after the
highest letter already used (`L status` shows it). If the backlog already
groups items under its own batch names (a "Batch" column, `batch:<name>`
labels, section headings), use those names instead.

## Model tier

Each batch has a `tier`; an item may override it. The tier picks the model of
the item's worker.

| Tier | Default model | Use for |
|---|---|---|
| `light` | Haiku | Mechanical changes: typos, copy, renames, config values, docs. |
| `standard` | Sonnet | Ordinary features and bug fixes in code that can be read locally. The default. |
| `complex` | Opus | Cross-cutting changes, concurrency, security, data migrations, logic where a wrong guess is costly. |

A worker that acts on a whole batch (fix, conflict) uses the highest tier
among its items.

## Unclear items

Give an item a `question` when it is ambiguous, underspecified, or open to
several valid approaches. It is researched before it starts, and the other
items of its batch do not wait for it. Write one precise question that a
research pass can answer, not "needs clarification".

Do not hold an unclear item back yourself. Research decides whether it can be
built; only an item that research cannot settle is set aside.

## Plan format

Write `.planning/backlog-loop/plan.json`, then run `L plan-apply`. It checks
the plan and names every problem.

```json
{
  "source": "file",
  "backlog": "BACKLOG.md",
  "batches": [
    {
      "name": "A",
      "theme": "Address form validation",
      "title": "feat(forms): validate address fields",
      "rationale": "Three independent validators for fields of the same form.",
      "tier": "standard",
      "items": [
        {"id": "012", "title": "Validate the postal code"},
        {"id": "015", "title": "Fix the street label typo", "tier": "light"},
        {"id": "021", "title": "Validate the country", "question": "ISO codes or free text?"}
      ]
    },
    {
      "name": "B",
      "theme": "Checkout summary",
      "needs": ["A"],
      "items": [{"id": "029", "title": "Show the validated address in the summary"}]
    }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `source` | yes | `github` or `file`. With `file`, each batch's pull request also marks its items in the backlog file. |
| `backlog` | for `file` | Path of the backlog file. Default `BACKLOG.md`. |
| `batches[].name` | yes | Letters, digits, dot, dash, underscore. Unique, and not the name of a merged batch. |
| `batches[].theme` | yes | A few words. Shown in the plan and the report. |
| `batches[].title` | no | The pull request title, in the repository's commit convention: a squash merge uses it as the commit subject. Defaults to the theme. |
| `batches[].rationale` | no | One or two lines for the pull request body. |
| `batches[].needs` | no | Names of earlier batches that must be merged first. |
| `batches[].tier`, `items[].tier` | no | `light`, `standard` or `complex`. Default `standard`. |
| `items[].id`, `items[].title` | yes | The id as the backlog writes it; an issue number for `github`. Each item is in exactly one batch. |
| `items[].question` | no | Marks the item unclear, with the one question to research. |

A plan replaces every batch that has not started. Merged batches and batches
that wait for the user's merge stay as they are. An item that was set aside
returns only when the new plan names it.
