import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import {
  SPEC_FRONTMATTER_KEYS,
  agentFiles,
  difference,
  parseFrontmatter,
  skillFiles,
} from '../test-utils/repository.js'

const skills = skillFiles().map(parseFrontmatter)
const agents = agentFiles().map(parseFrontmatter)
const VENDOR_VARIABLE = /\$\{?(?:CLAUDE|CODEX|CURSOR|COPILOT|GEMINI)_[A-Z_]+\}?/
const VENDOR_COMPONENT_DIR = /\.(?:claude|codex|cursor|opencode|gemini|copilot|windsurf|github)\/(?:skills|agents|commands|rules|hooks|prompts)\//
const VENDOR_INSTRUCTION_FILE = /\b(?:CLAUDE\.md|GEMINI\.md|QWEN\.md|copilot-instructions\.md|\.cursorrules)\b/
const CLAUDE_TOOLS = 'AskUserQuestion|Bash|Edit|Glob|Grep|NotebookEdit|Read|Skill|SlashCommand|Task|TodoWrite|WebFetch|WebSearch|Write'
const TOOL_PHRASE = new RegExp(`\\b(?:${CLAUDE_TOOLS}) tools?\\b`)
const TOOL_BACKTICKED = /`(?:AskUserQuestion|NotebookEdit|SlashCommand|TodoWrite|WebFetch|WebSearch)`/
const AGENT_HANDOFF = new RegExp(
  `\\*{0,2}(${agents.map((agent) => agent.frontmatter.name).sort().join('|')})\\*{0,2}\\s+agent\\b`,
)

function hits(pattern, text) {
  const global = new RegExp(pattern.source, `${pattern.flags.replace('g', '')}g`)
  return [...new Set([...text.matchAll(global)].map((match) => match[0]))]
}

describe('skill specification conformance', () => {
  for (const skill of skills) {
    test(`${skill.rel} frontmatter stays within the specification`, () => {
      assert.deepEqual(difference(Object.keys(skill.frontmatter), SPEC_FRONTMATTER_KEYS), [])
    })

    test(`${skill.rel} name fits the specification limit`, () => {
      assert.ok(String(skill.frontmatter.name ?? '').length <= 64)
    })

    test(`${skill.rel} metadata is a string map`, () => {
      const metadata = skill.frontmatter.metadata
      if (metadata === undefined) return
      assert.ok(metadata && typeof metadata === 'object' && !Array.isArray(metadata))
      const bad = Object.entries(metadata)
        .filter(([key, value]) => typeof key !== 'string' || typeof value !== 'string')
        .map(([key]) => key)
      assert.deepEqual(bad, [])
    })

    test(`${skill.rel} compatibility fits the specification limit`, () => {
      const compatibility = skill.frontmatter.compatibility
      if (compatibility === undefined) return
      assert.ok(String(compatibility).length >= 1 && String(compatibility).length <= 500)
    })

    test(`${skill.rel} avoids experimental allowed-tools`, () => {
      assert.ok(!Object.hasOwn(skill.frontmatter, 'allowed-tools'))
    })
  }
})

const RULES = [
  ['interpolates no vendor variable', VENDOR_VARIABLE],
  ['references no vendor component directory', VENDOR_COMPONENT_DIR],
  ['references no vendor instruction file', VENDOR_INSTRUCTION_FILE],
]

describe('vendor-neutral prose', () => {
  for (const skill of skills) {
    for (const [label, pattern] of RULES) {
      test(`${skill.rel} ${label}`, () => assert.deepEqual(hits(pattern, skill.body), []))
    }

    test(`${skill.rel} names no vendor-specific tool`, () => {
      assert.deepEqual([...hits(TOOL_PHRASE, skill.body), ...hits(TOOL_BACKTICKED, skill.body)], [])
    })

    test(`${skill.rel} names agents only as optional capabilities`, () => {
      for (const [index, line] of skill.body.split('\n').entries()) {
        const match = AGENT_HANDOFF.exec(line)
        const qualified = line.includes('optional') || line.includes('when available') ||
          line.includes('package installer')
        assert.ok(!match || qualified, `${skill.rel}:${index + 1}: ${match?.[1]} is not optional`)
      }
    })
  }

  for (const agent of agents) {
    for (const [label, pattern] of RULES) {
      test(`${agent.rel} ${label}`, () => assert.deepEqual(hits(pattern, agent.body), []))
    }
  }
})

describe('progressive disclosure', () => {
  for (const skill of skills) {
    test(`${skill.rel} body stays within 500 lines`, () => {
      assert.ok(skill.body.split('\n').length <= 500)
    })
  }
})

const CAUGHT = [
  [VENDOR_VARIABLE, 'run ${CLAUDE_PLUGIN_ROOT}/scripts/x.sh'],
  [VENDOR_VARIABLE, '$CLAUDE_PROJECT_DIR/notes'],
  [VENDOR_COMPONENT_DIR, 'drop it in .claude/skills/foo/'],
  [VENDOR_COMPONENT_DIR, 'see .github/prompts/review.md'],
  [VENDOR_COMPONENT_DIR, 'add a rule under .cursor/rules/'],
  [VENDOR_INSTRUCTION_FILE, 'append it to CLAUDE.md'],
  [VENDOR_INSTRUCTION_FILE, 'documented in copilot-instructions.md'],
  [TOOL_PHRASE, 'use the Grep tool to find it'],
  [TOOL_PHRASE, 'dispatch with the Task tool'],
  [TOOL_PHRASE, 'prefer the Read and Write tools'],
  [TOOL_BACKTICKED, 'call `WebFetch` on the URL'],
  [AGENT_HANDOFF, 'hand off to the **conventions-docs-steward** agent'],
]

const IGNORED = [
  [VENDOR_COMPONENT_DIR, 'never in a global tool directory (e.g. `~/.claude`, `~/.copilot`)'],
  [VENDOR_VARIABLE, 'never in a global tool directory (e.g. `~/.claude`, `~/.copilot`)'],
  [VENDOR_COMPONENT_DIR, 'the portable location is .agents/skills/<name>/'],
  [VENDOR_INSTRUCTION_FILE, 'patterns from AGENTS.md apply here'],
  [VENDOR_COMPONENT_DIR, 'workflows live in .github/workflows/'],
  [TOOL_PHRASE, 'write the task file before any code'],
  [TOOL_PHRASE, 'read the policy first, then edit'],
  [TOOL_PHRASE, 'this is a read-only review task'],
  [TOOL_BACKTICKED, 'the `Read` step is implicit'],
]

describe('portability rule fixtures', () => {
  for (const [pattern, sample] of CAUGHT) {
    test(`catches ${JSON.stringify(sample)}`, () => assert.match(sample, pattern))
  }
  for (const [pattern, sample] of IGNORED) {
    test(`ignores ${JSON.stringify(sample)}`, () => assert.doesNotMatch(sample, pattern))
  }
})
