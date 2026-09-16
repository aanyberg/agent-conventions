---
name: code-review
description: Review code changes on the current branch or PR before merge, in any language. Detects the languages in the diff and applies the matching guideline skill (python-coding-guidelines, typescript-coding-guidelines, rust-coding-guidelines). Use for PR reviews, branch audits, test adequacy checks, and as the independent reviewer step in task-workflow merge readiness. Constructive tone, actionable findings.
---

# Code Review

Structured review of code modified on the current branch, focusing on correctness and edge cases, readability and maintainability, idiomatic usage per language, typing quality, test coverage of business logic, KISS, pragmatic SOLID, and separation of concerns.

Uses constructive, collaborative phrasing ("Have you considered ...?") with practical suggestions.

## When to use

- Reviewing a pull request or branch before merge
- Acting as the independent reviewer in **task-workflow** row 12
- Auditing recent changes for quality
- Improving test strategy for new functionality

## Reviewer independence

When invoked as the independent reviewer, the reviewer receives only the diff,
the work item's goal and acceptance criteria when one exists, and the tests. It
does not receive the author's reasoning, plan, or log. It runs in a fresh
context or as a separate subagent. The author never approves their own PR.

## Workflow

### 1) Collect changed files

Use the pull request's known base when available. Otherwise inspect repository
metadata for the default branch rather than assuming `origin/main`. For
uncommitted work, include staged and unstaged changes. Fetch only when remote
comparison is necessary and allowed.

Group by language from extension: `.py` → python-coding-guidelines; `.ts .tsx .js .jsx` → typescript-coding-guidelines; `.rs` → rust-coding-guidelines. Load each applicable guideline skill plus **code-standards**. Files with no matching guideline (SQL, YAML, shell, Terraform) are reviewed against the universal checks only. If no reviewable files changed, report that and stop.

### 2) Review each changed file

Universal checks, every language:

1. **Correctness**: bugs, missed edge cases, failure modes, error handling, input validation at boundaries.
2. **Security**: authz on every new endpoint or query path, no secrets in code or logs, no injection via string-built queries or shell, no new dependency without a human label.
3. **Tests**: business logic and complex behaviour tested; critical paths, edge cases, regressions covered; no test deleted or skipped without justification; no exhaustive tests demanded for trivial wrappers.
4. **Design**: KISS, cohesion, dependency direction, interface clarity, split overly complex units.
5. **Scope**: diff matches the acceptance criteria, no unrelated changes, no drive-by refactors outside task scope.
6. **Docs**: repository documentation is updated when behaviour or structure
   changed. Require a changelog or architecture record only when the
   repository's existing conventions require one.

Language-specific checks:

**Python**
- Google Python Style Guide alignment, naming, docstrings, clear control flow
- Public APIs and core logic typed; precise hints; no unnecessary `Any`
- Idiomatic constructs, no overengineering

**TypeScript / JavaScript**
- `strict` respected; `unknown` over `any`; `as` only with documented safety reasoning; `@ts-expect-error` only with a comment
- Discriminated unions and `never` exhaustiveness on sum types
- Runtime validation through the project's existing validation approach at
  external boundaries: request bodies, environment, and third-party responses
- Async errors handled; no swallowed `.catch`; domain error classes with `cause`
- Named exports, import order, no circular imports
- Changed behaviour has a unit test or a Playwright test; stubs preferred over full module mocks
- Frontend: accessible markup (labels, roles, keyboard), no layout done with `any`-typed props

**Rust**
- Per rust-coding-guidelines: ownership clarity, structured error types using
  existing project dependencies, no `unwrap` in library paths, clippy clean

### 3) Prioritise findings

- **High**: likely bug, missing critical test, unsafe behaviour, authz gap, scope violation
- **Medium**: maintainability risk, weak typing, design concern, missing boundary validation
- **Low**: style or readability polish

### 4) Constructive language

Prefer "Have you considered handling ...?", "Would it simplify this if ...?", "Could this be split into ... for clearer separation?". Avoid "This is wrong."

### 5) Actionable suggestions

Every significant finding: why it matters, concrete improvement, optional code sketch.

## Output format

1. **Summary**: scope reviewed (files, languages), overall impression, verdict `approve` | `request-changes` | `needs-human`.
2. **Findings by priority**: High / Medium / Low, file + location, observation + suggestion.
3. **Testing assessment**: what is adequately tested, what critical behaviour is not.
4. **Refactor opportunities**: KISS simplifications, separation of concerns, idiomatic upgrades.
5. **Acceptance criteria check** (independent reviewer only): each criterion with met / not met / cannot verify.

`needs-human` is mandatory when the diff adds a dependency, changes a public
API or schema, or touches a repository-designated protected path.

## Quality checks before finishing

- Reviewed only changed branch files, or stated the deviation
- Loaded the guideline skill for every language present
- Included typing, security, and testing assessment
- Called out complexity with simplification options
- Verdict stated explicitly
