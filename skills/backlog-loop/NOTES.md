# Notes: design decisions and known limits

`backlog-loop` was rewritten on 2026-10-05. The first version ran the whole
backlog through sequential batches with nine scripts and one agent action per
state. This version is built around how the skill is actually used: "pick up
batch D", several batches at once, one pull request each.

## Decisions

Each was confirmed by the owner before the rewrite.

| Decision | Why |
|---|---|
| Batches are named and stored with the state. `/backlog-loop D` runs one. | The backlogs in use have no durable batch structure; batch names existed only in chat. |
| Batches run in waves: every batch whose `needs` are merged starts together. | Sequential batches left workers idle whenever a batch was small. |
| One script, `loop.sh`, does every mechanical step. The agent gets only `plan`, `research`, `implement`, `apply`, `mark_backlog`, `fix`, `conflict`, `wait`, `done`, `halt`. | Fewer agent-facing actions means fewer places where a prompt can go wrong, and less to re-learn after a compaction. |
| The script merges; the guard denies every `gh pr merge` from the agent. | A merge then always follows the script's own check that the pull request is green and contains the base branch. |
| A later batch of a wave is updated from the base branch and tested again before it merges. | Two batches that pass alone can fail together. The cost is one more CI run per later batch. |
| A batch updates only when no earlier batch of the wave is on its way to a merge. | Otherwise it would be behind again right after, and every batch would pay several CI runs. |
| Low research confidence sets the item aside. It is not built. | "If something is still not clear, put the item to the side." A guess that merges costs a revert. |
| A red base branch after a merge: open the revert pull request, halt, leave the merge of the revert to the user. | No more work lands on a red base, and an unattended revert merge is avoided. |
| The planner reads the backlog; the script never parses it. With a file source a worker marks the items in the batch's own pull request. | Backlog files differ per repository (wide tables, archive and blocked sections). An agent follows the file's conventions; an awk parser could not. |
| No compatibility with the first version's state or configuration keys. | A rewrite; `state.json` carries `version: 3` and older state is refused with a message. |

Not carried over from the first version: `--plan-only` (now `plan`),
`--resume` (run the command again), `--gitignore`, per-tier project agents,
`batch-commits: squashed`, labels on issues, the iteration limit, and
automatic re-queueing of items into new batches. An item that leaves its
batch is reported as remaining and is planned again by `/backlog-loop plan`.

## Verified Claude Code behaviour

Checked against Claude Code 2.1.289 for the first version; the rewrite relies
on the same points.

| Point | Consequence |
|---|---|
| `${CLAUDE_SKILL_DIR}` is substituted in the skill body and in `allowed-tools`, not in hook commands. | The hook command looks for `hooks.sh` in `$BACKLOG_LOOP_HOME`, the project skill directory, then the personal one, and exits 0 when none has it. |
| Skill hooks register on invocation and stay active for the session. | The hooks do nothing unless `state.json` says a run is active. |
| Stop hook input carries `session_id`, `stop_hook_active` and `background_tasks`; a block is `{"decision": "block", "reason": ...}`. | The hook allows the stop for another session's run and while background tasks run. |
| Claude Code ends the turn after 8 consecutive Stop hook blocks (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`). | The hook counts its blocks and allows the stop one below the cap, leaving the run resumable. |
| `allowed-tools` applies to the invoking turn only. | `reference/setup.md` asks for permanent allow rules. |
| In interactive sessions subagents run in the background; the turn ends and a notification starts a new one. | The `wait` action tells the agent to end its turn while workers run. |
| An Agent worktree starts from the default branch; a branch committed in it is visible from the main checkout. | The item prompt checks out `origin/<base>` itself; the script reads item branches from the main repository. |
| The Bash tool times out after 2 minutes by default. | `next` polls CI for at most 100 seconds per call and is called again. |

## Known limits

- Not verified end to end in a live session: the scenario suite drives the
  script with a stub `gh` and simulated workers. The `gh` calls were checked
  against the flags of gh 2.102, not against GitHub.
- The guard reads shell text with patterns, not a shell parser. It errs
  towards denying; a command hidden behind `eval` or a script file is not
  seen. Whether skill hooks also apply inside subagents is not documented,
  so the worker prompts repeat the rules.
- CI state is read from check runs. A repository that reports only legacy
  commit statuses looks like one without checks.
- A check that registers late can be missed: the loop waits 30 seconds after
  a push before it trusts a green result.
- A hung background worker is noticed only when `next` runs again, after
  `worker-minutes`. Nothing wakes an idle session.
- With a file backlog, set-aside items are written to the file only as part
  of their batch's pull request. If the whole batch is set aside, they appear
  in the report only.
- Git submodules and Windows are not supported.
