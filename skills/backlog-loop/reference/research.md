# Research on unclear items

Unclear is not a blocker. When an item is ambiguous, underspecified, or open
to several valid approaches, the loop researches, decides, records the
decision, and continues.

## Protocol

1. `next.sh` returns `research` for the item.
2. `state.sh research-prompt <item>` prints the prompt below. Pass it verbatim
   to one `Explore` subagent (read-only). If the `Explore` type is not
   available, use a `general-purpose` subagent with the same prompt.
3. Write the decision record to `.planning/backlog-loop/decisions/<item>.md`
   from the template below.
4. `state.sh record decision <item> --confidence high|medium|low` checks the
   record, stores it, posts it on the issue, and adds the `needs-review` label
   when confidence is low. The record is also included in the PR description
   and in the worker's prompt.

One research pass per question. The scripts refuse a second pass for the same
item. If the research agent returns nothing useful, decide from what the
codebase shows and set confidence to `low`. Low confidence still proceeds.

## Decision rules

Apply in this order:

1. An existing convention in this codebase beats a generic best practice.
2. The smallest reversible change wins.
3. No new dependency unless nothing in the repository fits.
4. When two options are equal under the rules above, take the one the issue
   thread leans towards. If the thread is silent, take the one with fewer
   moving parts.

## Sources, in this order

1. This codebase: existing patterns, similar features, tests, git history,
   `CLAUDE.md` or `AGENTS.md`, ADRs.
2. The issue thread and linked pull requests.
3. External documentation, for the versions pinned in the repository.

## Research prompt

<!-- BEGIN prompt -->
Research one backlog item and report findings. You are read-only: do not
edit files, do not run commands that change anything.

Item {{REF}}: {{TITLE}}

Question to answer: {{QUESTION}}

Use these sources, in this order, and stop as soon as the question is settled:

1. This codebase: existing patterns for the same kind of problem, similar
   features, their tests, `git log` for how comparable changes were made,
   CLAUDE.md, AGENTS.md and any ADRs.
2. {{SOURCE}}
3. {{WEB}}

Budget: one pass, at most 15 minutes or 40 tool calls. Do not follow tangents.

Report, in this order:

- The options that are actually viable, at most three, each in one or two lines.
- For each option: the evidence, with file paths and line numbers.
- Which option matches existing convention in this codebase, and where.
- Which option is the smallest reversible change.
- Whether any option needs a new dependency.
- What you could not determine.
<!-- END prompt -->

## Decision record template

Copy this to `.planning/backlog-loop/decisions/<item>.md`. All six headings
are required; `state.sh record decision` rejects a record that lacks one.

```markdown
# Decision for <item>: <title>

## Question

<the one question that had to be settled>

## Options

1. <option>: <one line>
2. <option>: <one line>

## Choice

<the option taken, and the one-sentence reason>

## Evidence

- `path/to/file.ext:42`: <what it shows>
- <issue comment or doc link>: <what it shows>

## Assumptions

- <what is assumed to be true and was not verified>

## Confidence

<high | medium | low>: <why>
```

Confidence levels:

| Level | Meaning |
|---|---|
| `high` | The codebase or the issue thread settles it. |
| `medium` | Convention points one way; some assumption remains. |
| `low` | A judgement call. The item gets `needs-review` in state, in the report, and as a label. |
