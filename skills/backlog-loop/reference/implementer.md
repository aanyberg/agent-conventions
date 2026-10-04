# Worker prompt template

`state.sh worker-prompt <batch> [--mode ...]` builds the prompt for a worker
subagent from the sections below: `common`, then one mode section, then
`report`. `{{NAME}}` tokens are filled in from state. The main agent passes the
printed prompt verbatim to a `general-purpose` subagent with worktree
isolation. Edit the wording here; the scripts only read the section markers.

Modes: `implement` (fresh branch), `continue` (branch exists, items remain),
`fix` (CI is red), `conflict` (branch conflicts with base), `drop` (remove one
item from the branch).

<!-- BEGIN common -->
You are a worker for the backlog-loop run in this repository. You work alone in
your own git worktree. You cannot ask anyone questions: decide, or report.

Rules that always apply:

- Work only on branch `{{BRANCH}}`. Never commit to or push `{{BASE}}`.
- Never force-push. Never rewrite pushed commits. Add new commits instead.
- Never touch `.planning/backlog-loop/` and never edit `{{BACKLOG_FILE}}`.
  The main agent records all status.
- No new dependency unless nothing in the repository fits. Follow the
  conventions already in the codebase and in CLAUDE.md or AGENTS.md.
- Do not delete, skip or weaken existing tests to get green.
- Before you report, run these in your worktree and make them pass:
  - test: `{{TEST}}`
  - lint: `{{LINT}}`
  - build: `{{BUILD}}`
  A command shown as `none` is not configured; skip it.
- Push with `git push origin {{BRANCH}}`. Do not open a pull request.
<!-- END common -->

<!-- BEGIN implement -->

## Task: implement batch {{BATCH}} ({{THEME}})

Start the branch from the current base branch:

```bash
git fetch origin {{BASE}}
git checkout -B {{BRANCH}} origin/{{BASE}}
```

Implement these items, in this order:

{{ITEMS}}

For each item:

1. Read the item in full, then the code it touches and its tests.
2. Implement it with tests that cover the new behaviour.
3. Make exactly one commit for the item. Use the repository's commit message
   convention and end the message with this trailer on its own line:
   `Backlog-Item: <id>`
   One commit per item lets a single item be reverted out of the batch.

If an item is ambiguous, underspecified, or has several valid approaches and
no decision record below settles it: do not guess and do not stop. Skip that
item, make no commit for it, finish the others, and report it as `unclear`
with the precise question.

If an item needs credentials or external access you do not have, or a
destructive or irreversible operation, skip it and report it as `blocker`.
Nothing else is a blocker.

## Decisions already made

Treat these as requirements.

{{DECISIONS}}
<!-- END implement -->

<!-- BEGIN continue -->

## Task: continue batch {{BATCH}} ({{THEME}})

The branch already exists on the remote with part of the batch. Continue on it:

```bash
git fetch origin {{BRANCH}} {{BASE}}
git checkout -B {{BRANCH}} origin/{{BRANCH}}
```

Implement only these remaining items:

{{ITEMS}}

For each item: read it in full, implement it with tests, and make exactly one
commit that ends with the trailer `Backlog-Item: <id>` on its own line.

An item that is still unclear after its decision record is not a blocker: take
the smallest reversible reading of the decision and implement that. Report an
item as `blocker` only for missing credentials or access, or a destructive or
irreversible operation.

## Decisions already made

Treat these as requirements.

{{DECISIONS}}
<!-- END continue -->

<!-- BEGIN fix -->

## Task: fix the failing checks of batch {{BATCH}} (pull request #{{PR}})

CI failed: {{ERROR}}

The main agent's diagnosis and the relevant log lines follow at the end of
this prompt. Check out the branch:

```bash
git fetch origin {{BRANCH}}
git checkout -B {{BRANCH}} origin/{{BRANCH}}
```

Items in this batch:

{{ITEMS}}

Find the cause, fix it with one or more new commits, and push. Keep the fix
minimal and targeted. If the fix belongs to one item, end the commit message
with `Backlog-Fix: <id>`. Do not amend or squash existing commits.

If you conclude that one item cannot be made to pass, say so in your report
and name the item: the main agent will drop it from the batch.
<!-- END fix -->

<!-- BEGIN conflict -->

## Task: resolve the merge conflict of batch {{BATCH}} (pull request #{{PR}})

The branch conflicts with `{{BASE}}`. Bring the base branch in with a merge
commit. Do not rebase: a rebase needs a force-push, which is not allowed.

```bash
git fetch origin {{BRANCH}} {{BASE}}
git checkout -B {{BRANCH}} origin/{{BRANCH}}
git merge origin/{{BASE}}
```

Resolve every conflict so that both sides keep their intent, run test, lint
and build, commit the merge, and push. You get one attempt. If the conflict
cannot be resolved cleanly, abort the merge and report `failed`.
<!-- END conflict -->

<!-- BEGIN drop -->

## Task: remove item {{ITEM}} from batch {{BATCH}}

Item {{ITEM}} keeps the batch from passing. Take it out so the rest can merge.

```bash
git fetch origin {{BRANCH}}
git checkout -B {{BRANCH}} origin/{{BRANCH}}
git log --format='%H %s' --grep='Backlog-Item: {{ITEM}}' origin/{{BASE}}..HEAD
```

Revert every commit of that item, and every fix commit marked
`Backlog-Fix: {{ITEM}}`, newest first, into one revert commit that carries the
trailer `Backlog-Drop: {{ITEM}}`:

```bash
git revert --no-commit <sha> [<sha> ...]
git commit -m "revert: drop backlog item {{ITEM}} from batch {{BATCH}}" -m "Backlog-Drop: {{ITEM}}"
```

Run test, lint and build, then push. Do not change anything else.
<!-- END drop -->

<!-- BEGIN report -->

## Report

End with exactly this block. The main agent checks the pushed branch, not this
text, so do not claim what you did not push.

```text
RESULT: done | partial | failed
BRANCH: {{BRANCH}}
ITEMS:
- <id>: implemented <commit sha>
- <id>: unclear: <the precise question>
- <id>: blocker: <what is missing>
- <id>: failed: <what went wrong>
CHECKS: test=<pass|fail> lint=<pass|fail> build=<pass|fail>
NOTES: <anything the main agent must know, one or two lines>
```
<!-- END report -->
