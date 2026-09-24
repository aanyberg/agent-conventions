# Consuming this repository

The supported installation route is [`npx skills`](https://github.com/vercel-labs/skills).
Run the command from the project where you want the skills, or use `-g` for a
machine-wide installation:

```bash
npx skills add aanyberg/agent-conventions
```

Select your assistants when prompted. The CLI manages the installed copies
and removes them with `npx skills remove`; this repository does not install
agents, plugins, or global instructions.

## Skill locations

The source of truth is [`skills/`](../skills), just as in Google's skills repo.
For project installs, `npx skills` places skills in these locations according
to the assistants you select:

| Assistant | Project location |
| --- | --- |
| Assistants using the shared convention | `.agents/skills/<name>/SKILL.md` |
| Claude Code | `.claude/skills/<name>/SKILL.md` |

The CLI manages the links or copies. Do not maintain a second skill corpus in
either directory in this repository. Global destinations depend on the
selected assistant; use `npx skills add aanyberg/agent-conventions -g` to let
the CLI place them. This repository does not include the plugin marketplaces
in Google's `.agents/plugins/` or `.claude-plugin/`: those provide additional
installation routes, contrary to this repo's skills-only distribution.

## Reference without installing

Instead of installing, tell your assistant which skill to read from this
repository. For example, in an existing project instruction file:

```markdown
For code reviews, read the `code-review` skill at
https://github.com/aanyberg/agent-conventions/blob/main/skills/code-review/SKILL.md
and follow its guidance when reviewing changes.
```

Use a pinned Git ref in the URL if you need stable guidance. If a skill links
to supporting files, make those files accessible too. The assistant must be
able to access the referenced repository; a link by itself does not load a
skill into an assistant's skill registry. You can likewise reference the
repository's [`AGENTS.md`](../AGENTS.md) if you want its general instructions,
without replacing your own project's instructions.

If you previously installed this repository through its old package
installer or a native plugin, remove that installation separately before
using `npx skills`. The new CLI cannot remove files it did not install.

## Repository-native behavior

The skills follow the consuming repository's existing conventions and
workflows. They do not create a policy, backlog, task hierarchy, architecture
record, branch, or changelog solely because they are available.

For a backlog operation, `backlog-management` follows an explicit selection,
then repository instructions, then established `BACKLOG.md` or GitHub Issues
structure. If those signals do not identify one backend, it asks whether to
use GitHub Issues, `BACKLOG.md`, or no persistent backlog. A GitHub remote
alone does not select GitHub Issues. Structured tasks and ADRs similarly
follow existing requirements, including required ADRs. Establish a new task or
ADR convention only after an explicit request and confirmation.
