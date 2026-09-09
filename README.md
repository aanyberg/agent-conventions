# agent-conventions

A collection of specialized agents, skills, and development guidelines for AI coding assistants.

This repository contains:

- **`skills/` and `agents/`** — The repository root is itself a Claude Code plugin (`conventions`), so these sit at the top level rather than nested under a plugin directory. That is also where the wider agent ecosystem scans for `SKILL.md` files. See [docs/CONSUMER.md](docs/CONSUMER.md) for how a consumer repo loads them via the `aanyberg` marketplace, with no copying into `~/.claude`.
  - **Agents** — Specialized multi-step task runners for common development workflows (feature planning, refactoring, documentation updates, etc.)
  - **Skills** — Focused knowledge modules covering code standards, best practices, and workflows across Python, TypeScript, and general development
- **Instructions** — A single `AGENTS.md` file with project-level guidance that works across all supported tools

These components enhance AI coding assistants by providing domain knowledge, coding conventions, and structured workflows.

## Installation

### Skills — any agent

The skills follow the [Agent Skills specification](https://agentskills.io/specification), so one copy works in every agent that reads it. Install them with the ecosystem's CLI:

```bash
# this project only
npx skills add aanyberg/agent-conventions

# every project on this machine
npx skills add aanyberg/agent-conventions -g
```

It prompts for scope and agents. To skip the prompts:

```bash
npx skills add aanyberg/agent-conventions -a codex -a github-copilot -a opencode -y
```

Agent flags: `claude-code`, `codex`, `github-copilot`, `opencode`, `cursor`, `gemini-cli`, and [70+ others](https://github.com/vercel-labs/skills#supported-agents).

**Only two directories are ever written**, at either scope:

| Path | Read by |
| --- | --- |
| `.agents/skills/` (or `~/.agents/skills/`) | Codex, GitHub Copilot, OpenCode, Cursor, Gemini CLI, Cline, Zed, Amp and others — this is the cross-vendor convention |
| `.claude/skills/` (or `~/.claude/skills/`) | Claude Code, the one holdout — symlinked to the above, not a second copy |

Because Claude Code is a symlink into the same files, there is no duplicate to drift. At project scope, commit `.agents/skills/` and gitignore `.claude/skills/`.

### Skills & agents — Claude Code plugin

The plugin route additionally installs the [`agents/`](agents), which are Claude-specific, and updates through `claude plugin update` rather than re-running an installer:

```bash
claude plugin marketplace add aanyberg/agent-conventions
claude plugin install conventions@aanyberg
```

A consumer repo can commit the marketplace in `.claude/settings.json` so contributors need no per-person install at all — see [docs/CONSUMER.md](docs/CONSUMER.md).

### Global Instructions

`AGENTS.md` is the single source of truth. The filename is the portable part — 30+ tools read a project's `AGENTS.md` directly — but *global* instructions are a different matter: each tool looks in its own config directory, and two of them expect a different filename there. So every tool below needs a link, and what portability buys you is one file to edit rather than three to keep in sync.

> **This step is manual for now.** The symlinks below are the current method; they are being replaced by an installer that appends a marked block instead, so an existing file is never clobbered. Until then, note that a symlink means edits to the target write back into this repository.

Symlink `AGENTS.md` to each tool's expected config path:

**Claude Code**
```bash
ln -s /path/to/agent-conventions/AGENTS.md ~/.claude/CLAUDE.md
```

**GitHub Copilot**
```bash
mkdir -p ~/.copilot
ln -s /path/to/agent-conventions/AGENTS.md ~/.copilot/copilot-instructions.md
```

**OpenAI Codex CLI**
```bash
mkdir -p ~/.codex
ln -s /path/to/agent-conventions/AGENTS.md ~/.codex/AGENTS.md
```

Replace `/path/to/agent-conventions` with the absolute path to your local clone, e.g. `/home/<username>/projects/agent-conventions`.

## Validation

Every change is gated by a validation suite. It parses the same files Claude Code
parses at load time — so a failure means the plugin would load wrong — checks each
skill against the [Agent Skills specification](https://agentskills.io/specification)
so the single copy stays installable in every other agent, and runs the shipped shell
scripts end to end in throwaway git repos.

```bash
uv run --frozen pytest tests
```

It takes about two seconds and needs no API access or GitHub auth — `gh` is stubbed.
`.github/workflows/validate.yml` gates every pull request on Linux, and repeats the
suite on macOS after merge to `main` as a canary.

What it checks:

| Area | Checks |
| --- | --- |
| Manifests | `marketplace.json` and `plugin.json` parse, agree on descriptions, use semver, and every declared `source` resolves to a real plugin. Plugin identity comes from the manifest pair, not the directory name — the root plugin is `conventions` while its directory is the repo itself |
| Skills | frontmatter has `name` and `description`, `name` matches the directory, names are unique, descriptions fit the loader budget, and every key is one the Agent Skills spec permits — `version` is not one of them, it belongs inside `metadata` |
| Agents | `name` matches the filename and is kebab-case; `tools`, `model`, `effort`, `maxTurns`, and `permissionMode` are present and valid; `plan`-mode agents declare no write tools |
| References | relative markdown links resolve, shipped scripts are executable with a shebang, and every skill or agent named in prose exists |
| Policy | `policy.example.yml` parses, has exactly one copy, keeps the `backend: auto` line `generate-policy.sh` substitutes, and contains every key the skills read |
| Scripts | `detect-backend.sh` and `generate-policy.sh` run against real git repos with a stubbed `gh`: explicit and auto backend resolution, the incomplete-migration guard, idempotent generation, a missing template, and a round trip proving what one writes the other reads back |
| Shell lint | `shellcheck --severity=warning` over every shipped script, using the binary vendored by `shellcheck-py` so no separate install is needed |
| Cross-agent portability | the repo ships one copy of each skill, so no skill or agent body may depend on a single vendor: no interpolated `${CLAUDE_*}` variable, no vendor component directory (`.claude/skills/`, `.cursor/rules/`, …), no vendor instruction file (`CLAUDE.md`, `copilot-instructions.md`), and no tool named from one agent's vocabulary. Naming a vendor directory as somewhere *not* to write stays legal — `task-workflow` does exactly that with `~/.claude` and `~/.copilot`. Each rule is pinned to a sample it must catch and a sample it must ignore, so a regex that rots fails loudly instead of passing on everything |
| Script portability | shipped scripts use no GNU-only regex escape (`\s`, `\d`, `\w`, …) or flag (`grep -P`, bare `sed -i`, `readlink -f`, `date -d`). shellcheck does not parse regex arguments, and a `\s` in `sed -E` silently produced a wrong backend on macOS while passing every Linux run |

Adding a skill or agent needs no test changes — the suite discovers files by glob and
parametrises per file, so each one fails independently with its own path in the failure.
