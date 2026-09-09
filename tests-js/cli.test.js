/**
 * The CLI end to end, against a throwaway HOME and project.
 *
 * These run the real binary as a subprocess rather than importing its
 * internals, because the failure modes worth catching here are integration
 * ones: a plan that renders differently from what it executes, an uninstall
 * that removes a file it did not write, a second install that duplicates
 * instead of updating.
 */

import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, before, describe, test } from 'node:test'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const CLI = path.join(ROOT, 'bin', 'cli.js')

let tmp
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ac-cli-')) })
after(() => { fs.rmSync(tmp, { recursive: true, force: true }) })

/** Run the CLI with an isolated HOME and cwd. Never touches the real machine. */
function run(args, { home, cwd, expectFail = false } = {}) {
  try {
    return execFileSync(process.execPath, [CLI, ...args], {
      cwd: cwd ?? home,
      encoding: 'utf8',
      env: { ...process.env, HOME: home, USERPROFILE: home, CI: '1' },
    })
  } catch (err) {
    if (expectFail) return (err.stdout ?? '') + (err.stderr ?? '')
    throw new Error(`CLI failed: ${err.stdout}\n${err.stderr}`)
  }
}

function sandbox(name) {
  const home = path.join(tmp, name, 'home')
  const project = path.join(tmp, name, 'project')
  fs.mkdirSync(home, { recursive: true })
  fs.mkdirSync(project, { recursive: true })
  return { home, project }
}

describe('project scope', () => {
  test('writes exactly two directories and links Claude Code into the first', () => {
    const { home, project } = sandbox('project-basic')
    run(['-p', '-a', 'all', '-y'], { home, cwd: project })

    const canonical = path.join(project, '.agents', 'skills')
    const claude = path.join(project, '.claude', 'skills')
    assert.ok(fs.existsSync(canonical), '.agents/skills must hold the real files')
    assert.ok(fs.existsSync(claude), '.claude/skills must exist for Claude Code')

    const names = fs.readdirSync(canonical).sort()
    assert.ok(names.length >= 19, `expected the bundled skills, got ${names.length}`)
    assert.ok(names.includes('git-conventions'))

    // Claude's entries are links into the canonical copy, not duplicates.
    const entry = path.join(claude, 'git-conventions')
    assert.ok(fs.lstatSync(entry).isSymbolicLink(), 'Claude entries must be links, not copies')
    assert.ok(fs.existsSync(path.join(entry, 'SKILL.md')), 'the link must resolve')
  })

  test('does not write instructions at project scope', () => {
    const { home, project } = sandbox('project-no-instructions')
    const out = run(['-p', '-a', 'all', '-c', 'skills,instructions', '-y'], { home, cwd: project })
    assert.match(out, /global scope only/)
    assert.ok(!fs.existsSync(path.join(home, '.claude', 'CLAUDE.md')))
  })

  test('--copy produces real directories instead of links', () => {
    const { home, project } = sandbox('project-copy')
    run(['-p', '-a', 'all', '--copy', '-y'], { home, cwd: project })
    const entry = path.join(project, '.claude', 'skills', 'git-conventions')
    assert.equal(fs.lstatSync(entry).isSymbolicLink(), false)
    assert.ok(fs.existsSync(path.join(entry, 'SKILL.md')))
  })
})

describe('global scope', () => {
  test('installs skills and instructions, wrapping instructions in markers', () => {
    const { home } = sandbox('global-basic')
    run(['-g', '-a', 'all', '-y'], { home })

    assert.ok(fs.existsSync(path.join(home, '.agents', 'skills', 'git-conventions', 'SKILL.md')))
    const claudeMd = path.join(home, '.claude', 'CLAUDE.md')
    assert.ok(fs.existsSync(claudeMd), 'Claude Code global instructions must be written')
    const text = fs.readFileSync(claudeMd, 'utf8')
    assert.match(text, /BEGIN aanyberg\/agent-conventions/)
    assert.match(text, /END aanyberg\/agent-conventions/)

    for (const rel of [['.copilot', 'copilot-instructions.md'], ['.codex', 'AGENTS.md'], ['.gemini', 'GEMINI.md']]) {
      assert.ok(fs.existsSync(path.join(home, ...rel)), `${rel.join('/')} must be written`)
    }
  })

  test('preserves existing instruction content outside the markers', () => {
    const { home } = sandbox('global-preserve')
    const claudeMd = path.join(home, '.claude', 'CLAUDE.md')
    fs.mkdirSync(path.dirname(claudeMd), { recursive: true })
    const theirs = '# My own global rules\n\nAlways use tabs.\n'
    fs.writeFileSync(claudeMd, theirs)

    run(['-g', '-a', 'claude-code', '-y'], { home })
    const after = fs.readFileSync(claudeMd, 'utf8')
    assert.ok(after.startsWith(theirs), 'their content must survive verbatim, at the top')
    assert.match(after, /BEGIN aanyberg/)
  })

  test('a second install updates the block rather than duplicating it', () => {
    const { home } = sandbox('global-idempotent')
    run(['-g', '-a', 'claude-code', '-y'], { home })
    const once = fs.readFileSync(path.join(home, '.claude', 'CLAUDE.md'), 'utf8')
    run(['-g', '-a', 'claude-code', '-y'], { home })
    const twice = fs.readFileSync(path.join(home, '.claude', 'CLAUDE.md'), 'utf8')
    assert.equal(twice, once, 'install must be idempotent')
    assert.equal(twice.match(/BEGIN aanyberg/g).length, 1, 'exactly one block')
  })
})

describe('the symlink case, end to end', () => {
  test('refuses to write through the symlink the old README told people to make', () => {
    const { home } = sandbox('cli-symlink')
    // Reproduce the documented setup: ~/.claude/CLAUDE.md -> a clone's AGENTS.md
    const clone = path.join(tmp, 'cli-symlink', 'clone')
    fs.mkdirSync(clone, { recursive: true })
    const source = path.join(clone, 'AGENTS.md')
    const original = '# The repository source of truth\n'
    fs.writeFileSync(source, original)

    const claudeMd = path.join(home, '.claude', 'CLAUDE.md')
    fs.mkdirSync(path.dirname(claudeMd), { recursive: true })
    fs.symlinkSync(source, claudeMd)

    const out = run(['-g', '-a', 'claude-code', '-y'], { home })
    assert.match(out, /REFUSED|SKIPPED/, 'the run must report the refusal')
    assert.equal(
      fs.readFileSync(source, 'utf8'), original,
      'the clone AGENTS.md must be untouched — this is the data-loss case',
    )
    assert.ok(fs.lstatSync(claudeMd).isSymbolicLink(), 'the link itself must survive')
  })

  test('--replace-symlinks converts the link without touching its target', () => {
    const { home } = sandbox('cli-symlink-replace')
    const clone = path.join(tmp, 'cli-symlink-replace', 'clone')
    fs.mkdirSync(clone, { recursive: true })
    const source = path.join(clone, 'AGENTS.md')
    fs.writeFileSync(source, '# untouched\n')
    const claudeMd = path.join(home, '.claude', 'CLAUDE.md')
    fs.mkdirSync(path.dirname(claudeMd), { recursive: true })
    fs.symlinkSync(source, claudeMd)

    run(['-g', '-a', 'claude-code', '--replace-symlinks', '-y'], { home })
    assert.equal(fs.lstatSync(claudeMd).isSymbolicLink(), false)
    assert.equal(fs.readFileSync(source, 'utf8'), '# untouched\n')
  })
})

describe('dry run and disclosure', () => {
  test('--dry-run writes nothing but prints every path', () => {
    const { home, project } = sandbox('dry-run')
    const out = run(['-p', '-a', 'all', '--dry-run'], { home, cwd: project })
    assert.match(out, /nothing was written/)
    assert.match(out, /\.agents[/\\]skills/)
    assert.ok(!fs.existsSync(path.join(project, '.agents')), 'dry run must not create anything')
  })

  test('the disclosure names the receipt and the undo command', () => {
    const { home, project } = sandbox('disclosure')
    const out = run(['-p', '-a', 'all', '-y'], { home, cwd: project })
    assert.match(out, /receipt:/i)
    assert.match(out, /uninstall/)
  })
})

describe('uninstall', () => {
  test('removes what it installed and restores pre-existing content exactly', () => {
    const { home } = sandbox('uninstall-restore')
    const claudeMd = path.join(home, '.claude', 'CLAUDE.md')
    fs.mkdirSync(path.dirname(claudeMd), { recursive: true })
    const theirs = '# Mine\n\nKeep this.\n'
    fs.writeFileSync(claudeMd, theirs)

    run(['-g', '-a', 'claude-code', '-y'], { home })
    assert.match(fs.readFileSync(claudeMd, 'utf8'), /BEGIN aanyberg/)

    run(['uninstall', '-g'], { home })
    assert.equal(
      fs.readFileSync(claudeMd, 'utf8'), theirs,
      'their file must be restored byte-for-byte',
    )
    assert.ok(!fs.existsSync(path.join(home, '.agents', 'skills', 'git-conventions')))
  })

  test('deletes an instruction file it created outright', () => {
    const { home } = sandbox('uninstall-created')
    run(['-g', '-a', 'codex', '-y'], { home })
    const codexAgents = path.join(home, '.codex', 'AGENTS.md')
    assert.ok(fs.existsSync(codexAgents))
    run(['uninstall', '-g'], { home })
    assert.ok(!fs.existsSync(codexAgents), 'a file we created should not be left behind empty')
  })

  test('never removes a file it did not write', () => {
    const { home, project } = sandbox('uninstall-foreign')
    run(['-p', '-a', 'all', '-y'], { home, cwd: project })

    // A skill someone else put in the same directory.
    const foreign = path.join(project, '.agents', 'skills', 'someone-elses-skill')
    fs.mkdirSync(foreign, { recursive: true })
    fs.writeFileSync(path.join(foreign, 'SKILL.md'), 'not ours')

    run(['uninstall', '-p'], { home, cwd: project })
    assert.ok(fs.existsSync(path.join(foreign, 'SKILL.md')), 'a foreign skill must survive uninstall')
  })

  test('reports plainly when there is nothing to uninstall', () => {
    const { home } = sandbox('uninstall-empty')
    const out = run(['uninstall', '-g'], { home, expectFail: true })
    assert.match(out, /No receipt/)
  })
})

describe('argument handling', () => {
  test('rejects an unknown agent by name and lists the valid ones', () => {
    const { home } = sandbox('bad-agent')
    const out = run(['-g', '-a', 'not-an-agent', '-y'], { home, expectFail: true })
    assert.match(out, /unknown agent/)
    assert.match(out, /claude-code/)
  })

  test('rejects an unknown flag rather than ignoring it', () => {
    const { home } = sandbox('bad-flag')
    const out = run(['--nonsense'], { home, expectFail: true })
    assert.match(out, /unknown option/)
  })

  test('--help exits cleanly', () => {
    const { home } = sandbox('help')
    assert.match(run(['--help'], { home }), /agent-conventions/)
  })
})

describe('uninstall does not take content the installer did not add', () => {
  test('keeps what you appended to a file the installer created', () => {
    const { home } = sandbox('uninstall-appended')
    run(['-g', '-a', 'codex', '-y'], { home })

    // The installer created this file. The user then adds their own notes.
    const codexAgents = path.join(home, '.codex', 'AGENTS.md')
    const mine = '\n# Notes I added later\n\nKeep these.\n'
    fs.appendFileSync(codexAgents, mine)

    run(['uninstall', '-g'], { home })

    assert.ok(fs.existsSync(codexAgents), 'the file must survive — it is no longer only ours')
    const after = fs.readFileSync(codexAgents, 'utf8')
    assert.match(after, /Notes I added later/, 'their content must survive')
    assert.ok(!after.includes('BEGIN aanyberg'), 'our block must be gone')
  })

  test('still deletes a created file that holds nothing but our block', () => {
    const { home } = sandbox('uninstall-only-ours')
    run(['-g', '-a', 'codex', '-y'], { home })
    const codexAgents = path.join(home, '.codex', 'AGENTS.md')
    assert.ok(fs.existsSync(codexAgents))
    run(['uninstall', '-g'], { home })
    assert.ok(!fs.existsSync(codexAgents), 'a file containing only our block should not be left empty')
  })
})
