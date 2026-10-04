# Batching rules

The `plan` action asks you to split the open items into batches. Batches run
one at a time, in plan order. The items of a batch are implemented in
parallel, one worker each, and land together in one pull request, so CI runs
once per batch.

Aim for few, full batches: a batch takes about as long as its slowest item
plus one CI run, and batches do not overlap.

## What goes into one batch

1. **Independent items.** Items in the same batch are implemented at the same
   time from the same base. None may need another's code.
2. **Items that do not edit the same lines.** Their commits are combined onto
   one branch; edits to the same code conflict there. A conflict is applied by
   hand once, and moves the item to the next batch if that fails.
3. **One kind of risk.** Do not mix a schema migration with copy changes, or a
   dependency upgrade with a feature. If one part had to be reverted, the rest
   should not have to go with it.
4. **Reviewable.** One reviewer can understand the PR in one sitting. As a
   guide: at most about 400 changed lines. The hard limit is
   `max-batch-items` (default 15); `state.sh plan-apply` rejects more.

Fill a batch up to `parallel-items` (default 5) or a multiple of it. Fewer
items leave worker slots idle; a batch above the limit runs in waves.

## Items that build on each other

Put an item in a later batch than the items it builds on, and name them in
`needs`:

```json
{"id": "15", "needs": ["12"]}
```

- `needs` may only name items in earlier batches.
- An item starts only when everything it needs is merged. Otherwise it moves
  to the next batch, without counting an attempt.
- If a needed item ends up blocked, the item is blocked too.
- Add `needs` only for a real dependency: shared code that must exist first,
  or an item that says "after #n". Same theme or same area is not one.

Each item must be implementable as one commit. Split an item that cannot be.

## Model tier

Each batch gets a `tier`, and an item may override it. The tier picks the
model the item's worker runs on:

| Tier | Default model | Use for |
|---|---|---|
| `light` | Haiku | Mechanical changes: typos, copy, renames, config values, docs, dependency bumps with no code changes. |
| `standard` | Sonnet | Ordinary feature work and bug fixes in code you can read locally. The default. |
| `complex` | Opus | Cross-cutting changes, concurrency, security, data migrations, or logic where a wrong guess is costly. |

Give the batch the tier most of its items need, and override the outliers.
When in doubt, choose `standard`. Workers that act on the whole batch (CI fix,
conflict, drop) use the highest tier among its items. The project can map
tiers to other models or to its own agents (`reference/setup.md`).

## Unclear items

An unclear item goes into the batch its dependencies point to, and into
`unclear` with one precise question. It is researched before it starts; the
other items of its batch do not wait for it.

## Plan format

Write `.planning/backlog-loop/plan.json`:

```json
{
  "batches": [
    {
      "theme": "Address form validation",
      "title": "feat(forms): validate address fields",
      "rationale": "Independent validators for three fields of the form.",
      "tier": "standard",
      "items": ["12", {"id": "15", "tier": "light"}, "21"]
    },
    {
      "theme": "Checkout summary",
      "title": "feat(checkout): show validated address in summary",
      "items": [{"id": "29", "needs": ["12"]}]
    }
  ],
  "unclear": [
    { "id": "29", "question": "Show the address as one line or as the form layout?" }
  ]
}
```

- `theme`: required. Becomes the batch name in the plan and the report.
- `title`: the PR title. Follow the repository's commit convention, because a
  squash merge uses it as the commit subject. Defaults to the theme.
- `rationale`: one or two lines, shown in `plan.md` and in the PR body.
- `tier`: `light`, `standard` or `complex`. Defaults to `standard`.
- `items`: an id, or `{"id", "tier", "needs"}`. Every open item appears in
  exactly one batch.
- `unclear`: items that need a research pass, each with one precise question.

`state.sh plan-apply` validates the plan, writes `plan.md` with each item's
model, and with `--plan-only` halts the run so the plan can be reviewed.
