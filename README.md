# agent-conventions

A collection of specialized agents, skills, and development guidelines for AI coding assistants.

This repository contains:

- **`skills/` and `agents/`** — The repository root is itself a Claude Code plugin (`conventions`), so these sit at the top level rather than nested under a plugin directory. That is also where the wider agent ecosystem scans for `SKILL.md` files. See [docs/CONSUMER.md](docs/CONSUMER.md) for how a consumer repo loads them via the `aanyberg` marketplace, with no copying into `~/.claude`.
  - **Agents** — Specialized multi-step task runners for common development workflows (feature planning, refactoring, documentation updates, etc.)
  - **Skills** — Focused knowledge modules covering code standards, best practices, and workflows across Python, TypeScript, and general development
- **Instructions** — A single `AGENTS.md` file with project-level guidance that works across all supported tools

These components enhance AI coding assistants by providing domain knowledge, coding conventions, and structured workflows.

## Installation

### Agents & Skills (Claude Code)

Claude Code loads agents and skills via the plugin marketplace at `.claude-plugin/marketplace.json` — see [docs/CONSUMER.md](docs/CONSUMER.md) for the exact `.claude/settings.json` snippet and CLI commands. Agents and skills live at [`agents/`](agents) and [`skills/`](skills).

### Global Instructions

`AGENTS.md` is the single source of truth for global instructions. Symlink it to each tool's expected config path:

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
parses at load time — so a failure means the plugin would load wrong — and runs the
shipped shell scripts end to end in throwaway git repos.

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
| Skills | frontmatter has `name` and `description`, `name` matches the directory, names are unique, descriptions fit the loader budget, and no unrecognised (silently ignored) keys |
| Agents | `name` matches the filename and is kebab-case; `tools`, `model`, `effort`, `maxTurns`, and `permissionMode` are present and valid; `plan`-mode agents declare no write tools |
| References | relative markdown links resolve, shipped scripts are executable with a shebang, and every skill or agent named in prose exists |
| Policy | `policy.example.yml` parses, has exactly one copy, keeps the `backend: auto` line `generate-policy.sh` substitutes, and contains every key the skills read |
| Scripts | `detect-backend.sh` and `generate-policy.sh` run against real git repos with a stubbed `gh`: explicit and auto backend resolution, the incomplete-migration guard, idempotent generation, a missing template, and a round trip proving what one writes the other reads back |
| Shell lint | `shellcheck --severity=warning` over every shipped script, using the binary vendored by `shellcheck-py` so no separate install is needed |
| Portability | shipped scripts use no GNU-only regex escape (`\s`, `\d`, `\w`, …) or flag (`grep -P`, bare `sed -i`, `readlink -f`, `date -d`). shellcheck does not parse regex arguments, and a `\s` in `sed -E` silently produced a wrong backend on macOS while passing every Linux run |

Adding a skill or agent needs no test changes — the suite discovers files by glob and
parametrises per file, so each one fails independently with its own path in the failure.
