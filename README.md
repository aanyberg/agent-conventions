# agent-conventions

A collection of specialized agents, skills, and development guidelines for AI coding assistants.

This repository contains:

- **`skills/` and `agent-sources/`** — Skills follow the Agent Skills
  specification. Agent sources remain outside provider auto-discovery; the
  installer renders them into each provider's native format and directory.
  - **Agents** — Six specialized roles for planning, implementation, review,
    documentation synchronization, repository research, and verification
  - **Skills** — Focused knowledge modules covering code standards, best practices, and workflows across Python, TypeScript, and general development
- **Instructions** — A single `AGENTS.md` file with project-level guidance that works across all supported tools

These components enhance AI coding assistants by providing domain knowledge, coding conventions, and structured workflows.

## Installation

### Everything, one command

```bash
# this machine, every project — skills, agents, and global instructions
npx github:aanyberg/agent-conventions -g

# preview without writing anything
npx github:aanyberg/agent-conventions -g --dry-run
```

Once the package is on npm the shorter `npx @anyberg/agent-conventions@latest` works identically.

> **Note the spelling.** The npm scope is `@anyberg` (one `a`); the GitHub org and the Claude marketplace are `aanyberg` (two). They are separate namespaces and the handles differ — `github:aanyberg/…` and `conventions@aanyberg` are correct as written. The `github:` form needs nothing published and accepts any ref — `github:aanyberg/agent-conventions#1.1.0` pins a release.

Run bare, it asks for scope and agents, prints every path it will touch, and defaults to **no**. `-y` skips the prompt but still prints the plan. Nothing global is written without the paths appearing on screen first.

It writes a receipt, so `uninstall` removes exactly what was installed and nothing else:

```bash
npx github:aanyberg/agent-conventions uninstall -g
```

**Existing files are never clobbered.** Global instructions are appended inside `<!-- BEGIN/END -->` markers, so your own content survives an install and is restored byte-for-byte by an uninstall. If an instruction path, skills root, or generated-agent directory is itself a **symlink**, the installer refuses it rather than writing through the link. Other selected providers still install, and the receipt records only successful writes. `--replace-symlinks` converts the link itself to a real path, leaving its target untouched.

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
| `.claude/skills/` (or `~/.claude/skills/`) | Claude Code, the one holdout — contains per-skill links into the above, not a second copy |

Because each Claude Code entry uses a full-path symlink into the same files,
there is no duplicate to drift. At project scope, commit `.agents/skills/` and
gitignore `.claude/skills/`; regenerate the links after moving the project.

### Agents — every target provider

The installer renders the canonical [`agent-sources/`](agent-sources) corpus into each
selected provider's native format. Generated agents are real files rather than
symlinks because frontmatter, tool names, permissions, and even the file format
differ by provider.

| Provider | Project path | Global path |
| --- | --- | --- |
| Claude Code | `.claude/agents/*.md` | `~/.claude/agents/*.md` |
| Codex | `.codex/agents/*.toml` | `~/.codex/agents/*.toml` |
| GitHub Copilot | `.github/agents/*.agent.md` | `~/.copilot/agents/*.agent.md` |
| OpenCode | `.opencode/agents/*.md` | `~/.config/opencode/agents/*.md` |
| Cursor | `.cursor/agents/*.md` | `~/.cursor/agents/*.md` |
| Gemini CLI | `.gemini/agents/*.md` | `~/.gemini/agents/*.md` |

Every emitted name starts with `conventions-`. The receipt stores a digest for
each generated file: updates refuse foreign collisions, and uninstall preserves
any managed agent a user modified after installation.

### Native plugin install

Each ecosystem has its own manifest pointing at the same top-level
[`skills/`](skills). Native plugin installation is intentionally skills-only;
use the package installer above when provider-native agents are also required:

```bash
# Codex, Cursor, ChatGPT, Kiro, VS Code — via the Agent Plugins standard
# (plugin.json at the repo root)

claude plugin marketplace add aanyberg/agent-conventions   # Claude Code
copilot plugin marketplace add aanyberg/agent-conventions  # GitHub Copilot CLI
gemini extensions install aanyberg/agent-conventions       # Gemini CLI
```

Codex discovers the repo through `.codex-plugin/plugin.json`; Copilot CLI reads the same `.claude-plugin/marketplace.json` Claude Code does.

### Skills — Claude Code plugin

The plugin route installs skills and updates through `claude plugin update`.
Canonical agent sources are not exposed directly because their metadata is not
valid provider configuration; use the package installer for agents:

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

## Removing

Whatever put this on your machine is what takes it off — the routes do not clean up after each other.

| Installed with | Remove with |
| --- | --- |
| `npx github:aanyberg/agent-conventions` | `npx github:aanyberg/agent-conventions uninstall -g` (or `-p`) |
| `npx skills add …` | `npx skills remove -g` |
| `claude plugin install` | `claude plugin uninstall conventions@aanyberg` |
| `claude plugin marketplace add` | `claude plugin marketplace remove aanyberg` |
| `gemini extensions install` | see `gemini extensions --help` |

### What the installer's uninstall removes

It works from the receipt written at install time, so it removes **exactly** what was installed and nothing adjacent:

- every skill directory it created, and the links it made into `.claude/skills/`
- every generated agent that is still byte-identical to the installed copy;
  modified agents are retained and reported
- its block from each instruction file, leaving your own content byte-for-byte as it was — and deleting the file outright only if the installer created it and nothing else is in it
- the receipt itself

A skill someone else put in the same directory is left alone. That is the point of the receipt: removal is never inferred from what an install *would* have produced.

### `npm uninstall` does not do this

`npm uninstall` removes the package and **nothing the installer wrote**. It cannot — npm removed uninstall lifecycle scripts in v7, on the grounds that a removal has too many possible causes to give a script useful context.

So if you installed the package globally, remove the content first and the package second:

```bash
npx github:aanyberg/agent-conventions uninstall -g
npm uninstall -g @anyberg/agent-conventions
```

The other order strands the files with the tool gone. Recoverable — the receipt is still on disk and `npx` re-fetches — but avoidable.

### By hand

If the receipt is gone, or you would rather see exactly what is there, these are all the paths the installer ever writes. Substitute the project root for `~` if you installed with `-p`:

```bash
~/.agents/skills/          # the 17 skills — the real files
~/.claude/skills/          # one link per skill into the above
~/.claude/agents/          # generated Claude agents
~/.codex/agents/           # generated Codex TOML agents
~/.copilot/agents/         # generated Copilot agents
~/.config/opencode/agents/ # generated OpenCode agents
~/.cursor/agents/          # generated Cursor agents
~/.gemini/agents/          # generated Gemini agents
~/.agent-conventions.json  # the receipt
```

Instruction files are edited, not created wholesale, so delete only the block between the markers and leave the rest:

```bash
~/.claude/CLAUDE.md
~/.copilot/copilot-instructions.md
~/.codex/AGENTS.md
~/.gemini/GEMINI.md
```

Each block is delimited by `<!-- BEGIN aanyberg/agent-conventions -->` and `<!-- END aanyberg/agent-conventions -->`. Anything outside those markers was yours.

## Releasing

Six manifests declare a version. Set them together, never by hand:

```bash
node scripts/bump-version.mjs 1.1.0
git commit -am "chore: release 1.1.0"
git tag 1.1.0 && git push origin 1.1.0
```

The bare semantic-version tag triggers [`release.yml`](.github/workflows/release.yml), which **re-runs the full suite rather than trusting merge-time checks** — an `--admin` merge bypasses required status checks as well as the approval rule, so a staged release cannot assume the PR was green. It also verifies the complete tag matches the manifests, packs the tarball and asserts it contains the skills, agents, `AGENTS.md` and the binary, then installs that exact tarball and runs a full install/uninstall round trip. Only then does it stage the package for approval.

Approve the staged package once its checks complete:

```bash
npm stage list @anyberg/agent-conventions
npm stage approve <stage-id>
```

Publishing uses [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) over OIDC: no `NPM_TOKEN` is stored anywhere, the credential is short-lived and scoped to this one workflow, and npm attaches a provenance attestation automatically.

### One-time setup

Neither step can be scripted from here — both need an authenticated session:

1. **npm** — publish `1.0.0` manually once (`npm publish --access public`), since a trusted publisher can only be added to a package that exists. Then under the package's *Settings → Trusted publishers*, add: repository `aanyberg/agent-conventions`, workflow `release.yml`, environment `release`.
2. **GitHub** — create an environment named `release` (*Settings → Environments*). Adding yourself as a required reviewer there puts a human approval in front of every publish, which is worth having for a public registry.

Until step 1 is done, `npx @anyberg/agent-conventions` will not resolve — use the `github:` form above, which needs nothing published. Publishing buys a shorter command, a tarball fetch instead of a clone, and a provenance attestation; it does not add capability.

There is deliberately **no `postinstall` hook**. `npm install` does nothing on its own; the installer is run explicitly.

That is not only a matter of taste. `npm uninstall` removes the package and **nothing the installer wrote** — not the skills, not the instruction blocks, not the receipt — and it cannot, because npm removed uninstall lifecycle scripts in v7 ("there's no clear way to currently give the script enough context to be useful"). An auto-installing `postinstall` would therefore be a one-way door: files written into `$HOME` with no supported mechanism to remove them. The explicit installer plus a receipt is the only arrangement here that fully reverses itself.

See [Removing](#removing) for how to take any of this back off.

## Validation

Every change is gated by a validation suite. It parses the same files Claude Code
parses at load time — so a failure means the plugin would load wrong — checks each
skill against the [Agent Skills specification](https://agentskills.io/specification)
so the single copy stays installable in every other agent, and runs the shipped shell
scripts end to end in throwaway git repos.

```bash
npm test
```

It needs no API access or GitHub auth — `gh` is stubbed.
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
| Agents | canonical names are package-prefixed; abstract capabilities, access, model tier, effort, and turn limits are valid; read-only roles cannot request writes; every provider renderer preserves identity and behavior |
| References | relative markdown links resolve, shipped scripts are executable with a shebang, and every skill or agent named in prose exists |
| Policy | `policy.example.yml` parses, has exactly one copy, keeps the `backend: auto` line `generate-policy.sh` substitutes, and contains every key the skills read |
| Scripts | `detect-backend.sh` and `generate-policy.sh` run against real git repos with a stubbed `gh`: explicit and auto backend resolution, the incomplete-migration guard, idempotent generation, a missing template, and a round trip proving what one writes the other reads back |
| Shell lint | ShellCheck 0.11.0 with `--severity=warning` over every shipped script; `npm test` downloads the official platform binary once and verifies its SHA-256 digest |
| Cross-agent portability | the repo ships one copy of each skill, so no skill or agent body may depend on a single vendor: no interpolated `${CLAUDE_*}` variable, no vendor component directory (`.claude/skills/`, `.cursor/rules/`, …), no vendor instruction file (`CLAUDE.md`, `copilot-instructions.md`), and no tool named from one agent's vocabulary. Naming a vendor directory as somewhere *not* to write stays legal — `task-workflow` does exactly that with `~/.claude` and `~/.copilot`. Each rule is pinned to a sample it must catch and a sample it must ignore, so a regex that rots fails loudly instead of passing on everything |
| Script portability | shipped scripts use no GNU-only regex escape (`\s`, `\d`, `\w`, …) or flag (`grep -P`, bare `sed -i`, `readlink -f`, `date -d`). shellcheck does not parse regex arguments, and a `\s` in `sed -E` silently produced a wrong backend on macOS while passing every Linux run |

Adding a skill or agent needs no test changes — the suite discovers files dynamically
and creates a subtest per file, so each one fails independently with its own path.
