import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { after, test } from 'node:test'

import { parse as parseToml } from 'smol-toml'
import { parse as parseYaml } from 'yaml'

import { ROOT } from '../test-utils/repository.js'

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ac-renderers-'))
after(() => {
  fs.rmSync(tmp, { recursive: true, force: true })
})

function frontmatter(file) {
  const text = fs.readFileSync(file, 'utf8')
  assert.ok(text.startsWith('---\n'), file)
  const end = text.indexOf('\n---\n', 4)
  assert.notEqual(end, -1, file)
  return parseYaml(text.slice(4, end))
}

test('installer emits each provider-native agent format', () => {
  const home = path.join(tmp, 'home')
  const project = path.join(tmp, 'project')
  fs.mkdirSync(home)
  fs.mkdirSync(project)
  execFileSync(process.execPath, [
    path.join(ROOT, 'bin', 'cli.js'),
    '-p', '-a', 'all', '-c', 'agents', '-y',
  ], {
    cwd: project,
    env: { ...process.env, HOME: home, USERPROFILE: home, CI: '1' },
    encoding: 'utf8',
  })

  const claude = frontmatter(path.join(project, '.claude/agents/conventions-code-reviewer.md'))
  assert.deepEqual(new Set(Object.keys(claude)), new Set([
    'name', 'description', 'tools', 'model', 'effort', 'maxTurns', 'permissionMode',
  ]))
  assert.ok(!claude.tools.includes('Write'))

  const codexText = fs.readFileSync(
    path.join(project, '.codex/agents/conventions-code-reviewer.toml'),
    'utf8',
  )
  assert.doesNotMatch(codexText, /\\n/)
  assert.match(codexText, /^# Conventions Code Reviewer$/m)
  const codex = parseToml(codexText)
  assert.deepEqual(new Set(Object.keys(codex)), new Set([
    'name', 'description', 'sandbox_mode', 'model_reasoning_effort', 'developer_instructions',
  ]))
  assert.equal(codex.sandbox_mode, 'read-only')

  const copilot = frontmatter(
    path.join(project, '.github/agents/conventions-code-reviewer.agent.md'),
  )
  assert.deepEqual(new Set(Object.keys(copilot)), new Set(['name', 'description', 'tools']))
  assert.deepEqual(copilot.tools, ['read', 'search', 'execute'])

  const opencode = frontmatter(path.join(project, '.opencode/agents/conventions-code-reviewer.md'))
  assert.deepEqual(new Set(Object.keys(opencode)), new Set(['description', 'mode', 'permission']))
  assert.equal(opencode.permission.edit, 'deny')

  const cursor = frontmatter(path.join(project, '.cursor/agents/conventions-code-reviewer.md'))
  assert.deepEqual(
    new Set(Object.keys(cursor)),
    new Set(['name', 'description', 'model', 'readonly', 'is_background']),
  )
  assert.equal(cursor.readonly, true)

  const gemini = frontmatter(path.join(project, '.gemini/agents/conventions-code-reviewer.md'))
  assert.deepEqual(new Set(Object.keys(gemini)), new Set([
    'name', 'description', 'kind', 'tools', 'max_turns',
  ]))
  assert.ok(!gemini.tools.includes('write_file'))
})
