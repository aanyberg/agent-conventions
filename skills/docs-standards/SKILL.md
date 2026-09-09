---
name: docs-standards
description: Use when writing or updating documentation — READMEs, CHANGELOGs, role/layer docs, ADRs, or API references. Covers doc placement, changelog format, the mandatory role-doc layout, writing style, and when to hand off to the docs-change-steward agent.
---

# Documentation Standards

Keeps repository documentation consistent, factual, and in sync with the code it describes.

## When to Load

Load this skill when:

- Writing or editing `.md` files (README, guides, runbooks)
- Adding a `CHANGELOG.md` entry or preparing release notes
- Creating or updating role docs (`docs/roles/*.md`) or layer docs
- Documenting a public API, module, or behavioural change
- Reviewing a pull request that changes documentation

For **multi-file doc synchronisation** after a code change — mapping a diff to every affected page and maintaining release traceability — hand off to the **docs-change-steward** agent, which enforces these same standards at scale.

## Where Documentation Lives

| Doc | Location | Owning skill / agent |
|-----|----------|----------------------|
| Project overview | `README.md` | docs-standards |
| Release history | `CHANGELOG.md` | docs-standards + code-standards (versioning) |
| System-as-is + ADRs | `.planning/architecture.md` | architecture-planning |
| Role behaviour | `docs/roles/*.md` | docs-change-steward |
| Layer / locked-version tables | layer docs | docs-change-steward |
| Task / backlog records | `.planning/tasks/`, `BACKLOG.md` | task-workflow, backlog-management |

Keep each doc in its canonical location. Do not duplicate the same information across files — link instead.

## Writing Style

- **Factual and concise.** Describe what is true now; never invent versions, dates, or behaviour.
- **Explain *why*, not *what*.** The code shows *what*; docs add rationale and context.
- **Match existing terminology.** Reuse the repo's nouns and headings; don't introduce synonyms.
- **Prefer tables and short lists** over long prose for reference material.
- **Imperative, active voice** in instructions ("Run", not "You should run").

## Markdown Conventions

- One `#` H1 per file (the title); nest headings without skipping levels.
- Fenced code blocks always carry a language hint (` ```bash `, ` ```python `).
- Use relative links between repo docs so they survive clones and moves.
- Wrap file names, paths, commands, and identifiers in backticks.

## CHANGELOG Format

Follow *Keep a Changelog* with Semantic Versioning. The version source of truth is `pyproject.toml` (Python) or `package.json` (Node/TypeScript) per **code-standards**.

```markdown
## [1.4.0] - 2025-01-30
### Added
- Short, user-facing description of the change.
### Fixed
- ...
```

- Group entries under `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`.
- Add an entry **only when public or observable behaviour changes** (mirrors **task-workflow** merge-readiness step 5).
- Bump the version and update `CHANGELOG.md` in the same commit that cuts the release (**code-standards** → Semantic Versioning).

## Role Doc Layout (mandatory)

When creating or updating a role document under `docs/roles/*.md`, use this exact top-level section order so files stay consistent with the **docs-change-steward** agent:

1. `## What is this role?`
2. `## What does this role do?`
3. `## Configuration`
4. `## Files and Templates`
5. `## Other Important Information` (only if needed)

Rules:

- Do not add alternative top-level headings (no "Overview", "Features", "Requirements").
- Omit `Other Important Information` when there is nothing extra to say.
- Save locked software versions in their layer-doc version tables when applicable.

## Keeping Docs in Sync

Treat stale documentation like a failing test — fix it in the same branch as the change that made it wrong:

- A behavioural change updates the affected page **and** `CHANGELOG.md`.
- A structural change updates `.planning/architecture.md` (see **architecture-planning**).
- Missing or outdated docs are **Documentation debt** — log them via **tech-debt**, then track through **backlog-management**.

## Commits & Branches

Documentation-only changes use the `docs` type (see **git-conventions**):

- Commit: `docs(<scope>): <imperative>` — e.g. `docs(api): clarify retry backoff`
- Branch: `docs/<short-kebab-description>`
