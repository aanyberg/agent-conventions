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

## Available skills

| Skill | Category | What it does | Target area |
|---|---|---|---|
| `value-gate` | Workflow | Gets a human go/no-go on whether a proposed change is worth building. | New features and behaviour changes |
| `behavior-spec` | Workflow | Writes Given/When/Then scenarios as acceptance criteria. | New features and behaviour changes |
| `test-driven-development` | Workflow | Implements approved scenarios with a failing test first. | New features and behaviour changes |
| `task-workflow` | Workflow | Manages task records, merge readiness, and autonomous implementation of an item. | Task execution |
| `backlog-management` | Workflow | Lists, creates, claims, links, and updates work items in the repository's tracker. | Backlog |
| `backlog-loop` | Workflow | Plans the backlog into named batches and executes them in waves, one pull request per batch. | Backlog |
| `git-conventions` | Workflow | Follows repository-native commit, branch, pull request, and worktree conventions. | Git |
| `architecture-planning` | Design | Guides architectural decisions, boundaries, technology choices, and decision records. | Architecture |
| `testing-strategy` | Design | Designs test strategies and test plans. | Testing |
| `code-standards` | Code quality | Applies cross-language code rules, testing boundaries, and semantic versioning. | Any language |
| `code-review` | Code quality | Reviews a branch or pull request before merge with the matching language guidelines. | Any language |
| `tech-debt` | Code quality | Identifies, categorizes, and prioritizes technical debt. | Code health |
| `docs-standards` | Documentation | Keeps READMEs, changelogs, and other docs consistent with the code. | Documentation |
| `python-best-practices` | Language | Entry point for working in Python files. | Python |
| `python-coding-guidelines` | Language | Simplifies code with Python idioms. | Python |
| `python-design-patterns` | Language | Applies design patterns when structuring or refactoring components. | Python |
| `rust-best-practices` | Language | Entry point for working in Rust files. | Rust |
| `rust-coding-guidelines` | Language | Applies Rust idioms, type system usage, error handling, and naming. | Rust |
| `rust-design-patterns` | Language | Applies design patterns when structuring or refactoring components. | Rust |
| `typescript-coding-guidelines` | Language | Applies idioms, type system usage, error handling, and naming. | TypeScript and JavaScript |
| `ios-app-intents` | iOS | Designs App Intents, app entities, and App Shortcuts. | iOS system surfaces |
| `ios-debugger-agent` | iOS | Builds, runs, and debugs apps on Simulator with XcodeBuildMCP. | iOS debugging |
| `ios-ettrace-performance` | iOS | Captures and interprets Simulator ETTrace profiles. | iOS performance |
| `ios-memgraph-leaks` | iOS | Captures and inspects leaks and memgraphs. | iOS memory |
| `ios-simulator-browser` | iOS | Mirrors a Simulator into a browser and renders SwiftUI previews with hot reload. | iOS previews |
| `swiftui-liquid-glass` | SwiftUI | Implements and reviews iOS 26+ Liquid Glass UI. | SwiftUI design |
| `swiftui-performance-audit` | SwiftUI | Audits runtime performance from code first. | SwiftUI performance |
| `swiftui-ui-patterns` | SwiftUI | Builds and refactors UI with component patterns and examples. | SwiftUI UI |
| `swiftui-view-refactor` | SwiftUI | Refactors view files into stable, testable structure. | SwiftUI structure |

## Skills with their own documentation

Most skills are a single `SKILL.md`. The larger ones ship a README that
explains what they do, how to use them, and how they work inside:

| Skill | What it does |
|---|---|
| [`backlog-loop`](skills/backlog-loop/README.md) | Works through a backlog unattended: named batches run in waves, one worker per item, one CI-gated pull request per batch, with set-aside and remaining items reported. |

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
