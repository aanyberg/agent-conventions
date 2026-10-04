# Batching rules

The `plan` action asks you to cluster the open items into batches. Each batch
becomes one pull request. Aim for few batches (around ten for a hundred items),
but never at the price of a PR nobody can review.

## Order of clustering

1. **Dependency chains first.** Items that build on each other go into the same
   batch, or into ordered batches linked with `depends_on`.
2. **Then theme.** Items about the same feature area, the same kind of change
   (all dependency bumps, all copy fixes), or the same user-visible flow.
3. **Then files touched.** Items that edit the same files belong together:
   apart, they produce merge conflicts between batches.

## What a batch must satisfy

- **Reviewable.** One reviewer can understand it in one sitting. As a guide:
  at most about 400 changed lines or 10 items, whichever comes first. The hard
  limit is `max-batch-items` (default 15); `state.sh plan-apply` rejects more.
- **One kind of risk.** Do not mix a schema migration with copy changes, or a
  dependency upgrade with a feature. If one part had to be reverted, the rest
  should not have to go with it.
- **Independent of later batches.** A batch may depend only on earlier batches.
- **Revertible per item.** Each item must be implementable as one commit. Split
  an item that cannot be, or give it a batch of its own.

## Choosing sizes

- A risky or large item gets its own batch.
- Small mechanical items (typos, renames, config tweaks) can share a large batch.
- An unclear item goes into the batch its theme points to, and into `unclear`
  with the question. It is researched before its batch starts.
- Prefer two medium batches over one that only just fits the limit. Independent
  batches are implemented in parallel, so splitting costs little.
- Aim for at least as many independent batches as `parallel-batches` (default
  4). A plan whose batches form one chain runs one worker at a time.
- Do not create a batch per item unless the items really are unrelated. Every
  batch costs a full CI cycle, plus one more when the base branch has moved.

## Dependencies

- `depends_on` lists earlier batch numbers. A batch starts only after those are
  merged.
- Add a dependency only for a real one: shared code that must exist first, or
  an item that says "after #n". Same theme or same area is not a dependency.
  An unnecessary dependency removes parallelism,
  and with `--no-merge` it stalls the dependent batch until you merge.
- If a batch ends up blocked, the batches that depend on it are blocked too.

## Model tier

Each batch gets a `tier`, which picks the model its workers run on:

| Tier | Default model | Use for |
|---|---|---|
| `light` | Haiku | Mechanical changes: typos, copy, renames, config values, docs, dependency bumps with no code changes. |
| `standard` | Sonnet | Ordinary feature work and bug fixes in code you can read locally. The default. |
| `complex` | Opus | Cross-cutting changes, concurrency, security, data migrations, or logic where a wrong guess is costly. |

Pick the tier for the hardest item in the batch. When in doubt, choose
`standard`. Fix, conflict and drop workers use the batch's tier. The project
can map tiers to other models (`reference/setup.md`).

## Plan format

Write `.planning/backlog-loop/plan.json`:

```json
{
  "batches": [
    {
      "theme": "Address form validation",
      "title": "feat(forms): validate address fields",
      "rationale": "Three items change the same validator and its tests.",
      "tier": "standard",
      "items": ["12", "15", "21"],
      "depends_on": []
    },
    {
      "theme": "Checkout summary",
      "title": "feat(checkout): show validated address in summary",
      "items": ["29"],
      "depends_on": [1]
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
- `items`: ids as strings. Every open item appears in exactly one batch.
- `depends_on`: batch numbers (1-based position in `batches`), earlier only.
- `unclear`: items that need a research pass, each with one precise question.

`state.sh plan-apply` validates the plan, writes `plan.md` with each batch's
model, and with
`--plan-only` halts the run so the plan can be reviewed.
