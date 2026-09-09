# agent-conventions

A collection of specialized agents, skills, and development guidelines for AI coding assistants.

This repository contains:

- **`skills/` and `agents/`** — The repository root is itself a Claude Code plugin (`conventions`), so these sit at the top level rather than nested under a plugin directory. That is also where the wider agent ecosystem scans for `SKILL.md` files. See [docs/CONSUMER.md](docs/CONSUMER.md) for how a consumer repo loads them via the `aanyberg` marketplace, with no copying into `~/.claude`.
  - **Agents** — Specialized multi-step task runners for common development workflows (feature planning, refactoring, documentation updates, etc.)
  - **Skills** — Focused knowledge modules covering code standards, best practices, and workflows across Python, TypeScript, and general development
- **Instructions** — A single `AGENTS.md` file with project-level guidance that works across all supported tools

These components enhance AI coding assistants by providing domain knowledge, coding conventions, and structured workflows.

## Installation

### Everything, one command

```bash
# this machine, every project — skills and global instructions
npx @aanyberg/agent-conventions@latest -g

# preview without writing anything
npx @aanyberg/agent-conventions@latest -g --dry-run
```

Run bare, it asks for scope and agents, prints every path it will touch, and defaults to **no**. `-y` skips the prompt but still prints the plan. Nothing global is written without the paths appearing on screen first.

It writes a receipt, so `uninstall` removes exactly what was installed and nothing else:

```bash
npx @aanyberg/agent-conventions@latest uninstall -g
```

**Existing files are never clobbered.** Global instructions are appended inside `<!-- BEGIN/END -->` markers, so your own content survives an install and is restored byte-for-byte by an uninstall. If an instruction path is already a **symlink** — which it will be if you followed the older setup below — the installer refuses it rather than writing through the link into your clone. `--replace-symlinks` converts it, leaving the file it pointed at untouched.

Your project's own `AGENTS.md` is never written. That file is yours.

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

### Native plugin install

Each ecosystem has its own manifest, all pointing at the same top-level [`skills/`](skills):

```bash
# Codex, Cursor, ChatGPT, Kiro, VS Code — via the Agent Plugins standard
# (plugin.json at the repo root)

claude plugin marketplace add aanyberg/agent-conventions   # Claude Code
copilot plugin marketplace add aanyberg/agent-conventions  # GitHub Copilot CLI
gemini extensions install aanyberg/agent-conventions       # Gemini CLI
```

Codex discovers the repo through `.codex-plugin/plugin.json`; Copilot CLI reads the same `.claude-plugin/marketplace.json` Claude Code does.

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

## Releasing

Six manifests declare a version. Set them together, never by hand:

```bash
node scripts/bump-version.mjs 1.1.0
git commit -am "chore: release 1.1.0"
git tag v1.1.0 && git push --tags
```

The tag triggers [`release.yml`](.github/workflows/release.yml), which **re-runs both suites rather than trusting merge-time checks** — an `--admin` merge bypasses required status checks as well as the approval rule, so a publish cannot assume the PR was green. It also verifies the tag matches the manifests, packs the tarball and asserts it contains the skills, agents, `AGENTS.md` and the binary, then installs that exact tarball and runs a full install/uninstall round trip. Only then does it publish.

Publishing uses [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) over OIDC: no `NPM_TOKEN` is stored anywhere, the credential is short-lived and scoped to this one workflow, and npm attaches a provenance attestation automatically.

### One-time setup

Neither step can be scripted from here — both need an authenticated session:

1. **npm** — publish `1.0.0` manually once (`npm publish --access public`), since a trusted publisher can only be added to a package that exists. Then under the package's *Settings → Trusted publishers*, add: repository `aanyberg/agent-conventions`, workflow `release.yml`, environment `release`.
2. **GitHub** — create an environment named `release` (*Settings → Environments*). Adding yourself as a required reviewer there puts a human approval in front of every publish, which is worth having for a public registry.

Until step 1 is done, `npx @aanyberg/agent-conventions` will not resolve.

## Validation

Every change is gated by a validation suite. It parses the same files Claude Code
parses at load time — so a failure means the plugin would load wrong — checks each
skill against the [Agent Skills specification](https://agentskills.io/specification)
so the single copy stays installable in every other agent, and runs the shipped shell
scripts end to end in throwaway git repos.

```bash
uv run --frozen pytest tests   # structure, skills, agents, manifests
node --test tests-js/           # the installer and the version bump
```

It takes about two seconds and needs no API access or GitHub auth — `gh` is stubbed.
`.github/workflows/validate.yml` gates every pull request on Linux, and repeats the
suite on macOS after merge to `main` as a canary.

What it checks:

| Area | Checks |
| --- | --- |
| Release | the version bump sets all six manifests together, refuses a non-semver input without writing, is idempotent, and leaves every other field and the file formatting untouched. A separate test asserts the six currently agree, so drift fails a PR rather than a release |
| Installer | the CLI runs end to end against a throwaway `HOME`: both scopes, symlink and copy modes, idempotent reinstall, and an uninstall that restores a pre-existing file byte-for-byte and leaves a foreign skill in the same directory alone. The symlink guard has its own tests — the one failure mode here that destroys data rather than annoying someone |
| Install manifests | the four ecosystem manifests parse, declare the same version, and point at the same `skills/`; `plugin.json` matches the Agent Plugins name grammar and carries no key outside its schema, which sets `additionalProperties: false` so an extra key invalidates the file rather than being ignored |
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
