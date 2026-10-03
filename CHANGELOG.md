# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- Remove the central workflow policy and automatic backend detection. Skills
  now follow repository evidence, and backlog management asks the user when
  the choice between GitHub Issues, `BACKLOG.md`, or no persistent tracker is
  ambiguous.
- Follow existing project dependencies and tooling instead of defaulting to
  Hatch, pnpm, barrel modules, or optional Rust support crates.

- Make `changelog/` fragments the changelog convention in `docs-standards`:
  one fragment per change, with `CHANGELOG.md` assembled only when a release
  is cut. `task-workflow` merge readiness now asks for a fragment.

- Add a Git snapshot rule to `AGENTS.md` and `git-conventions`: commit every
  verified working state before moving on to the next change.

### Removed

- Remove the package installer, package metadata and lockfile, provider-native
  plugin manifests, publishing workflow, and bundled agent definitions. Skills
  are now available through `npx skills` or by referencing this repository
  directly.
- Remove the automated validation workflow and local test harness.
