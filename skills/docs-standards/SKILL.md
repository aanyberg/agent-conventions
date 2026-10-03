---
name: docs-standards
description: Use when writing or updating documentation — READMEs, changelogs, role/layer docs, ADRs, or API references. Preserves repository locations, formats, terminology, and release conventions.
---

# Documentation Standards

Keeps repository documentation consistent, factual, and in sync with the code it describes.

Preserve the repository's existing documentation locations, changelog format,
role document structure, release process, and commit conventions. Do not create
a `CHANGELOG.md`, `.planning/`, role-doc hierarchy, or release artifact solely
to follow this skill.

## When to Load

Load this skill when:

- Writing or editing `.md` files (README, guides, runbooks)
- Adding a changelog fragment under `changelog/` or preparing release notes
- Creating or updating role docs (`docs/roles/*.md`) or layer docs
- Documenting a public API, module, or behavioural change
- Reviewing a pull request that changes documentation

For **multi-file doc synchronisation** after a code change, map the diff to
every affected page and maintain release traceability. If a
documentation-sync subagent is available in the environment, it can handle
this work; this repository does not provide one.

## Where Documentation Lives

Follow the repository's existing documentation layout. Common locations are
listed for discovery only; they are not reasons to create or move files.

| Doc | Location | Owning skill |
|-----|----------|----------------------|
| Project overview | `README.md` | docs-standards |
| Unreleased changes | `changelog/` (one fragment per change) | docs-standards |
| Release history | `CHANGELOG.md` (assembled from fragments at release) | docs-standards + code-standards (versioning) |
| System-as-is + ADRs | Existing architecture/ADR location | architecture-planning |
| Role behaviour | `docs/roles/*.md` | docs-standards |
| Layer / locked-version tables | layer docs | docs-standards |
| Task / backlog records | Existing task or backlog location | task-workflow, backlog-management |

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

## Changelog format

The changelog convention is one fragment file per change in
`<project>/changelog/`.

- If `<project>/changelog/` exists, follow its `README.md` for naming,
  categories, size limit, and release steps.
- If it does not exist and the user wants a changelog, create
  `<project>/changelog/` with a `README.md` that defines those rules. Do not
  use another directory name.
- Never edit `CHANGELOG.md` for unreleased work. Add a fragment instead, and
  do not append to `[Unreleased]`.
- `CHANGELOG.md` is written only when a release is cut, assembled from the
  fragments.
- Keep fragments short; detail belongs in the PR body.
- Grep changelog archives; never read them whole.

Fragment categories are the *Keep a Changelog* headings: `Added`, `Changed`,
`Fixed`, `Removed`, `Deprecated`, `Security`. Versions follow Semantic
Versioning. Determine the version source of truth from the repository's
release configuration.

The assembled release section in `CHANGELOG.md` looks like this:

```markdown
## [1.4.0] - 2025-01-30
### Added
- Short, user-facing description of the change.
### Fixed
- ...
```

- Add a fragment **only when public or observable behaviour changes** (mirrors **task-workflow** merge-readiness step 5).
- The release commit assembles the `changelog/` fragments into `CHANGELOG.md`, deletes them, then bumps the version (**code-standards** → Semantic Versioning).

## Suggested role doc layout

Preserve the existing role-document layout. If the user requests a new role
documentation convention, the following order is a concise starting point:

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

Treat stale documentation like a failing test and fix affected docs in the
same change:

- A behavioural change updates the affected page and adds a `changelog/`
  fragment only when the repository's existing conventions require it.
- A structural change updates the repository's existing architecture record.
- Missing or outdated docs are **Documentation debt**. Track them in the
  repository's existing work system; use **backlog-management** when the user
  wants the debt recorded and a backend has been resolved.

## Commits & Branches

Follow the repository's existing commit and branch conventions. If none exist,
**git-conventions** may use:

- Commit: `docs(<scope>): <imperative>` — e.g. `docs(api): clarify retry backoff`
- Branch: the fallback selected by **git-conventions**
