# agent-conventions

Portable [Agent Skills](https://agentskills.io/specification) for coding
standards, language guidelines, testing, reviews, documentation, backlog
management, and development workflows.

Like [Google's skills repository](https://github.com/google/skills), this repo
keeps its skills in a single top-level [`skills/`](skills) directory. Install
them with `npx skills`, or reference the skill files directly. We do not ship
provider-native agents, plugins, or a separate installer.

## Repository-native by default

Skills follow the consuming repository's existing contributor instructions,
tooling, tracker, documentation layout, and Git history. They do not create
policy files, planning hierarchies, backlogs, or ADR systems merely because
they are available.

For backlog operations, `backlog-management` follows an explicit choice or
established repository evidence. If neither identifies a single backend, it
asks whether to use GitHub Issues, `BACKLOG.md`, or no persistent backlog.
Structured task files and architecture records are similarly used only when
already established or explicitly requested.

## Installation

Install with the [skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add aanyberg/agent-conventions
```

Select the skills and assistants you want when prompted. Preview the available
skills, or install globally, with:

```bash
npx skills add aanyberg/agent-conventions --list
npx skills add aanyberg/agent-conventions -g
```

For project installs, the CLI uses generic `.agents/skills/` for assistants
that read it and `.claude/skills/` when Claude Code is selected. It manages the
copies or links; this repository does not commit duplicate skill trees in
either location. Global destinations depend on the selected assistant. Remove
installed skills with `npx skills remove` (or `npx skills remove -g` for global
installs).

## Reference without installing

You can reference this repository manually: point your assistant at a
`SKILL.md` under [`skills/`](skills) and any supporting files in that skill's
directory. You can also reference [`AGENTS.md`](AGENTS.md) from your existing
project instructions if you want its general guidance.
References do not automatically install skills or merge instructions; the
assistant must be able to read the referenced files. See the
[consumer guide](docs/CONSUMER.md) for an example and migration notes.
