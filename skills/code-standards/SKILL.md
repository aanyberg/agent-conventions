---
name: code-standards
description: Use when writing code, running linters, or reviewing pull requests. Covers universal cross-language code rules (style, naming, error handling, imports, testing), testing boundaries, language style-guide loading, and semantic versioning.
---

# Code Standards

Enforces consistent code quality and architectural boundaries.

## General Rules

### Testing Boundaries
- **Strict separation:** no implementation in test files, no test code in implementation files.
- Test files are for validation; implementation files are for logic.
- Shared test utilities go in a dedicated `test-utils` or `testing` module.

### Style Guides

Load language skills based on the files being changed. Each language skill carries only **language-specific** idioms, type-system usage, and tooling; the **Universal Code Rules** below apply to every language.

- **Python** (`.py`, `pyproject.toml`, `requirements.txt`): load `python-best-practices` + `python-coding-guidelines`; also load `python-design-patterns` when designing or refactoring component structure
- **TypeScript / JavaScript** (`.ts`, `.tsx`, `.js`, `.jsx`): load `typescript-coding-guidelines`
- **Rust** (`.rs`, `Cargo.toml`): load `rust-best-practices` + `rust-coding-guidelines`; also load `rust-design-patterns` when designing or refactoring component structure
- **Docs** (`.md`, `README`, `CHANGELOG`, role/layer docs): load `docs-standards`
- **Hatch projects**: load `hatch-workflow` for test, lint, and build entrypoints

### Semantic Versioning
- **Source of truth:** `pyproject.toml` (Python) or `package.json` (Node.js/TypeScript)
- Format: `MAJOR.MINOR.PATCH` (e.g., `1.2.3`)
- Bump version when cutting a release alongside a commit that updates CHANGELOG.md

### Conciseness
- Answers are short, no loss of information.
- "Fix this: X" > "We need to fix this: X"
- Comments explain *why*, not *what*; code is self-documenting.

## Universal Code Rules

Language-agnostic rules shared across Python, TypeScript, and Rust. The language coding-guidelines skills add the specifics (syntax, mechanisms, tooling) on top of these.

### Style
- Keep each commit/PR focused on a single stated purpose — exclude unrelated changes even if conceptually related (in Gerrit-style repos, each commit *is* a PR).
- Wrap code identifiers in backticks in user-facing messages (errors, warnings, logs).
- Centralize validation at one layer — validate/parse into a trusted type once at the boundary, then rely on it; prevents validation drift.
- Extract duplicated logic into a shared helper after 2+ occurrences — refactor rather than fork a parallel implementation.
- Consolidate duplicate logic across conditional branches (combined conditions, extracted variables, hoisted shared code).
- Remove commented-out code, unused definitions, and superseded implementations — version control preserves history.
- Inline single-use helpers that only wrap field/property access or delegation — removes needless indirection.
- Scope helpers and constants to their single usage site — don't hoist to module/crate root "just in case".
- Compile static regex patterns once as module-level constants — avoid recompiling on every call.

### Naming
- Drop redundant prefixes when context is clear — `Config.description`, not `Config.config_description`.
- Use specific names that convey meaning (`user_id`, `order_id`) over generic `id`, `name`, `data`.
- Boolean functions/variables read as predicates — `is_*`, `has_*`, `can_*`.
- Avoid redundant type suffixes (`Value`, `Type`, `Class`, `List`, `Str`) when the type is already clear.
- Rename functions/methods when their behavior changes — names must reflect actual scope, return values, and abstraction level.

### Error Handling
- Use domain-specific error types and preserve the cause chain when wrapping or re-raising (see each language skill for the mechanism).
- Don't use assertions as error handling — raise/throw a descriptive error including the relevant identifiers.
- Validate inputs before expensive work — fail fast.
- Catch specific error types, not a blanket catch-all, when the failure modes are known.

### Imports
- Place imports at the top of the file — no inline imports inside functions unless intentional, documented lazy-loading.
- Remove unused and duplicate imports.

### Testing
- Remove tests when redundant, obsolete, or duplicative — each test should verify distinct, currently-existing behavior.
- Test behavior through the public interface, not private internals.
- Use descriptive test names that read as sentences.
- Don't suppress coverage to hide gaps — write the test; only mark genuinely unreachable paths.
