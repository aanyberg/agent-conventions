# Setup, configuration and troubleshooting

## Requirements

- `git`, `jq` and a recent `gh` that has `gh pr revert` and
  `gh pr update-branch` (developed against 2.102), on macOS or Linux.
- A GitHub repository you can push branches to and merge pull requests in.
- CI that runs on pull requests. The loop tests nothing locally: a batch
  merges only when its checks are green. For a repository where some pull
  requests run no checks, see `ci` below.
- A green base branch. The loop refuses to start on a red one.

The hooks look for the skill at `~/.claude/skills/backlog-loop/` or
`<project>/.claude/skills/backlog-loop/`, because Claude Code does not expand
`${CLAUDE_SKILL_DIR}` in hook commands. For any other location, set
`BACKLOG_LOOP_HOME` to the skill directory in the `env` block of your
settings.

## Commands

| Command | Effect |
|---|---|
| `/backlog-loop plan` | Groups the open items into named batches by theme and dependency, shows the plan and stops. Builds nothing. Use it first, after the backlog changed, and to queue set-aside items again. |
| `/backlog-loop execute` | Runs every remaining batch of the plan, wave by wave. Continues an unfinished run. |
| `/backlog-loop execute D` | Runs batch D only. Several names run several batches, in waves among themselves. |
| `/backlog-loop execute --no-merge` | With or without names: each batch stops at a green pull request. Merge it, then run `execute` again for the batches that need it. |
| `/backlog-loop status` | Shows the plan and the last report. Changes nothing. `/backlog-loop` alone does the same. |

`execute` never plans: without a plan, or with nothing left of it, it says so
and stops. A batch that needs an unmerged batch cannot be started alone: name
both, as in `/backlog-loop execute B D`.

## Configuration

Optional. Add a section to the project's `CLAUDE.md` (`.claude/CLAUDE.md` and
`AGENTS.md` are read too):

```markdown
## Backlog loop

- source: file
- path: BACKLOG.md
- merge-method: squash
```

| Key | Default | Meaning |
|---|---|---|
| `source` | from the plan | `github` (issues) or `file`. Without it the planner follows the repository's evidence. |
| `label` | `backlog` | `github`: open issues with this label are the backlog. |
| `path` | `BACKLOG.md` | `file`: the backlog file. |
| `base-branch` | repository default | The branch the pull requests target. |
| `merge-method` | `squash` | `squash`, `merge` or `rebase`. |
| `ci` | `required` | `required`: a pull request without any check halts the run. `optional`: it merges after a grace period of five minutes. |
| `model-light`, `model-standard`, `model-complex` | `haiku`, `sonnet`, `opus` | The model for workers of each tier. |
| `model-research` | `sonnet` | The model for research on unclear items. |
| `parallel-batches` | 3 | Batches per wave. |
| `parallel-workers` | 6 | Workers at once, across the wave. |
| `max-attempts` | 2 | Worker attempts per item before it is set aside. |
| `max-fixes` | 2 | Fix attempts on a red pull request before the batch is set aside. |
| `ci-wait-minutes` | 45 | How long one CI run may take before it counts as failed. |
| `worker-minutes` | 90 | How long a worker may stay silent before it counts as failed. |
| `verify-minutes` | 20 | How long to wait for CI on the base branch after a merge. |
| `max-hours` | 12 | Wall-clock limit of one run. |

The configuration is read again at every start.

### Backlog sources

**GitHub issues.** Items are issue numbers. The pull request closes them
with `Closes #<n>`. A set-aside item gets a comment that says why and what it
needs.

**A backlog file.** Any layout the repository uses. The planner reads it;
the script never parses it. Before a batch's pull request opens, a worker
marks the batch's items in the file, in the file's own conventions, as one
commit on the batch branch. Status and code merge together, and a batch that
does not merge leaves the file untouched.

## Permissions for unattended runs

The skill's `allowed-tools` covers its scripts, `git` and `gh`, but Claude
Code applies that grant only to the turn that invoked the skill. After a
background worker reports, and inside workers, your own settings decide. Set
this up once in `.claude/settings.local.json` of the target repository:

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

- Use the path of your install in the first rule. The script prints its
  commands with the path it was started under, so a symlinked install matches
  the rule you write for the symlink.
- The script merges pull requests itself, after it has verified them. The
  merge happens inside the script call that the first rule allows. Use
  `--no-merge` to keep the merge button for yourself.
- `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`: Claude Code ends a turn after 8 Stop hook
  blocks in a row. The hook stays one below the cap and leaves the run
  resumable; a higher cap means fewer manual restarts on a long run.

While a run is active a guard hook denies, for the orchestrator: every
`gh pr merge`, force-pushes, pushes to the base branch, and edits or removal
of the run's state. The worker prompts carry the same rules.

## The run's files

`.planning/backlog-loop/`, ignored through `.git/info/exclude`:

| File | Content |
|---|---|
| `state.json` | The plan (batches and items) and the current run. Written only by `loop.sh`. |
| `plan.json` | The planner's last input to `plan-apply`. |
| `decisions/<item>.md` | The decision record of each researched item. |
| `report.md` | The report of the last finished run. |
| `run.log` | Every action and transition, with timestamps. |
| `lock` | The session that owns the active run. |

Branches: `backlog-loop/<batch>/batch-t<n>` for a batch and
`backlog-loop/<batch>/item-<id>-t<n>` for an item. After a merge the loop
deletes the batch branch (local and remote) and the item branches. Branches
of set-aside batches stay, with their open pull request.

## Resume

Run `/backlog-loop execute` again. It works after a crash, a usage limit, a closed
terminal or a halt. Batches in progress continue where GitHub says they are:
an open pull request goes on waiting for CI, a merged one is verified, a
finished worker's commit is kept, and a lost worker's item is handed out
again. Merged batches are never redone.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `another session (...) is running the loop here` | A run is active, or its session died less than 15 minutes ago. If it is gone, delete `.planning/backlog-loop/lock` and run `/backlog-loop execute`. |
| `CI is red on main` | The base branch must be green before the loop adds to it. |
| `batch D needs B, which is not merged` | Run both: `/backlog-loop execute B D`. If B was set aside, D waits until B's items are planned again and merged. |
| `halted - no CI checks ran on PR #n` | The pull request triggered no workflow. Add CI for pull requests, or set `ci: optional`. |
| `halted - URGENT: main is red after PR #n merged` | CI on the base branch failed after the merge. Merge the revert pull request the loop opened, then run `/backlog-loop execute`. |
| `halted - stalled` | The agent tried to stop three times without advancing the loop, usually because a command keeps being denied. Read the end of `run.log`, fix the permission rule, run `/backlog-loop execute`. |
| The run stopped although work remains | The Stop hook block cap was reached, or the turn ended on an error. Run `/backlog-loop execute`. |
| `there is no batch left to execute` | Everything planned is merged or set aside. Run `/backlog-loop plan` to pick up new backlog items. |
| A batch was set aside with its pull request open | CI stayed red after `max-fixes` attempts, or a conflict with the base branch could not be resolved. Fix and merge the pull request yourself, or close it and run `/backlog-loop plan` to queue its items again. |
| Hooks do nothing | The skill is in neither default location. Set `BACKLOG_LOOP_HOME`. Check with `/hooks`. |
| State looks wrong | Never edit `state.json`. To start over, delete `.planning/backlog-loop/` while no run is active, then run `/backlog-loop plan`. |

## Tests

```bash
tests/run.sh
```

Plain bash. The scenario suite runs the whole loop against a real git
repository with a bare origin and a stub `gh` (`tests/stubs/gh`) that merges,
updates and reverts for real and reads CI results from marker files in the
commit. The suite runs in CI on every pull request that touches the skill
(`.github/workflows/backlog-loop.yml`), together with shellcheck.
