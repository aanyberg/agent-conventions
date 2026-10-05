# Planning batches and waves

The `plan` action asks you to split the open backlog items into named
batches. The plan is stored with the run's state, so `/backlog-loop execute D` means
the same batch tomorrow as today.

- A **batch** is one pull request. Its items are implemented at the same
  time, one worker each, and merge together after one CI run.
- A **wave** is every batch that can start now: the batches whose `needs` are
  merged. The loop forms waves itself from `needs`; you do not number them.

## Reading the backlog

Read the backlog the way this repository keeps it. Follow, in this order: the
`## Backlog loop` section of `CLAUDE.md` or `AGENTS.md`, the repository's own
instructions, then the evidence (a `BACKLOG.md`, or open GitHub issues).

Read every open item. No label, status or section narrows the list: you
decide what each item is, see the next section.

| Source | Open items are | Item id |
|---|---|---|
| `github` | Every open issue. List them with `gh issue list --state open --limit 1000 --json number,title,labels,body`. If the list comes back as long as the limit, raise the limit and list again. | The issue number. |
| `file` | Every entry of the backlog file that is not done, cancelled or archived. | The entry's id, exactly as the file writes it. |

Count the items you read. The count goes into the plan as `read`.

## Classifying the items

Put every item you read into exactly one of four classes. The first goes
into a batch; the other three go into the plan's `left_out` list with a
category and a reason.

| Class | Category | An item belongs here when |
|---|---|---|
| Buildable | (in a batch) | There is work left that a change in this repository delivers. |
| Already done | `done` | Its code is merged and nothing is left to build here. What remains happens outside the repository, such as an operator run or a rollout. |
| Blocked outside the repository | `blocked` | It waits on credentials, another repository, a third party or an owner decision that research cannot settle. |
| Not a work item | `not-an-item` | It is an epic or tracking issue, a run summary, a discussion, or a duplicate of another open item. |

Classify from the evidence, in this order:

1. **The item's text**: what it asks for and what it says is still open.
2. **The Git history and the code**: `git log --grep '#<id>'`, merged pull
   requests that name the item, and whether the code it asks for exists.
3. **The backlog's own marks**: labels such as `status:blocked`,
   `needs-human` or `status:ready`, a status column, a "Blocked" section.

The backlog's marks are evidence, not a verdict. A label can be stale: an
item marked blocked whose blocker is gone is buildable, and an item marked
ready whose code already merged is done. When the marks and the other
evidence disagree, follow the evidence and say so in the reason.

Write a reason the user can check without opening the item: name the pull
request that shipped it, the thing it waits on, or the items it tracks.

An unclear item is not left out. It is buildable with a `question`, see
"Unclear items". Only use `blocked` for an owner decision when the item
itself says the decision is the owner's.

Items that `L status` lists under "Set aside" stay out of the plan and out of
`left_out`, unless the user said what they needed has been supplied.

Run `L status` before you plan again. Keep the name and content of a batch
that has not changed, so that the names the user knows stay valid. Merged
batches keep their names; a new batch must not reuse one.

## How to group items

A batch is a group a reviewer would recognise: one theme, one pull request.
Build the plan in three steps.

**1. Group by theme.** Put items together that belong to the same thing. Use
the strongest signal the backlog gives, in this order:

- the backlog's own grouping: an epic, a milestone, a section heading, a
  category or area column, a label such as `area:checkout`;
- the same feature or user-facing surface (the address form, the receipt
  email);
- the same part of the code (one module, one service, one schema);
- the same kind of work (copy fixes, dependency bumps, test gaps), for items
  that fit no feature group.

Name the theme in the batch's `theme`, in the words the backlog uses.

**2. Follow the relation chains.** Read each item's "depends on", "blocked
by" and "after #n" links, and the links in its text. A chain is a set of
items where one needs another's code.

- Items of one chain belong to the same theme, even when the backlog files
  them under different categories. Move them together.
- Items of a batch are built at the same time, so two items of a chain cannot
  share a batch. Cut the chain into steps: the items that need nothing go into
  the theme's first batch, the items that need those into its next batch, and
  so on. Link the steps with `needs`.
- Give the steps of one theme the same theme text with a step suffix, for
  example "Address form (1/2)" and "Address form (2/2)".

**3. Check each batch against the limits below**, and split or regroup the
ones that break them. Split along a sub-theme, not arbitrarily.

A theme with a single item is a batch of one. Do not pad a batch with
unrelated items to fill it.

## Limits of one batch

1. **Independent items.** They are built at the same time from the same base.
   None may need another's code: that is a chain, see step 2.
2. **Items that do not edit the same lines.** Their commits are combined onto
   one branch. A conflict costs an extra worker, and the item leaves the batch
   if that fails. Items of one theme often touch the same file; when they
   would edit the same lines, put them in consecutive steps of the theme.
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

- Give a batch `needs` when it builds on another batch's code: the next step
  of a relation chain, or items that say "after #n". Same theme alone is not
  a dependency.
- Batches without `needs` between them start together, at most
  `parallel-batches` at once (default 3).
- Keep batches of one wave in different parts of the code. Two batches that
  edit the same files conflict when the second is updated; that costs a
  worker, and the batch is set aside if it cannot be resolved. When two
  batches must touch the same files, chain them with `needs`.
- A batch whose needed batch is set aside does not run. Do not chain batches
  that are only loosely related.

## Names

Name batches `A`, `B`, `C`, … in the order they should run, keeping the
steps of one theme next to each other. Continue after the
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

Planning builds nothing. The user starts the work with
`/backlog-loop execute`, for all batches or by name.

Write `.planning/backlog-loop/plan.json`, then run `L plan-apply`. It checks
the plan and names every problem.

```json
{
  "source": "file",
  "backlog": "BACKLOG.md",
  "read": 6,
  "left_out": [
    {"id": "008", "title": "Send the receipt email", "category": "done", "reason": "Shipped in #41; only the provider's domain check is left."},
    {"id": "030", "title": "Checkout epic", "category": "not-an-item", "reason": "Tracks 012, 015, 021 and 029."}
  ],
  "batches": [
    {
      "name": "A",
      "theme": "Address form (1/2): validation",
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
      "theme": "Address form (2/2): checkout summary",
      "rationale": "Builds on the validators of batch A (029 depends on 012).",
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
| `read` | yes | How many open items you read. At least the number of items the plan names. |
| `left_out` | no | The items you read and did not plan. Each has `id`, `title`, `category` (`done`, `blocked` or `not-an-item`) and `reason`. No item is both in a batch and left out. |
| `batches[].name` | yes | Letters, digits, dot, dash, underscore. Unique, and not the name of a merged batch. |
| `batches[].theme` | yes | A few words. Shown in the plan and the report. |
| `batches[].title` | no | The pull request title, in the repository's commit convention: a squash merge uses it as the commit subject. Defaults to the theme. |
| `batches[].rationale` | no | One or two lines for the pull request body. |
| `batches[].needs` | no | Names of earlier batches that must be merged first. |
| `batches[].tier`, `items[].tier` | no | `light`, `standard` or `complex`. Default `standard`. |
| `items[].id`, `items[].title` | yes | The id as the backlog writes it; an issue number for `github`. Each item is in exactly one batch. |
| `items[].question` | no | Marks the item unclear, with the one question to research. |

`batches` may be empty when nothing is buildable. The report then says so
and lists what was left out.

A plan replaces every batch that has not started. Merged batches and batches
that wait for the user's merge stay as they are. An item that was set aside
returns only when the new plan names it. The `left_out` list is replaced as a
whole.
