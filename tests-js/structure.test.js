import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { describe, test } from 'node:test'

import { parse as parseYaml } from 'yaml'

import {
  ROOT,
  SPEC_FRONTMATTER_KEYS,
  agentFiles,
  difference,
  duplicates,
  markdownFiles,
  parseFrontmatter,
  relative,
  shellScripts,
  skillFiles,
  walk,
} from '../test-utils/repository.js'

const NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const VALID_TOOLS = new Set([
  'AskUserQuestion', 'Bash', 'Edit', 'Glob', 'Grep', 'NotebookEdit', 'Read',
  'Skill', 'SlashCommand', 'Task', 'TodoWrite', 'WebFetch', 'WebSearch', 'Write',
])
const AGENT_KEYS = new Set([
  'name', 'description', 'capabilities', 'access', 'model-tier', 'effort', 'max-turns',
])
const VALID_CAPABILITIES = new Set(['read', 'search', 'shell', 'write', 'ask'])
const VALID_ACCESS = new Set(['read-only', 'workspace-write'])
const VALID_MODEL_TIERS = new Set(['fast', 'balanced', 'deep'])
const VALID_EFFORT = new Set(['low', 'medium', 'high'])

const skills = skillFiles().map(parseFrontmatter)
const agents = agentFiles().map(parseFrontmatter)

describe('skill frontmatter', () => {
  test('every skill directory has a SKILL.md', () => {
    const missing = fs.readdirSync(path.join(ROOT, 'skills'), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(ROOT, 'skills', entry.name))
      .filter((dir) => !fs.existsSync(path.join(dir, 'SKILL.md')))
      .map(relative)
    assert.deepEqual(missing, [])
  })

  for (const skill of skills) {
    test(`${skill.rel} has a name and description`, () => {
      assert.ok(Object.hasOwn(skill.frontmatter, 'name'), `${skill.rel}: frontmatter has no 'name'`)
      assert.ok(Object.hasOwn(skill.frontmatter, 'description'), `${skill.rel}: frontmatter has no 'description'`)
      assert.ok(String(skill.frontmatter.description).trim(), `${skill.rel}: description is empty`)
    })

    test(`${skill.rel} name matches its directory`, () => {
      assert.equal(skill.frontmatter.name, path.basename(path.dirname(skill.path)))
    })

    test(`${skill.rel} name is kebab-case`, () => {
      assert.match(String(skill.frontmatter.name ?? ''), NAME)
    })

    test(`${skill.rel} description fits the loader budget`, () => {
      assert.ok(String(skill.frontmatter.description).length <= 1024)
    })

    test(`${skill.rel} has only specification frontmatter`, () => {
      assert.deepEqual(difference(Object.keys(skill.frontmatter), SPEC_FRONTMATTER_KEYS), [])
    })

    test(`${skill.rel} allowed tools are known`, () => {
      let tools = skill.frontmatter['allowed-tools']
      if (tools === undefined) return
      if (typeof tools === 'string') tools = tools.split(',').map((tool) => tool.trim()).filter(Boolean)
      const unknown = tools.filter((tool) => !VALID_TOOLS.has(tool) && !String(tool).startsWith('mcp__'))
      assert.deepEqual(unknown, [])
    })

    test(`${skill.rel} body is not a stub`, () => {
      assert.ok(skill.body.trim().length > 100)
    })
  }

  test('skill names are unique', () => {
    assert.deepEqual(duplicates(skills.map((skill) => skill.frontmatter.name)), [])
  })
})

describe('canonical agent frontmatter', () => {
  for (const agent of agents) {
    test(`${agent.rel} has all required fields`, () => {
      assert.deepEqual(difference(AGENT_KEYS, new Set(Object.keys(agent.frontmatter))), [])
    })

    test(`${agent.rel} has no unknown fields`, () => {
      assert.deepEqual(difference(Object.keys(agent.frontmatter), AGENT_KEYS), [])
    })

    test(`${agent.rel} name matches its filename`, () => {
      assert.equal(agent.frontmatter.name, path.basename(agent.path, '.md'))
    })

    test(`${agent.rel} has a package-prefixed kebab-case name`, () => {
      assert.match(String(agent.frontmatter.name ?? ''), NAME)
      assert.ok(agent.frontmatter.name.startsWith('conventions-'))
    })

    test(`${agent.rel} has a non-empty description`, () => {
      assert.ok(String(agent.frontmatter.description ?? '').trim())
    })

    test(`${agent.rel} capabilities are valid`, () => {
      const capabilities = agent.frontmatter.capabilities
      assert.ok(Array.isArray(capabilities) && capabilities.length > 0)
      assert.deepEqual(difference(capabilities, VALID_CAPABILITIES), [])
    })

    test(`${agent.rel} access is valid`, () => {
      assert.ok(VALID_ACCESS.has(agent.frontmatter.access))
    })

    test(`${agent.rel} model tier is valid`, () => {
      assert.ok(VALID_MODEL_TIERS.has(agent.frontmatter['model-tier']))
    })

    test(`${agent.rel} effort is valid`, () => {
      assert.ok(VALID_EFFORT.has(agent.frontmatter.effort))
    })

    test(`${agent.rel} max turns is a positive integer`, () => {
      const turns = agent.frontmatter['max-turns']
      assert.ok(Number.isInteger(turns) && turns > 0 && turns <= 100)
    })

    test(`${agent.rel} read-only roles cannot write`, () => {
      if (agent.frontmatter.access === 'read-only') {
        assert.ok(!agent.frontmatter.capabilities.includes('write'))
      }
    })
  }

  test('agent names are unique', () => {
    assert.deepEqual(duplicates(agents.map((agent) => agent.frontmatter.name)), [])
  })
})

const LINK = /\[[^\]]*\]\((?!https?:\/\/|mailto:|#)([^)\s]+)\)/g
const REFERENCE = /\*\*([a-z0-9]+(?:-[a-z0-9]+)+)\*\*/g
const NOT_A_REFERENCE = new Set([
  'agent-conventions', 'github-issues', 'release-commit-only', 'per-branch',
  'issue-number', 'needs-discussion', 'needs-human', 'agent-safe',
  'in-review', 'run-lock-issue', 'planning-runs-dir', 'short-kebab',
  'backlog-migration', 'delete-tests', 'skip-tests', 'delete-or-skip-test',
  'commit-to-protected-branch', 'package-lock', 'pnpm-lock',
  'language-specific', 'cross-language', 'type-first', 'read-only',
])

describe('cross-references', () => {
  for (const file of markdownFiles()) {
    test(`${relative(file)} has no broken relative links`, () => {
      const broken = [...fs.readFileSync(file, 'utf8').matchAll(LINK)]
        .map((match) => match[1])
        .filter((target) => !fs.existsSync(path.resolve(path.dirname(file), target.split('#', 1)[0])))
      assert.deepEqual(broken, [])
    })
  }

  test('shipped scripts are executable and have a shebang', () => {
    const problems = []
    for (const script of shellScripts()) {
      try {
        fs.accessSync(script, fs.constants.X_OK)
      } catch {
        problems.push(`${relative(script)} (not executable)`)
      }
      if (!fs.readFileSync(script, 'utf8').startsWith('#!')) {
        problems.push(`${relative(script)} (no shebang)`)
      }
    }
    assert.deepEqual(problems, [])
  })

  test('references to shipped scripts name their owning skill', () => {
    const shipped = new Map(shellScripts().map((script) => [path.basename(script), script]))
    const problems = []
    for (const file of [...skillFiles(), ...agentFiles()]) {
      const text = fs.readFileSync(file, 'utf8')
      for (const match of text.matchAll(/[\w./-]*scripts\/([A-Za-z0-9_.-]+\.sh)/g)) {
        const script = shipped.get(match[1])
        if (!script) continue
        const owner = path.basename(path.dirname(path.dirname(script)))
        if (path.basename(path.dirname(file)) !== owner &&
            !text.includes(`**${owner}**`) && !text.includes(owner)) {
          problems.push(`${relative(file)} references scripts/${match[1]} without naming ${owner}`)
        }
      }
    }
    assert.deepEqual(problems, [])
  })

  test('skill and agent names referenced in prose exist', () => {
    const known = new Set([
      ...skills.map((skill) => skill.frontmatter.name),
      ...agents.map((agent) => agent.frontmatter.name),
      ...NOT_A_REFERENCE,
    ])
    const dangling = []
    for (const doc of [...skills, ...agents]) {
      for (const match of doc.body.matchAll(REFERENCE)) {
        if (!known.has(match[1])) dangling.push(`${doc.rel}: **${match[1]}**`)
      }
    }
    assert.deepEqual(dangling, [])
  })
})

const POLICY_TEMPLATE = path.join(ROOT, 'policy.example.yml')
const POLICY_REF = /\b(?:policy\.)?((?:backlog|ids|statuses|states|git|review|versioning|autonomous|checks|worktrees|tests|reporting)(?:\.[a-z_]+)+)\b/g
const FILE_EXTENSIONS = new Set(['md', 'yml', 'yaml', 'json', 'sh', 'py', 'toml'])

function flattenKeys(value, prefix = '') {
  const keys = new Set()
  if (!value || typeof value !== 'object' || Array.isArray(value)) return keys
  for (const [key, nested] of Object.entries(value)) {
    const current = `${prefix}${key}`
    keys.add(current)
    for (const child of flattenKeys(nested, `${current}.`)) keys.add(child)
  }
  return keys
}

function referencedPolicyKeys() {
  const refs = new Map()
  for (const file of [...skillFiles(), ...agentFiles()]) {
    for (const match of fs.readFileSync(file, 'utf8').matchAll(POLICY_REF)) {
      const key = match[1]
      if (FILE_EXTENSIONS.has(key.slice(key.lastIndexOf('.') + 1))) continue
      refs.set(key, [...(refs.get(key) ?? []), relative(file)])
    }
  }
  return refs
}

describe('policy template', () => {
  test('exists', () => {
    assert.ok(fs.statSync(POLICY_TEMPLATE).isFile())
  })

  test('parses as YAML', () => {
    const parsed = parseYaml(fs.readFileSync(POLICY_TEMPLATE, 'utf8'))
    assert.ok(parsed && typeof parsed === 'object' && !Array.isArray(parsed))
  })

  test('keeps backend auto for generation', () => {
    assert.match(fs.readFileSync(POLICY_TEMPLATE, 'utf8'), /^\s*backend: auto\s*$/m)
  })

  test('is the only policy template', () => {
    assert.deepEqual(
      walk(ROOT, (file) => path.basename(file) === 'policy.example.yml').map(relative),
      ['policy.example.yml'],
    )
  })

  const templateKeys = flattenKeys(parseYaml(fs.readFileSync(POLICY_TEMPLATE, 'utf8')))
  for (const [key, files] of [...referencedPolicyKeys()].sort()) {
    test(`declares referenced policy key ${key}`, () => {
      assert.ok(templateKeys.has(key), `referenced in: ${[...new Set(files)].sort().join(', ')}`)
    })
  }
})
