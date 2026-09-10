# Compatibility Contracts

`agent-conventions` supports Node.js 18.17 and newer. The Linux validation
workflow runs the full suite on Node.js 18.17 and 20; the release workflow
publishes from Node.js 20.

## Provider-Native Agents

The installer emits provider-native agent files. Validation parses every
rendered YAML or TOML file for every canonical role and checks it against the
versioned positive and negative fixtures in
`tests-js/fixtures/agent-contracts.js`. These are deterministic
renderer-contract checks, not a claim that each provider offers a schema
validator.

| Provider | Generated format | Official offline validator | Repository contract |
| --- | --- | --- | --- |
| Claude Code | YAML Markdown | Plugin helper is incompatible with the emitted fields | YAML syntax and emitted frontmatter fields |
| Codex | TOML | None for standalone agent TOML | TOML syntax, access mode, nonempty instructions |
| GitHub Copilot | YAML Markdown | None | YAML syntax and emitted frontmatter fields |
| OpenCode | YAML Markdown | None for Markdown agents | YAML syntax and permission fields |
| Cursor | YAML Markdown | None | YAML syntax and emitted frontmatter fields |
| Gemini CLI | YAML Markdown | None for agent files | YAML syntax and emitted frontmatter fields |

## Updating a Provider Contract

1. Confirm the provider's current agent-file documentation or schema.
2. Update the relevant renderer in `src/agents.js`.
3. Update `tests-js/fixtures/agent-contracts.js` with the provider's
   documented fields and valid values, plus an invalid fixture for the changed
   field or value.
4. Extend `tests-js/agents.test.js` if the field needs a new type or
   cross-field assertion.
5. Update this table if official validation availability changes.

Provider CLIs are intentionally not run in CI: their agent validation commands
are unavailable, unsupported for these file types, network-dependent, or
require a runtime newer than Node.js 18.17.
