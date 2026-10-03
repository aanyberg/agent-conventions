# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- Add the `value-gate` and `behavior-spec` skills. New behaviour now runs
  through value-gate (a human go/no-go, asked through interactive prompts with
  suggested answers and a free-text option), behavior-spec (Given/When/Then
  scenarios as acceptance criteria), then test-driven-development. When the
  value is unknown, value-gate offers an explore verdict that settles it with
  a scoped check or disposable spike. Approved scenarios can be recorded as a
  backlog item through `backlog-management`.

### Changed

- Make `test-driven-development` the default for new behaviour with approved
  scenarios: each scenario becomes a failing acceptance test before any
  production code. `task-workflow` task files gain `## Value` and
  `## Scenarios` sections.

- Remove the central workflow policy and automatic backend detection. Skills
  now follow repository evidence, and backlog management asks the user when
  the choice between GitHub Issues, `BACKLOG.md`, or no persistent tracker is
  ambiguous.
- Follow existing project dependencies and tooling instead of defaulting to
  Hatch, pnpm, barrel modules, or optional Rust support crates.

- Make `changelog/` fragments the changelog convention in `docs-standards`:
  one fragment per change, with `CHANGELOG.md` assembled only when a release
  is cut. `task-workflow` merge readiness now asks for a fragment.

### Removed

- Remove the package installer, package metadata and lockfile, provider-native
  plugin manifests, publishing workflow, and bundled agent definitions. Skills
  are now available through `npx skills` or by referencing this repository
  directly.
- Remove the automated validation workflow and local test harness.
