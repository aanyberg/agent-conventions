import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, test } from 'node:test'

import { parse as parseToml } from 'smol-toml'
import { parse as parseYaml } from 'yaml'

import { bundledAgents, parseCanonicalAgent, renderAgent } from '../src/agents.js'
import { agentTargets } from '../src/targets.js'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const PROVIDERS = ['claude-code', 'codex', 'github-copilot', 'opencode', 'cursor', 'gemini-cli']

function yamlHeader(output) {
  const end = output.indexOf('\n---\n', 4)
  assert.ok(output.startsWith('---\n') && end !== -1, 'must begin with YAML frontmatter')
  return {
    frontmatter: parseYaml(output.slice(4, end)),
    body: output.slice(end + 5),
  }
}

describe('canonical agents', () => {
  test('loads the six package-prefixed roles', () => {
    const names = bundledAgents(ROOT).map((agent) => agent.name)
    assert.deepEqual(names, [
      'conventions-code-reviewer',
      'conventions-docs-steward',
      'conventions-implementer',
      'conventions-planner',
      'conventions-repo-researcher',
      'conventions-verifier',
    ])
  })

  test('rejects write capability on a read-only role', () => {
    const source = [
      '---',
      'name: conventions-bad',
      'description: Invalid',
      'capabilities: [read, write]',
      'access: read-only',
      'model-tier: fast',
      'effort: low',
      'max-turns: 1',
      '---',
      '',
      'Body.',
    ].join('\n')
    assert.throws(() => parseCanonicalAgent(source), /cannot request write/)
  })
})

describe('provider renderers', () => {
  const agents = bundledAgents(ROOT)
  const reviewer = agents.find((agent) => agent.name === 'conventions-code-reviewer')
  const implementer = agents.find((agent) => agent.name === 'conventions-implementer')

  for (const provider of PROVIDERS) {
    test(`${provider} preserves canonical identity and body`, () => {
      const output = renderAgent(reviewer, provider)
      if (provider !== 'opencode') assert.match(output, /conventions-code-reviewer/)
      assert.match(output, /Review the assigned diff as an independent reviewer/)
      assert.match(output, /\n\n## Rules\n/)
      assert.doesNotMatch(output, /model-tier|max-turns|capabilities:/)
    })
  }

  test('Claude maps tiers and excludes write tools from reviewers', () => {
    const reviewerOutput = renderAgent(reviewer, 'claude-code')
    assert.match(reviewerOutput, /^model: opus$/m)
    assert.match(reviewerOutput, /^tools: Read, Grep, Glob, Bash, Skill$/m)
    assert.doesNotMatch(reviewerOutput, /\b(?:Edit|Write)\b/)

    const implementerOutput = renderAgent(implementer, 'claude-code')
    assert.match(implementerOutput, /^tools: .*Edit, Write/m)
  })

  test('Codex emits TOML with sandbox access and developer instructions', () => {
    const reviewerOutput = renderAgent(reviewer, 'codex')
    assert.match(reviewerOutput, /^sandbox_mode = "read-only"$/m)
    assert.match(reviewerOutput, /^developer_instructions = """$/m)
    assert.match(reviewerOutput, /\n# Conventions Code Reviewer\n\nReview the assigned diff/)
    assert.doesNotMatch(reviewerOutput, /\\n/)
    assert.doesNotMatch(reviewerOutput, /^---$/m)
    assert.equal(parseToml(reviewerOutput).developer_instructions, reviewer.body)

    const implementerOutput = renderAgent(implementer, 'codex')
    assert.match(implementerOutput, /^sandbox_mode = "workspace-write"$/m)
  })

  test('Codex multiline instructions preserve TOML-sensitive Markdown', () => {
    const source = [
      '---',
      'name: conventions-format-fixture',
      'description: Formatting fixture',
      'capabilities: [read]',
      'access: read-only',
      'model-tier: fast',
      'effort: low',
      'max-turns: 1',
      '---',
      '',
      '# Formatting',
      '',
      'Keep `\\s`, "quotes", and `"""` intact.',
    ].join('\n')
    const agent = parseCanonicalAgent(source)
    const output = renderAgent(agent, 'codex')
    assert.equal(parseToml(output).developer_instructions, agent.body)
    assert.ok(output.split('\n').length > 7, 'the Markdown body must use physical lines')
  })

  test('Codex emits every canonical body as readable multiline TOML', () => {
    for (const agent of agents) {
      const output = renderAgent(agent, 'codex')
      assert.ok(
        output.split('\n').length >= agent.body.split('\n').length,
        `${agent.name} must retain physical Markdown lines`,
      )
      assert.equal(parseToml(output).developer_instructions, agent.body, agent.name)
    }
  })

  test('Copilot emits mapped tools as a YAML array', () => {
    const output = renderAgent(reviewer, 'github-copilot')
    assert.match(output, /^tools: \["read", "search", "execute"\]$/m)
  })

  test('OpenCode expresses access through permission rules', () => {
    assert.match(renderAgent(reviewer, 'opencode'), /^  edit: deny$/m)
    assert.match(renderAgent(implementer, 'opencode'), /^  edit: allow$/m)
  })

  test('Cursor uses its readonly field', () => {
    assert.match(renderAgent(reviewer, 'cursor'), /^readonly: true$/m)
    assert.match(renderAgent(implementer, 'cursor'), /^readonly: false$/m)
  })

  test('Gemini uses snake-case turn limits and native tool names', () => {
    const output = renderAgent(reviewer, 'gemini-cli')
    assert.match(output, /^max_turns: 12$/m)
    assert.match(output, /^  - read_file$/m)
    assert.match(output, /^  - run_shell_command$/m)
  })

  test('every YAML renderer emits a parseable provider contract for every role', () => {
    const expectedKeys = {
      'claude-code': ['name', 'description', 'tools', 'model', 'effort', 'maxTurns', 'permissionMode'],
      'github-copilot': ['name', 'description', 'tools'],
      opencode: ['description', 'mode', 'permission'],
      cursor: ['name', 'description', 'model', 'readonly', 'is_background'],
      'gemini-cli': ['name', 'description', 'kind', 'tools', 'max_turns'],
    }
    for (const provider of Object.keys(expectedKeys)) {
      for (const agent of agents) {
        const { frontmatter, body } = yamlHeader(renderAgent(agent, provider))
        assert.deepEqual(Object.keys(frontmatter).sort(), expectedKeys[provider].sort(), `${provider}: ${agent.name}`)
        assert.ok(body.trim(), `${provider}: ${agent.name} body is empty`)
        assert.equal(frontmatter.description, agent.description, `${provider}: ${agent.name}`)
      }
    }
  })
})

describe('agent destinations', () => {
  test('project targets use each provider native directory and extension', () => {
    const targets = Object.fromEntries(
      agentTargets('project', { home: '/home/example', cwd: '/repo' })
        .map((target) => [target.agent, target]),
    )
    assert.equal(targets['claude-code'].dir, path.join('/repo', '.claude', 'agents'))
    assert.equal(targets.codex.suffix, '.toml')
    assert.equal(targets['github-copilot'].dir, path.join('/repo', '.github', 'agents'))
    assert.equal(targets['github-copilot'].suffix, '.agent.md')
    assert.equal(targets.opencode.dir, path.join('/repo', '.opencode', 'agents'))
    assert.equal(targets.cursor.dir, path.join('/repo', '.cursor', 'agents'))
    assert.equal(targets['gemini-cli'].dir, path.join('/repo', '.gemini', 'agents'))
  })
})
