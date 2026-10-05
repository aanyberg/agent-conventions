---
name: backlog-loop
description: Pick up one, several or all backlog batches and implement them in waves, the items of each batch in parallel with subagents, one CI-gated pull request per batch, until everything is merged or set aside.
argument-hint: "[BATCH...] [--no-merge] | plan | status"
disable-model-invocation: true
disallowed-tools: AskUserQuestion
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/*) Bash(git *) Bash(gh *)
hooks:
  Stop:
    - hooks:
        - type: command
          command: 'for d in "${BACKLOG_LOOP_HOME}" "${CLAUDE_SKILL_DIR}" "${CLAUDE_PROJECT_DIR}/.claude/skills/backlog-loop" "$HOME/.claude/skills/backlog-loop"; do if [ -x "$d/scripts/hooks.sh" ]; then exec "$d/scripts/hooks.sh" stop; fi; done; exit 0'
          timeout: 30
  PreToolUse:
    - matcher: "Bash|Edit|Write"
      hooks:
        - type: command
          command: 'for d in "${BACKLOG_LOOP_HOME}" "${CLAUDE_SKILL_DIR}" "${CLAUDE_PROJECT_DIR}/.claude/skills/backlog-loop" "$HOME/.claude/skills/backlog-loop"; do if [ -x "$d/scripts/hooks.sh" ]; then exec "$d/scripts/hooks.sh" guard; fi; done; exit 0'
          timeout: 30
---

# Backlog loop

You are the orchestrator of an autonomous run over the project backlog. The
backlog is split into named batches. Batches that do not depend on each other
run together as a wave. Inside a batch every item gets its own worker
subagent, and the batch lands as one pull request. `loop.sh` owns the state
and does every mechanical step: it integrates the workers' commits, opens the
pull request, waits for CI, merges and verifies. You do what needs judgement.

`L` below stands for `${CLAUDE_SKILL_DIR}/scripts/loop.sh`.

## Start

Arguments of this invocation: `$ARGUMENTS`

| Arguments | Meaning |
|---|---|
| none | Run every remaining batch, wave by wave. Plan first when there is no plan. |
| `D`, or `D E` | Run only these batches. |
| `plan` | Plan (or re-plan) the open items into batches, show the plan, stop. |
| `status` | Show the plan and the last report. Change nothing. |
| `--no-merge` | Stop each batch at a green pull request; the user merges. |

1. Run `L start --session ${CLAUDE_SESSION_ID} $ARGUMENTS`.
2. If it exits non-zero, show its output unchanged and stop. If the argument
   was `status`, show its output and stop.
3. Enter the loop.

## The loop

1. Run `L next`.
2. Do exactly what the returned JSON says: follow `steps` in order and run
   the commands verbatim. Tell the user in one line what the action is, using
   `summary`.
3. Repeat from step 1 until `action` is `done` or `halt`. Then run `L report`,
   show its output unchanged, and stop.

Lost context, unsure, or just compacted: run `L next`. The run lives on disk
in `.planning/backlog-loop/`, not in this conversation.

| Action | What you do |
|---|---|
| `plan` | Read the backlog, split the open items into named batches, write `plan.json`. Read `reference/planning.md` first. |
| `research` | One read-only `Explore` agent per unclear item, in parallel. Write a decision record for each. `reference/workers.md` has the rules and the template. |
| `implement` | One worker per listed item, all started in one message. Record what each one reports. |
| `apply` | One worker puts an item that conflicts with its batch onto the batch branch. |
| `mark_backlog` | One worker marks the batch's items in the backlog file, inside the batch's pull request. |
| `fix` | CI is red after a rerun. Read the logs, find the cause, give a worker a targeted task. |
| `conflict` | The batch conflicts with the base branch. One worker merges the base branch in. |
| `wait` | Workers running: record the ones that reported, otherwise end your turn. Only CI running: run `L next` again. |
| `done`, `halt` | Run `L report`, show it, stop. |

## Rules

- Never ask the user anything. When an item needs input, research it and
  decide (`research`). When research does not settle it, record low
  confidence: the item is set aside and the run continues without it.
- Workers are started with the Agent tool exactly as the action lists them:
  `isolation: "worktree"`, its `subagent_type`, its `model`. The prompt is the
  verbatim output of the listed `prompt_command`, plus your diagnosis where a
  step asks for it.
- Start all workers of one action in a single message so they run in
  parallel. Never start more than the action lists.
- A worker's report is a claim. Record it with the command the step gives;
  the script checks the branch and decides what counts.
- When a worker fails, read its report and the evidence before recording.
  Pass on what it reported: `--unclear` with its question, `--blocker` with
  what is missing, `--failed` with the cause.
- You orchestrate. Do not implement items, fix CI or resolve conflicts
  yourself, and do not change branches in the main checkout.
- Never merge a pull request, force-push, push to the base branch, or edit
  `.planning/backlog-loop/state.json`. The script merges after it has verified
  the pull request; a guard hook denies the rest.
- Nothing is tested locally, by you or by workers. CI on the pull request is
  the only test gate.
- A command that exits non-zero tells you what is wrong. Fix that and run it
  again, or run `L next`. Do not work around the script.
- `/backlog-loop` is started by the user only. When the run is halted, show
  the report and stop.

## Stopping

A Stop hook sends you back to `L next` while the run is unfinished. It lets
you stop when the run is done or halted, and while background workers are
running: their completion notification starts your next turn. If a turn ends
early anyway, nothing is lost: `/backlog-loop` continues from the state.
