# Worker prompt template

`state.sh worker-prompt <batch> [--mode ...]` builds the prompt for a worker
subagent from the sections below: `common`, then one mode section, then
`report`. `{{NAME}}` tokens are filled in from state. The main agent passes the
printed prompt verbatim to a `general-purpose` subagent with worktree
isolation. Edit the wording here; the scripts only read the section markers.

Modes: `item` (one item on its own local branch), `apply` (put a conflicting
item onto the local batch branch), `fix` (CI is red), `conflict` (branch
conflicts with base), `drop` (remove one item from the branch).

<!-- BEGIN common -->
You are a worker for the backlog-loop run in this repository. You work alone in
your own git worktree. You cannot ask anyone questions: decide, or report.

Rules that always apply:

- Work only on the branch your task below names. Never commit to or push
  `{{BASE}}`.
- Never force-push. Never rewrite pushed commits. Add new commits instead.
- Never touch `.planning/backlog-loop/` and never edit `{{BACKLOG_FILE}}`.
  The main agent records all status.
- No new dependency unless nothing in the repository fits. Follow the
  conventions already in the codebase and in CLAUDE.md or AGENTS.md.
- Do not delete, skip or weaken existing tests to get green.
- Do not run the test suite, the linter or the build. Testing happens only in
  the repository's CI, on the pull request. Write the tests your change needs
  and read the code carefully; CI is the judge.
- Push only when your task below says so. Do not open a pull request.
<!-- END common -->

<!-- BEGIN item -->

## Task: implement item {{ITEM}} of batch {{BATCH}} ({{THEME}})

Other workers implement the other items of this batch at the same time, each
on its own branch. Start your branch from the current base branch:

```bash
git fetch origin {{BASE}}
git checkout -B {{ITEM_BRANCH}} origin/{{BASE}}
```

Your item:

{{ITEMS}}

1. Read the item in full, then the code it touches and its tests.
2. Implement it with tests that cover the new behaviour. Touch only what the
   item needs: unrelated edits collide with the other workers' items.
3. Make exactly one commit. Use the repository's commit message convention
   and end the message with this trailer on its own line:
   `Backlog-Item: {{ITEM}}`
4. Do not push. The branch is local; the main agent reads it from the
   repository and assembles the batch.

If the item is ambiguous, underspecified, or has several valid approaches and
no decision record below settles it: do not guess. Make no commit and report
it as `unclear` with the precise question.

If the item needs credentials or external access you do not have, or a
destructive or irreversible operation, make no commit and report it as
`blocker`. Nothing else is a blocker.

## Decisions already made

Treat these as requirements.

{{DECISIONS}}
<!-- END item -->

<!-- BEGIN apply -->

## Task: apply item {{ITEM}} onto batch {{BATCH}} ({{THEME}})

Item {{ITEM}} was implemented on its own branch, but its commit conflicts with
the other items already on the batch branch. Apply it by hand:

```bash
git fetch origin {{BASE}}
git checkout {{BRANCH}}
git cherry-pick {{ITEM_BRANCH}}
```

Resolve every conflict so that both sides keep their intent, then
`git cherry-pick --continue`. Keep the original commit message, including the
trailer `Backlog-Item: {{ITEM}}`. Do not push: the main agent pushes the batch
branch once every item is on it.

You get one attempt. If the conflict cannot be resolved cleanly, run
`git cherry-pick --abort` and report `failed`; the item moves to the next
batch, where it is built on top of this one.
<!-- END apply -->

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

Resolve every conflict so that both sides keep their intent, commit the merge,
and push. You get one attempt. If the conflict
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

Push. Do not change anything else.
<!-- END drop -->

<!-- BEGIN report -->

## Report

End with exactly this block. The main agent checks the branch, not this text,
so do not claim what you did not commit.

```text
RESULT: done | partial | failed
BRANCH: <the branch you worked on>
ITEMS:
- <id>: implemented <commit sha>
- <id>: unclear: <the precise question>
- <id>: blocker: <what is missing>
- <id>: failed: <what went wrong>
NOTES: <anything the main agent must know, one or two lines>
```
<!-- END report -->
