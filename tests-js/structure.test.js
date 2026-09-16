import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { describe, test } from 'node:test'

import {
  ROOT,
  SPEC_FRONTMATTER_KEYS,
  agentFiles,
  difference,
  duplicates,
  markdownFiles,
  parseFrontmatter,
  relative,
  skillFiles,
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
  test('markdown discovery covers tracked files only', () => {
    const discovered = markdownFiles().map(relative)
    const untracked = discovered.filter(
      (file) => file.startsWith('.') || file.includes('node_modules/'),
    )
    assert.deepEqual(untracked, [])
    assert.ok(discovered.includes('README.md'))
    assert.ok(discovered.includes('skills/backlog-management/SKILL.md'))
  })

  for (const file of markdownFiles()) {
    test(`${relative(file)} has no broken relative links`, () => {
      const broken = [...fs.readFileSync(file, 'utf8').matchAll(LINK)]
        .map((match) => match[1])
        .filter((target) => !fs.existsSync(path.resolve(path.dirname(file), target.split('#', 1)[0])))
      assert.deepEqual(broken, [])
    })
  }

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

describe('repository-native workflow contract', () => {
  test('ships no central policy or policy-management scripts', () => {
    const removed = [
      'policy.example.yml',
      'skills/backlog-management/policy.example.yml',
      'skills/backlog-management/scripts/detect-backend.sh',
      'skills/backlog-management/scripts/generate-policy.sh',
      'skills/backlog-management/scripts/init-managed-workflow.sh',
    ]
    assert.deepEqual(
      removed.filter((file) => fs.existsSync(path.join(ROOT, file))),
      [],
    )
  })

  test('shipped guidance has no policy dependency', () => {
    const files = [
      ...skillFiles(),
      ...agentFiles(),
      path.join(ROOT, 'AGENTS.md'),
      path.join(ROOT, 'README.md'),
      path.join(ROOT, 'docs', 'CONSUMER.md'),
    ]
    const pattern = /\.planning\/policy\.yml|\bpolicy\.(?:backlog|git|versioning|autonomous|worktrees)|\bworkflow\.(?:backlog|tasks|architecture|autonomous)/
    const offenders = files
      .filter((file) => pattern.test(fs.readFileSync(file, 'utf8')))
      .map(relative)
    assert.deepEqual(offenders, [])
  })

  test('backlog selection asks only when repository evidence is ambiguous', () => {
    const backlog = fs.readFileSync(
      path.join(ROOT, 'skills', 'backlog-management', 'SKILL.md'),
      'utf8',
    )
    assert.match(
      backlog,
      /Honor an explicit selection in the user's request: GitHub Issues,\s+`BACKLOG\.md`, or no persistent backlog/s,
    )
    assert.match(backlog, /Any documented selection is\s+authoritative/s)
    assert.match(
      backlog,
      /If an explicit or documented selection exists, use it and stop resolution/,
    )
    assert.match(
      backlog,
      /Only when neither the request nor repository instructions select an option,\s+inspect existing state/s,
    )
    assert.match(
      backlog,
      /repository-specific labels, fields, projects, or statuses, is evidence for\s+the GitHub Issues backend/s,
    )
    assert.match(backlog, /exactly one backend is established, use it/)
    assert.match(backlog, /If neither or both are\s+plausible, ask the user to choose/s)
    assert.match(backlog, /GitHub remote or enabled Issues feature alone is not a backend choice/)
    assert.match(backlog, /Do not create a policy or private configuration file/)
    assert.match(
      backlog,
      /Load `backends\/<backend>\.md` only for GitHub Issues or\s+Markdown/s,
    )
  })

  test('keeps both backlog backend adapters', () => {
    for (const backend of ['github-issues.md', 'markdown.md']) {
      const file = path.join(
        ROOT,
        'skills',
        'backlog-management',
        'backends',
        backend,
      )
      assert.ok(fs.statSync(file).isFile())
      assert.doesNotMatch(
        fs.readFileSync(file, 'utf8'),
        /\.planning\/policy\.yml|\bpolicy\./,
      )
    }
  })

  test('publishes only the backlog skill and its two adapters', () => {
    const packed = JSON.parse(execFileSync(
      'npm',
      ['pack', '--dry-run', '--json', '--silent'],
      { cwd: ROOT, encoding: 'utf8' },
    ))
    const backlogPaths = packed[0].files
      .map((file) => file.path)
      .filter((file) => file.startsWith('skills/backlog-management/'))
      .sort()
    assert.deepEqual(backlogPaths, [
      'skills/backlog-management/SKILL.md',
      'skills/backlog-management/backends/github-issues.md',
      'skills/backlog-management/backends/markdown.md',
    ])
  })

  test('task workflow activates structured files only from evidence or intent', () => {
    const taskWorkflow = fs.readFileSync(
      path.join(ROOT, 'skills', 'task-workflow', 'SKILL.md'),
      'utf8',
    )
    assert.match(taskWorkflow, /Loading\s+this skill does not create `.planning\/`/s)
    assert.match(taskWorkflow, /user explicitly requests it/)
    assert.match(taskWorkflow, /repository already contains `.planning\/tasks\/`/)
    assert.match(taskWorkflow, /Backlog tracking is independent/)
  })

  test('architecture records activate from repository practice or intent', () => {
    const architecture = fs.readFileSync(
      path.join(ROOT, 'skills', 'architecture-planning', 'SKILL.md'),
      'utf8',
    )
    assert.match(
      architecture,
      /when repository practice\s+requires it or the user explicitly asks/s,
    )
    assert.match(
      architecture,
      /Propose and confirm a\s+location only when establishing a new convention/s,
    )
    for (const file of [
      path.join(ROOT, 'AGENTS.md'),
      path.join(ROOT, 'docs', 'CONSUMER.md'),
    ]) {
      const guidance = fs.readFileSync(file, 'utf8')
      assert.match(guidance, /required ADRs/)
      assert.match(
        guidance,
        /new .*ADR convention.*only (?:when|after)\s+an explicit request/s,
      )
    }
  })

  test('workflow-aware agents preserve repository-native behavior', () => {
    for (const name of [
      'conventions-code-reviewer.md',
      'conventions-docs-steward.md',
      'conventions-implementer.md',
      'conventions-planner.md',
    ]) {
      const file = path.join(ROOT, 'agent-sources', name)
      const text = fs.readFileSync(file, 'utf8')
      assert.match(text, /repository/, relative(file))
      assert.doesNotMatch(text, /policy|generic or managed mode/, relative(file))
    }
  })

  test('language guidance does not impose optional tools or dependencies', () => {
    const forbiddenDefaults = [
      ['skills/python-coding-guidelines/SKILL.md', /Projects generally use `hatch`/],
      ['skills/typescript-coding-guidelines/SKILL.md', /Use `pnpm` by default/],
      ['skills/typescript-coding-guidelines/SKILL.md', /Use barrel files .* to define/],
      ['skills/typescript-coding-guidelines/SKILL.md', /Run `eslint` and `prettier`/],
      ['skills/typescript-coding-guidelines/SKILL.md', /`strict: true` is non-negotiable/],
      ['skills/rust-coding-guidelines/SKILL.md', /Use `anyhow` .* for application/],
      ['skills/rust-coding-guidelines/SKILL.md', /Set `#!\[deny\(warnings\)\]`/],
    ]
    for (const [file, pattern] of forbiddenDefaults) {
      assert.doesNotMatch(fs.readFileSync(path.join(ROOT, file), 'utf8'), pattern, file)
    }
  })

  test('TDD activates only from repository practice or user intent', () => {
    const tdd = fs.readFileSync(
      path.join(ROOT, 'skills', 'test-driven-development', 'SKILL.md'),
      'utf8',
    )
    const strategy = fs.readFileSync(
      path.join(ROOT, 'skills', 'testing-strategy', 'SKILL.md'),
      'utf8',
    )
    assert.match(tdd, /when the user requests it, the repository documents it/)
    assert.match(strategy, /When the repository or user has selected TDD/)
    assert.doesNotMatch(tdd, /\*\*Always:\*\*/)
  })
})
