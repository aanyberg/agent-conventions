---
name: backlog-loop
description: Implement every item in the project backlog in themed, CI-gated pull request batches until all are merged or blocked.
argument-hint: "[--plan-only] [--resume] [--no-merge] [--gitignore]"
disable-model-invocation: true
disallowed-tools: AskUserQuestion
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(git *) Bash(gh *)
hooks:
  Stop:
    - hooks:
        - type: command
          command: 'for d in "${BACKLOG_LOOP_HOME}" "${CLAUDE_SKILL_DIR}" "${CLAUDE_PROJECT_DIR}/.claude/skills/backlog-loop" "$HOME/.claude/skills/backlog-loop"; do if [ -x "$d/scripts/stop-gate.sh" ]; then exec "$d/scripts/stop-gate.sh"; fi; done; exit 0'
          timeout: 60
  PreToolUse:
    - matcher: "Bash|Edit|Write"
      hooks:
        - type: command
          command: 'for d in "${BACKLOG_LOOP_HOME}" "${CLAUDE_SKILL_DIR}" "${CLAUDE_PROJECT_DIR}/.claude/skills/backlog-loop" "$HOME/.claude/skills/backlog-loop"; do if [ -x "$d/scripts/guard.sh" ]; then exec "$d/scripts/guard.sh"; fi; done; exit 0'
          timeout: 30
---

# Backlog loop

You are the orchestrator of an autonomous loop that implements every backlog
item through a few themed pull requests. Scripts decide. You execute.

## The loop

1. Run `${CLAUDE_SKILL_DIR}/scripts/next.sh`.
2. Do exactly what the returned JSON says. Follow `instructions` in order and
   run the commands verbatim.
3. Repeat from step 1 until `action` is `done` or `halt`. Then show the report
   and stop.

Lost context, unsure, or just compacted: run `next.sh`. The run lives on disk
in `.planning/backlog-loop/`, not in this conversation. Running `/backlog-loop`
again resumes it.

## Rules

- Never ask the user anything. An unclear item is researched and decided, not
  escalated: `state.sh record unclear <item> --question "..."`.
- Never count attempts, apply limits, pick the next step, or skip an action
  yourself. `next.sh` does that.
- Never edit `.planning/backlog-loop/state.json`. Record results only with the
  commands an action gives you. The scripts check GitHub and git, not your word.
- You orchestrate, workers implement. On any failure read the evidence (CI logs,
  diff, worker report), reason about the cause, and delegate a targeted task.
  Do not implement items yourself and do not leave the base branch in the main
  checkout.
- Never force-push, push to the base branch, merge with `--admin`, or merge a
  pull request that `verify-batch.sh <batch> pre-merge` has not declared READY.
- Hard blockers are only: missing credentials or external access, a destructive
  or irreversible operation, and three failed attempts. Ambiguity is never one.
- A script that exits non-zero tells you what is wrong. Fix that, then run
  `next.sh`. Do not work around a script.

## Start

Arguments of this invocation: `$ARGUMENTS`

1. Run `${CLAUDE_SKILL_DIR}/scripts/preflight.sh --probes $ARGUMENTS`. Run every
   printed line as its own Bash call. If one is denied or needs approval, stop
   and tell the user which permission rule is missing (see
   `reference/setup.md`, "Permissions for unattended runs").
2. Run `${CLAUDE_SKILL_DIR}/scripts/preflight.sh --session ${CLAUDE_SESSION_ID} $ARGUMENTS`.
   It runs no test suite: whether the base branch is green is read from CI.
   If it exits non-zero, show its output unchanged and stop. On success it
   starts a new run, or resumes the unfinished one.
3. Enter the loop.

## Workers

- Implementation, fixes, conflict resolution and drops: Agent tool,
  `subagent_type: "general-purpose"`, `isolation: "worktree"`. The prompt is
  the verbatim output of `state.sh worker-prompt`, plus your diagnosis when the
  action asks for it.
- Research: Agent tool, `subagent_type: "Explore"`, prompt from
  `state.sh research-prompt`. One pass per question.
- When an action lists several batches, start their workers in one message so
  they run in parallel. Never more than the action lists.
- If workers run in the background, end your turn after starting them. Their
  completion notification brings you back; then run `next.sh`.
- Nothing is tested locally, by you or by workers. CI on the pull request is
  the only test gate.
- A worker's report is a claim. `state.sh record worker-done <batch>` checks
  the pushed branch for one commit per item.

## Actions

| Action | What you do |
|---|---|
| `preflight` | Run the Start steps above. |
| `plan` | Read all items, cluster them, write `plan.json`. Read `reference/batching.md` first. |
| `implement_batch` | Start one worker per listed batch, then record what each pushed. |
| `research` | One `Explore` pass, then write the decision record. Read `reference/research.md`. |
| `open_pr` | One command; the script writes the PR body with `Closes #<id>` lines and decisions. |
| `wait_ci` | Run `ci-wait.sh`; repeat while it prints `PENDING`. |
| `rerun_ci` | One command; failed jobs are rerun once before a failure counts. |
| `fix_ci` | Read the logs, find the cause, delegate the fix or name the poisoning item. |
| `drop_item` | A worker reverts one item's commit out of the batch. |
| `rebase_batch` | One command; the PR branch is updated from the base branch. |
| `resolve_conflict` | One worker attempt, otherwise the batch is re-queued last. |
| `merge` | Verify, run the printed merge command, confirm. |
| `verify` | The script confirms the merge and reads CI on the base branch; repeat while it prints `PENDING`. |
| `revert_batch` | The base branch is red: revert the PR, then the loop halts. |
| `mark_blocked` | Run `mark-blocked.sh` with what was tried, why it failed, what is needed. |
| `sync_backlog` | File source only: the status update for `BACKLOG.md` goes out as a last PR. |
| `wait_worker` | Workers are still running: record finished ones, otherwise end your turn. |
| `halt`, `done` | Run `report.sh`, show its output, stop. |

`reference/failures.md` has the playbook for each failure type. Read it when a
`fix_ci`, `resolve_conflict` or `revert_batch` cause is not obvious.

## Stopping

A Stop hook sends you back to `next.sh` while work remains. It lets you stop
when the run is done, halted, stalled, or waiting for background workers. If
the turn ends early anyway, nothing is lost: `/backlog-loop` resumes from state.
