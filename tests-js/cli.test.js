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
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, describe, test } from 'node:test'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const CLI = path.join(ROOT, 'bin', 'cli.js')

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ac-cli-'))
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
  test('installs portable skills and provider-native agents', () => {
    const { home, project } = sandbox('project-basic')
    run(['-p', '-a', 'all', '-y'], { home, cwd: project })

    const canonical = path.join(project, '.agents', 'skills')
    const claude = path.join(project, '.claude', 'skills')
    assert.ok(fs.existsSync(canonical), '.agents/skills must hold the real files')
    assert.ok(fs.existsSync(claude), '.claude/skills must exist for Claude Code')

    const names = fs.readdirSync(canonical).sort()
    assert.ok(names.length >= 17, `expected the bundled skills, got ${names.length}`)
    assert.ok(names.includes('git-conventions'))

    // Claude's entries are links into the canonical copy, not duplicates.
    const entry = path.join(claude, 'git-conventions')
    assert.ok(fs.lstatSync(entry).isSymbolicLink(), 'Claude entries must be links, not copies')
    assert.ok(path.isAbsolute(fs.readlinkSync(entry)), 'Claude links must use full paths')
    assert.equal(fs.realpathSync(entry), fs.realpathSync(path.join(canonical, 'git-conventions')))
    assert.ok(fs.existsSync(path.join(entry, 'SKILL.md')), 'the link must resolve')

    assert.ok(fs.existsSync(path.join(project, '.claude', 'agents', 'conventions-code-reviewer.md')))
    assert.ok(fs.existsSync(path.join(project, '.codex', 'agents', 'conventions-code-reviewer.toml')))
    assert.ok(fs.existsSync(path.join(project, '.github', 'agents', 'conventions-code-reviewer.agent.md')))
    assert.ok(fs.existsSync(path.join(project, '.opencode', 'agents', 'conventions-code-reviewer.md')))
    assert.ok(fs.existsSync(path.join(project, '.cursor', 'agents', 'conventions-code-reviewer.md')))
    assert.ok(fs.existsSync(path.join(project, '.gemini', 'agents', 'conventions-code-reviewer.md')))
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

  test('skips a dangling Claude skills symlink while installing other components', () => {
    const { home } = sandbox('global-dangling-skills')
    const claudeSkills = path.join(home, '.claude', 'skills')
    const missing = path.join(home, 'missing-skills')
    fs.mkdirSync(path.dirname(claudeSkills), { recursive: true })
    fs.symlinkSync(missing, claudeSkills)

    const output = run(['-g', '-a', 'all', '-y'], { home })

    assert.match(output, /REFUSED without --replace-symlinks/)
    assert.ok(fs.lstatSync(claudeSkills).isSymbolicLink())
    assert.ok(!fs.existsSync(missing), 'the dangling target must remain absent')
    assert.ok(fs.existsSync(path.join(home, '.agents', 'skills', 'git-conventions', 'SKILL.md')))
    assert.ok(fs.existsSync(path.join(home, '.codex', 'agents', 'conventions-code-reviewer.toml')))
    assert.ok(fs.existsSync(path.join(home, '.copilot', 'copilot-instructions.md')))

    const receipt = JSON.parse(fs.readFileSync(path.join(home, '.agent-conventions.json'), 'utf8'))
    assert.equal(receipt.skills.links.length, 0, 'skipped links must not be claimed')
    assert.ok(receipt.skills.dirs.length >= 17, 'canonical skills must remain uninstallable')
  })

  test('skips a dangling canonical skills symlink while installing other components', () => {
    const { home } = sandbox('global-dangling-canonical')
    const canonical = path.join(home, '.agents', 'skills')
    const missing = path.join(home, 'missing-canonical-skills')
    fs.mkdirSync(path.dirname(canonical), { recursive: true })
    fs.symlinkSync(missing, canonical)

    const output = run(['-g', '-a', 'all', '-y'], { home })

    assert.match(output, /REFUSED without --replace-symlinks/)
    assert.ok(fs.lstatSync(canonical).isSymbolicLink())
    assert.ok(!fs.existsSync(missing), 'the dangling target must remain absent')
    assert.ok(fs.existsSync(path.join(home, '.codex', 'agents', 'conventions-code-reviewer.toml')))
    assert.ok(fs.existsSync(path.join(home, '.copilot', 'copilot-instructions.md')))
    const receipt = JSON.parse(fs.readFileSync(path.join(home, '.agent-conventions.json'), 'utf8'))
    assert.equal(receipt.skills, null, 'a skipped fresh skills install must claim nothing')
  })

  test('--replace-symlinks converts the canonical skills root without touching its target', () => {
    const { home } = sandbox('global-replace-canonical')
    const foreign = path.join(home, 'foreign-canonical')
    const foreignSkill = path.join(foreign, 'git-conventions')
    fs.mkdirSync(foreignSkill, { recursive: true })
    fs.writeFileSync(path.join(foreignSkill, 'SKILL.md'), 'foreign skill')
    fs.writeFileSync(path.join(foreignSkill, 'notes.md'), 'untouched')
    const canonical = path.join(home, '.agents', 'skills')
    fs.mkdirSync(path.dirname(canonical), { recursive: true })
    fs.symlinkSync(foreign, canonical)

    run(['-g', '-a', 'codex', '-c', 'skills', '--replace-symlinks', '-y'], { home })

    assert.equal(fs.lstatSync(canonical).isSymbolicLink(), false)
    assert.ok(fs.existsSync(path.join(canonical, 'git-conventions', 'SKILL.md')))
    assert.equal(fs.readFileSync(path.join(foreignSkill, 'SKILL.md'), 'utf8'), 'foreign skill')
    assert.equal(fs.readFileSync(path.join(foreignSkill, 'notes.md'), 'utf8'), 'untouched')
  })

  test('--replace-symlinks converts the Claude skills root without touching its target', () => {
    const { home } = sandbox('global-replace-skills')
    const foreign = path.join(home, 'foreign-skills')
    fs.mkdirSync(foreign)
    fs.writeFileSync(path.join(foreign, 'keep.txt'), 'untouched')
    const claudeSkills = path.join(home, '.claude', 'skills')
    fs.mkdirSync(path.dirname(claudeSkills), { recursive: true })
    fs.symlinkSync(foreign, claudeSkills)

    run(['-g', '-a', 'claude-code', '-c', 'skills', '--replace-symlinks', '-y'], { home })

    assert.equal(fs.lstatSync(claudeSkills).isSymbolicLink(), false)
    assert.ok(fs.lstatSync(path.join(claudeSkills, 'git-conventions')).isSymbolicLink())
    assert.equal(fs.readFileSync(path.join(foreign, 'keep.txt'), 'utf8'), 'untouched')
    assert.ok(!fs.existsSync(path.join(foreign, 'git-conventions')))
  })

  test('refuses to write generated agents through a provider-directory symlink', () => {
    const { home } = sandbox('global-agent-directory-symlink')
    const foreign = path.join(home, 'foreign-agents')
    fs.mkdirSync(foreign)
    fs.writeFileSync(path.join(foreign, 'keep.txt'), 'untouched')
    const claudeAgents = path.join(home, '.claude', 'agents')
    fs.mkdirSync(path.dirname(claudeAgents), { recursive: true })
    fs.symlinkSync(foreign, claudeAgents)

    const output = run(['-g', '-a', 'claude-code', '-c', 'agents', '-y'], { home })

    assert.match(output, /REFUSED without --replace-symlinks/)
    assert.ok(fs.lstatSync(claudeAgents).isSymbolicLink())
    assert.deepEqual(fs.readdirSync(foreign), ['keep.txt'])
  })

  test('preserves agent receipts and stale files when a provider-directory symlink is refused', () => {
    const { home } = sandbox('global-agent-directory-receipt')
    run(['-g', '-a', 'claude-code', '-c', 'agents', '-y'], { home })
    const receiptPath = path.join(home, '.agent-conventions.json')
    const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'))
    const claudeAgents = path.join(home, '.claude', 'agents')
    const foreign = path.join(home, 'foreign-agents')
    fs.renameSync(claudeAgents, foreign)
    fs.symlinkSync(foreign, claudeAgents)
    const stale = path.join(claudeAgents, 'conventions-retired.md')
    const content = 'retired'
    fs.writeFileSync(stale, content)
    receipt.agents.push({
      provider: 'claude-code',
      name: 'conventions-retired',
      file: stale,
      sha256: crypto.createHash('sha256').update(content).digest('hex'),
    })
    fs.writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + '\n')

    const output = run(['-g', '-a', 'claude-code', '-c', 'agents', '-y'], { home })

    assert.doesNotMatch(output, /remove\s+.*conventions-retired\.md/)
    assert.ok(fs.existsSync(path.join(foreign, 'conventions-retired.md')))
    const updated = JSON.parse(fs.readFileSync(receiptPath, 'utf8'))
    assert.equal(updated.agents.filter((entry) => entry.provider === 'claude-code').length, 7)
  })

  test('--replace-symlinks converts an agent directory without touching its target', () => {
    const { home } = sandbox('global-replace-agent-directory')
    const foreign = path.join(home, 'foreign-agents')
    fs.mkdirSync(foreign)
    fs.writeFileSync(path.join(foreign, 'keep.txt'), 'untouched')
    const claudeAgents = path.join(home, '.claude', 'agents')
    fs.mkdirSync(path.dirname(claudeAgents), { recursive: true })
    fs.symlinkSync(foreign, claudeAgents)

    run(['-g', '-a', 'claude-code', '-c', 'agents', '--replace-symlinks', '-y'], { home })

    assert.equal(fs.lstatSync(claudeAgents).isSymbolicLink(), false)
    assert.ok(fs.existsSync(path.join(claudeAgents, 'conventions-code-reviewer.md')))
    assert.deepEqual(fs.readdirSync(foreign), ['keep.txt'])
  })

  test('skips a Claude skills file collision while installing other components', () => {
    const { home } = sandbox('global-skills-file')
    const claudeSkills = path.join(home, '.claude', 'skills')
    fs.mkdirSync(path.dirname(claudeSkills), { recursive: true })
    fs.writeFileSync(claudeSkills, 'foreign')

    const output = run(['-g', '-a', 'all', '-y'], { home })

    assert.match(output, /REFUSED path conflicts/)
    assert.match(output, /a file exists here/)
    assert.doesNotMatch(output, /REFUSED without --replace-symlinks/)
    assert.equal(fs.readFileSync(claudeSkills, 'utf8'), 'foreign')
    assert.ok(fs.existsSync(path.join(home, '.agents', 'skills', 'git-conventions', 'SKILL.md')))
    assert.ok(fs.existsSync(path.join(home, '.codex', 'agents', 'conventions-code-reviewer.toml')))
    const receipt = JSON.parse(fs.readFileSync(path.join(home, '.agent-conventions.json'), 'utf8'))
    assert.equal(receipt.skills.links.length, 0)
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

  test('an agents-only refresh preserves other component receipts', () => {
    const { home } = sandbox('global-partial-refresh')
    run(['-g', '-a', 'claude-code', '-y'], { home })
    run(['-g', '-a', 'claude-code', '-c', 'agents', '-y'], { home })

    const receipt = JSON.parse(fs.readFileSync(path.join(home, '.agent-conventions.json'), 'utf8'))
    assert.ok(receipt.skills?.dirs.length, 'skills ownership must survive a partial refresh')
    assert.ok(receipt.instructions.length, 'instruction ownership must survive a partial refresh')

    run(['uninstall', '-g'], { home })
    assert.ok(!fs.existsSync(path.join(home, '.agents', 'skills', 'git-conventions')))
    assert.ok(!fs.existsSync(path.join(home, '.claude', 'CLAUDE.md')))
  })

  test('a skills refresh removes obsolete paths recorded by the previous receipt', () => {
    const { home, project } = sandbox('stale-skill')
    run(['-p', '-a', 'codex', '-c', 'skills', '-y'], { home, cwd: project })

    const receiptPath = path.join(project, '.agent-conventions.json')
    const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'))
    const stale = path.join(project, '.agents', 'skills', 'retired-skill')
    fs.mkdirSync(stale, { recursive: true })
    fs.writeFileSync(path.join(stale, 'SKILL.md'), 'retired')
    receipt.skills.dirs.push(stale)
    fs.writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + '\n')

    run(['-p', '-a', 'codex', '-c', 'skills', '-y'], { home, cwd: project })
    assert.ok(!fs.existsSync(stale), 'an obsolete package-owned skill path must be removed')
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
    assert.match(out, /\.codex[/\\]agents/)
    assert.ok(!fs.existsSync(path.join(project, '.agents')), 'dry run must not create anything')
  })

  test('--dry-run describes an allowed agent-directory symlink replacement', () => {
    const { home } = sandbox('dry-run-replace-agent-directory')
    const foreign = path.join(home, 'foreign-agents')
    const claudeAgents = path.join(home, '.claude', 'agents')
    fs.mkdirSync(foreign, { recursive: true })
    fs.mkdirSync(path.dirname(claudeAgents), { recursive: true })
    fs.symlinkSync(foreign, claudeAgents)

    const output = run([
      '-g', '-a', 'claude-code', '-c', 'agents', '--replace-symlinks', '--dry-run',
    ], { home })

    assert.match(output, /replace\s+.*\.claude[/\\]agents/)
    assert.match(output, /create\s+.*conventions-code-reviewer\.md/)
    assert.doesNotMatch(output, /REFUSED without --replace-symlinks/)
    assert.ok(fs.lstatSync(claudeAgents).isSymbolicLink(), 'dry run must leave the link unchanged')
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

  test('uninstall refuses to remove skills through a replaced canonical-root symlink', () => {
    const { home } = sandbox('uninstall-replaced-canonical')
    run(['-g', '-a', 'all', '-y'], { home })

    const canonical = path.join(home, '.agents', 'skills')
    fs.rmSync(canonical, { recursive: true })
    const foreign = path.join(home, 'foreign-after-install')
    const foreignSkill = path.join(foreign, 'git-conventions')
    fs.mkdirSync(foreignSkill, { recursive: true })
    fs.writeFileSync(path.join(foreignSkill, 'SKILL.md'), 'foreign skill')
    fs.writeFileSync(path.join(foreignSkill, 'notes.md'), 'untouched')
    fs.symlinkSync(foreign, canonical)

    run(['uninstall', '-g'], { home })

    assert.equal(fs.readFileSync(path.join(foreignSkill, 'SKILL.md'), 'utf8'), 'foreign skill')
    assert.equal(fs.readFileSync(path.join(foreignSkill, 'notes.md'), 'utf8'), 'untouched')
  })

  test('preserves a generated agent modified after installation', () => {
    const { home, project } = sandbox('uninstall-modified-agent')
    run(['-p', '-a', 'codex', '-c', 'agents', '-y'], { home, cwd: project })
    const agent = path.join(project, '.codex', 'agents', 'conventions-code-reviewer.toml')
    fs.appendFileSync(agent, '\n# user note\n')

    const update = run(['-p', '-a', 'codex', '-c', 'agents', '-y'], { home, cwd: project })
    assert.match(update, /REFUSED/)
    assert.match(fs.readFileSync(agent, 'utf8'), /user note/)

    run(['uninstall', '-p'], { home, cwd: project })
    assert.ok(fs.existsSync(agent), 'a modified generated agent must survive uninstall')
    assert.match(fs.readFileSync(agent, 'utf8'), /user note/)
  })

  test('does not remove generated agents through a provider-directory symlink', () => {
    const { home } = sandbox('uninstall-agent-directory-symlink')
    run(['-g', '-a', 'claude-code', '-c', 'agents', '-y'], { home })
    const claudeAgents = path.join(home, '.claude', 'agents')
    const foreign = path.join(home, 'foreign-agents')
    fs.renameSync(claudeAgents, foreign)
    fs.symlinkSync(foreign, claudeAgents)

    run(['uninstall', '-g'], { home })

    assert.ok(
      fs.existsSync(path.join(foreign, 'conventions-code-reviewer.md')),
      'uninstall must not remove files through a symlinked provider directory',
    )
  })

  test('refuses a foreign agent collision and never claims it in the receipt', () => {
    const { home, project } = sandbox('foreign-agent')
    const agent = path.join(project, '.codex', 'agents', 'conventions-code-reviewer.toml')
    fs.mkdirSync(path.dirname(agent), { recursive: true })
    fs.writeFileSync(agent, 'foreign')

    const output = run(['-p', '-a', 'codex', '-c', 'agents', '-y'], { home, cwd: project })
    assert.match(output, /REFUSED/)
    assert.equal(fs.readFileSync(agent, 'utf8'), 'foreign')

    run(['uninstall', '-p'], { home, cwd: project })
    assert.equal(fs.readFileSync(agent, 'utf8'), 'foreign')
  })

  test('removes a stale generated agent during an update', () => {
    const { home, project } = sandbox('stale-agent')
    run(['-p', '-a', 'codex', '-c', 'agents', '-y'], { home, cwd: project })

    const receiptPath = path.join(project, '.agent-conventions.json')
    const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'))
    const stale = path.join(project, '.codex', 'agents', 'conventions-retired.toml')
    const content = 'retired'
    fs.writeFileSync(stale, content)
    receipt.agents.push({
      provider: 'codex',
      name: 'conventions-retired',
      file: stale,
      sha256: crypto.createHash('sha256').update(content).digest('hex'),
    })
    fs.writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + '\n')

    run(['-p', '-a', 'codex', '-c', 'agents', '-y'], { home, cwd: project })
    assert.ok(!fs.existsSync(stale), 'a byte-identical stale managed agent must be removed')
    const updated = JSON.parse(fs.readFileSync(receiptPath, 'utf8'))
    assert.ok(!updated.agents.some((entry) => entry.file === stale), 'stale entry must leave the receipt')
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

  test('rejects an unknown component', () => {
    const { home } = sandbox('bad-component')
    const out = run(['-g', '-c', 'widgets', '-y'], { home, expectFail: true })
    assert.match(out, /unknown component/)
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
