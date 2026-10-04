# Failure playbook

The scripts detect each failure and move the state; this file says what the
main agent does when `next.sh` hands it the matching action. Counting, limits
and transitions are never yours to decide.

| Failure | Detected by | Action you get | What happens |
|---|---|---|---|
| CI red | `ci-wait.sh` | `rerun_ci`, then `fix_ci` | First red: failed jobs are rerun once. Red again: one attempt is counted for every item in the batch. |
| Flaky CI | `ci-wait.sh` | `rerun_ci` | Green after the rerun: nothing is counted. |
| CI never finishes | `ci-wait.sh` deadline | `fix_ci` (timeout form) | Counts as a failed attempt. |
| One item poisons a batch | you, in `fix_ci` | `drop_item` | Its commit is reverted on the branch; it is retried in a batch of its own. |
| Item fails 3 attempts | `state.sh` | `mark_blocked` | The item is blocked and leaves its batch. |
| Hard blocker | worker report | `mark_blocked` | Blocked immediately. |
| Merge conflict | `verify-batch.sh` | `resolve_conflict` | One fix attempt, otherwise the batch is re-queued last. |
| Base branch behind | `verify-batch.sh pre-merge` | `rebase_batch` | The PR branch is updated and CI runs again. |
| Base red after merge | `verify-batch.sh post-merge`, from CI on the merge commit | `revert_batch` | The PR is reverted, the batch is blocked, the loop halts. |
| Worker lost or silent | `next.sh` deadline | `implement_batch` again | One attempt is counted for the items without a commit. |
| Crash, usage limit, closed terminal | next `/backlog-loop` | resume | State is reconciled with GitHub; merged batches are never redone. |
| Stall | `stop-gate.sh` | none | State unchanged across 2 gate checks: status `stalled`, report. |
| Concurrent run | `preflight.sh` | none | The second run refuses to start. |
| Limits reached | `next.sh` | `halt` | Status `halted`, report. `--resume` gives a fresh budget. |

## CI red (`fix_ci`)

1. Read the evidence yourself before delegating:
   `gh pr checks <pr>`, `gh run list --branch <branch> --limit 5`,
   `gh run view <run id> --log-failed`.
2. Decide which of these it is:
   - **The change is wrong.** A failing check caused by the diff.
     Delegate a fix: `state.sh worker-prompt <batch> --mode fix`, then append
     your diagnosis and the failing log lines to the prompt.
   - **One item is the cause and the rest is sound.** Name it:
     `state.sh record poison <batch> <item> --reason "..."`. The other items
     get their attempt back.
   - **You cannot tell which item.** Bisect: `git log --format='%h %s'
     origin/<base>..origin/<branch>` lists one commit per item. Ask a worker to
     run the failing check at each commit, oldest first, and report the first
     that fails.
   - **The environment is wrong** (missing secret in CI, runner out of disk).
     That is a hard blocker for the items that need it:
     `state.sh record hard-blocker <item> --reason "..."`.
3. After the worker pushed: `state.sh record fix-pushed <batch>`. It refuses
   when the branch has no new commit.

Never fix CI by deleting, skipping or loosening a test, and never by changing
the workflow so the check no longer runs.

## CI never finishes (`fix_ci`, timeout form)

The deadline (default 45 minutes per attempt) is already counted as a failed
attempt. Look for stuck or queued runs with `gh run list --branch <branch>`.
Cancel and restart them, then `state.sh record ci-retry <batch>`. If the cause
is in the code (a hanging test), delegate a fix as for a red CI.

## A poisoned batch (`drop_item`)

A worker reverts the item's commits on the batch branch in one revert commit
with the trailer `Backlog-Drop: <id>`. `state.sh record item-dropped <item>`
checks for that trailer. The item is then retried alone in a new batch, or
blocked if it has no attempts left. Batches that depended on the original
batch also wait for the retry.

## Merge conflict (`resolve_conflict`)

One attempt. The worker merges the base branch into the batch branch (never a
rebase, which would need a force-push), resolves the conflicts keeping the
intent of both sides, and pushes. Then
`state.sh record conflict-resolved <batch>`. If the worker cannot resolve it
cleanly: `state.sh record conflict-failed <batch>`. The PR is closed and the
batch is implemented again, last, from the new base. A second re-queue blocks
its items.

## Base branch red after a merge (`revert_batch`)

This is the one failure that stops the loop: the base branch must not stay
broken while more work lands on it.

1. `gh pr revert <pr>` opens the revert PR.
2. `state.sh record revert-opened <batch> <revert pr>`.
3. `ci-wait.sh --pr <revert pr>` until it prints `GREEN`, then merge it.
4. `state.sh record reverted <batch>` blocks the batch and halts the run.

If any step fails, `state.sh record revert-failed <batch> --reason "..."` halts
the run with an urgent report. Do not try to fix the regression forward.

## Blocking an item (`mark_blocked`)

`mark-blocked.sh <item> --tried "..." --why "..." --needs "..."`

- `--tried`: what was attempted, concretely (approaches, number of fixes).
- `--why`: the actual cause, from the logs or the worker report.
- `--needs`: the one input a human must provide to unblock it.

GitHub source: the text is posted on the issue with the `blocked` label. File
source: the item is annotated `BLOCKED: <reason>` in `BACKLOG.md` by the status
PR at the end of the run. The item leaves its batch and the loop continues.

## Worker problems

- **No report, or a crash:** `state.sh record worker-failed <batch> --reason "..."`.
- **Report says done, branch says otherwise:** `record worker-done` trusts the
  branch. Items without a commit carrying `Backlog-Item: <id>` count as failed.
- **Worker says an item is unclear:** `state.sh record unclear <item>
  --question "..."`, then `record worker-done`. The item is researched and the
  batch continues with it.
- **Worker past its deadline** (default 120 minutes): `next.sh` counts a failed
  attempt. Stop the hung worker if it is still listed as running.

## Stall, limits, and resuming

- **Stalled:** the Stop hook saw the same state on consecutive checks. Read
  `run.log` for the last action, fix what kept it from completing, then
  `/backlog-loop --resume`.
- **Halted on a limit:** `/backlog-loop --resume` continues with a fresh
  iteration and wall-clock budget.
- **Resume after a crash:** `preflight.sh` runs quick checks, `state.sh resume`
  reconciles every in-flight batch with GitHub: a merged PR moves to
  verification, a closed PR resets its batch, a lost worker is started again.
