# Setup, configuration and troubleshooting

Detail that the README leaves out: requirements, project configuration,
permissions for unattended runs, the run's files, resuming and fixing problems.

## Requirements and location

Requires `git`, `gh` and `jq` (1.6 or later), on macOS or Linux. Developed
against Claude Code 2.1.289 and gh 2.102. The test suite passes on macOS
(bash 3.2, jq 1.7) and on Debian 12 (bash 5.2, jq 1.6, git 2.39).

The hooks look for the skill at `~/.claude/skills/backlog-loop/` (personal) or
`<project>/.claude/skills/backlog-loop/` (project), because Claude Code does not
expand `${CLAUDE_SKILL_DIR}` in hook commands. For any other location, set
`BACKLOG_LOOP_HOME` to the skill directory in the `env` block of your settings.
See the [root README](../../../README.md) for installing skills.

## Arguments

| Argument | Effect |
|---|---|
| none | Runs preflight, plans, then loops until done. Resumes when an unfinished run exists. |
| `--plan-only` | Writes `.planning/backlog-loop/plan.md` and halts. `/backlog-loop --resume` executes the plan. |
| `--resume` | Requires an unfinished run. Reconciles it with GitHub and continues. |
| `--no-merge` | Every batch stops at a green PR. Batches that depend on an unmerged batch wait: merge, then `--resume`. |
| `--gitignore` | Writes `.planning/backlog-loop/` to `.gitignore` instead of `.git/info/exclude`. |

Arguments combine, for example `/backlog-loop --plan-only --no-merge`.

Start from the repository's main checkout, on the base branch, with a clean
tree. Preflight checks that and prints every problem with its fix:

```text
Preflight: 10 passed, 2 failed, 1 warning
FAIL  Branch rules: main requires 1 approving review
      Fix: allow bypass for your account, or run with --no-merge
FAIL  Baseline: CI is red on main: test
      Fix: main must be green before starting
WARN  Research: deny rule 'WebFetch' in .claude/settings.json; research uses the codebase only
Nothing was changed.
```

## Project configuration

Add a `## Backlog loop` section to the project's `CLAUDE.md` (`.claude/CLAUDE.md`
and `AGENTS.md` are read too). Every key is optional when it can be detected.

The loop tests nothing locally. The repository's CI is the only gate: it must
run on pull requests, and a batch merges only when every check is green. A
repository without CI fails preflight.

```markdown
## Backlog loop

- source: github
- label: backlog
- base-branch: main
- merge-method: squash
```

| Key | Default | Meaning |
|---|---|---|
| `source` | detected | `github` (issues) or `file`. Detected when only one of the two exists. |
| `label` | `backlog` | GitHub: open issues with this label are the backlog. |
| `path` | `BACKLOG.md` | File: the backlog file. |
| `base-branch` | repository default | Branch the PRs target. |
| `merge-method` | `squash` | `squash`, `merge` or `rebase`. |
| `model-light` | `haiku` | Model for `light` batches and for research. |
| `model-standard` | `sonnet` | Model for `standard` batches. |
| `model-complex` | `opus` | Model for `complex` batches. |

A model is `haiku`, `sonnet`, `opus`, `fable`, or `inherit` (the
orchestrator's model). The tier of each batch is chosen at planning time; see
[batching.md](batching.md#model-tier). Reasoning effort cannot be set per
worker: workers use the effort of the session that runs the loop.

Limits, all optional:

| Key | Default |
|---|---|
| `max-attempts` (per item) | 3 |
| `ci-reruns` (per batch) | 1 |
| `ci-wait-minutes` (per attempt) | 45 |
| `research-passes` (per question) | 1 |
| `parallel-batches` | 4 |
| `stall-threshold` (unchanged gate checks) | 2 |
| `max-iterations` | 100 |
| `max-hours` | 12 |
| `worker-wait-minutes` | 120 |
| `max-batch-items` | 15 |

### Backlog sources

**GitHub:** open issues with the label. Results are mirrored as comments and
the labels `blocked` and `needs-review`; merged PRs close their issues with
`Closes #<id>`. An issue that already carries `blocked` is skipped.

**File:** `BACKLOG.md` with either layout:

```markdown
| ID | Title | Status | Notes |
|---|---|---|---|
| B-1 | Add greeting | ready | |

- [ ] B-2: Add farewell
```

Rows with status `done`, `cancelled`, `merged` or `closed`, checked boxes, and
everything under `## Archive` are skipped. Give checkbox items an id; without
one the id is `item-<position>`, which shifts when the list is edited. At the
end of the run one extra PR marks merged items done and annotates blocked ones
with `BLOCKED: <reason>`.

## Permissions for unattended runs

The skill's `allowed-tools` covers its scripts, `git` and `gh`, but Claude Code
applies that grant only to the turn that invoked the skill. After a background
worker reports, after a resume, and inside workers, your own settings decide.
Set this up once, before the first unattended run.

**Recommended: auto mode plus a few allow rules.** In
`.claude/settings.local.json` of the target repository:

```json
{
  "permissions": {
    "allow": [
      "Bash(/Users/you/.claude/skills/backlog-loop/scripts/*)",
      "Bash(git *)",
      "Bash(gh *)"
    ]
  },
  "env": {
    "CLAUDE_CODE_STOP_HOOK_BLOCK_CAP": "30"
  }
}
```

- Use the absolute path of your install in the first rule.
- No test, lint or build command is needed: the loop runs none of them. CI on
  each pull request is the only test gate.
- `Bash(gh *)` matters in auto mode: its classifier blocks merging a pull
  request that no human approved, unless an allow rule matches. Without the
  rule, use `--no-merge`.
- `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`: Claude Code ends a turn after 8 Stop hook
  blocks in a row. The gate stays one below whatever the cap is and leaves the
  run resumable, so the default is safe; a higher cap means fewer manual
  `/backlog-loop` restarts on a long run. `0` removes the cap.

Other modes:

| Mode | Works? |
|---|---|
| `auto` | Yes, recommended, with the rules above. |
| `dontAsk` | Yes, for a strict setup: everything not in `allow` is denied, so list the file tools too. |
| `acceptEdits`, `default` (Manual) | Only attended: commands outside the allow list prompt and the run waits for you. |
| `plan` | No: nothing can be written. |
| `bypassPermissions` | Works, but only in a container or VM. |

Preflight helps: the skill has Claude run a `git` and a `gh` probe command at
the very start, so a missing rule shows while you are still there. It also
fails on `deny` and `ask` rules that match commands the loop needs, in user,
project, local and managed settings.

What the run can never do, enforced by the guard hook while a run is active:
force-push, push to the base branch, `gh pr merge --admin`, merge a PR that is
not verified green, and delete or hand-edit the state file.

GitHub side: your account needs write access, the merge method must be enabled,
and the base branch must not require human approval (or use `--no-merge`).

## The run's files

`.planning/backlog-loop/` (ignored by git):

| File | Content |
|---|---|
| `state.json` | The run. Written only by `scripts/state.sh`. |
| `plan.md` | The batches, human readable. |
| `run.log` | Every action, decision and script result, with timestamps. Removed when the run is done. |
| `report.md` | The summary, plus one line per batch. |
| `decisions/<item>.md` | Decision record for each unclear item. |
| `lock` | Session that owns the run. |
| `archive/<run id>/` | Earlier runs. |

When a run reaches `done`, the scripts clean up: branches and worktrees of
blocked and closed batches are removed (merged ones already were), leftover
`worktree-*` branches without commits of their own are deleted, and `run.log`,
`prompts/` and the other working files are removed. `state.json`, `plan.md`,
`report.md` and `decisions/` stay as the record. A halted or stalled run keeps
everything, so it can be resumed and diagnosed.

## Resume

Run `/backlog-loop` again. It works after a crash, a usage limit, a closed
terminal, a halt or a stall. The state is reconciled with GitHub first: a
merged PR is verified and counted, a closed PR resets its batch, a lost worker
is started again. Merged batches are never redone. A resume also gives a fresh
iteration and wall-clock budget.

To look without changing anything:

```bash
~/.claude/skills/backlog-loop/scripts/state.sh status
~/.claude/skills/backlog-loop/scripts/next.sh --peek
~/.claude/skills/backlog-loop/scripts/report.sh
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `FAIL  Filesystem: another session (...) is running the loop` | A run is active, or the session that ran it died less than 15 minutes ago. If it is gone: delete `.planning/backlog-loop/lock` and run `/backlog-loop`. |
| The run stopped although work remains | The Stop hook block cap was reached, or the turn ended on an API error. Run `/backlog-loop`. Raise `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` to see it less often. |
| `Backlog loop stalled` | Nothing changed across two stop checks, usually because a command kept being denied. Read the last lines of `run.log`, fix the permission rule, `/backlog-loop --resume`. |
| Claude waits on a permission prompt | A needed command is not in `allow`. Add it; see "Permissions for unattended runs". |
| Merge is denied in auto mode | The classifier blocks merging unapproved PRs. Add `Bash(gh *)` to `allow`, or use `--no-merge`. |
| `guard: PR ... is not verified for merge` | Working as intended: `verify-batch.sh <batch> pre-merge` must print READY first. |
| Hooks do nothing | The skill is not at `~/.claude/skills/backlog-loop` or `<project>/.claude/skills/backlog-loop`. Set `BACKLOG_LOOP_HOME`. Check with `/hooks`. |
| `Backlog loop halted: base branch was red ...` | A merge broke the base branch and was reverted. Its items are blocked with the reason. `/backlog-loop --resume` continues with the remaining batches. |
| `halted: remaining batches depend on pull requests that wait for a human merge` | `--no-merge`: merge the listed PRs, then `/backlog-loop --resume`. |
| State looks wrong | Never edit `state.json`. To start over, delete `.planning/backlog-loop/` while no run is active. |

## Tests

```bash
tests/run.sh            # everything, about three minutes
tests/run.sh --quick    # unit suites only
tests/dry-run.sh github # the full loop on a fixture repository, no network
tests/dry-run.sh file
```

The suite runs in CI on every pull request that touches the skill
(`.github/workflows/backlog-loop.yml`). The dry run sets
`BACKLOG_LOOP_DRY_RUN=1`, which puts stub `gh` and `git` (push, fetch, pull)
from `tests/stubs/` first on `PATH`. It drives a five-item backlog through
planning, batches, a CI failure with a fix, an unclear item with a decision
record, a hard blocker, and the final report.
