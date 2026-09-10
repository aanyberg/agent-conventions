/**
 * The write layer, with the symlink guard first.
 *
 * That guard is the only failure mode in this installer that destroys data
 * rather than merely annoying someone: the previous README told people to run
 * `ln -s /path/to/agent-conventions/AGENTS.md ~/.claude/CLAUDE.md`, and an
 * append through that link writes into their clone of this repository. So the
 * first test asserts the source file is byte-identical afterwards, not merely
 * that an error was raised.
 */

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { after, describe, test } from 'node:test'

import {
  applyInstructionWrite, applyManagedFileWrite, classify, contentDigest, hasBlock,
  installSkill, linkSkill, planInstructionWrite, planManagedFileWrite,
  planSkillLinkDirectory, prepareSkillLinkDirectory, removeBlock,
  removeManagedFile, renderBlock, upsertBlock,
} from '../src/write.js'
import { MARKER_BEGIN, MARKER_END, parseAgentSelection } from '../src/targets.js'

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ac-test-'))
after(() => { fs.rmSync(tmp, { recursive: true, force: true }) })

const scratch = (name) => {
  const dir = path.join(tmp, name)
  fs.mkdirSync(dir, { recursive: true })
  return dir
}

describe('the symlink guard', () => {
  test('refuses to write through a symlink, leaving the target byte-identical', () => {
    const dir = scratch('symlink-guard')
    const source = path.join(dir, 'AGENTS.md')
    const original = '# My real instructions\n\nDo not clobber me.\n'
    fs.writeFileSync(source, original)

    const link = path.join(dir, 'CLAUDE.md')
    fs.symlinkSync(source, link)

    const plan = planInstructionWrite(link)
    assert.equal(plan.action, 'refuse-symlink')

    assert.throws(
      () => applyInstructionWrite(plan, 'INJECTED CONTENT'),
      /is a symlink/,
      'must refuse rather than follow the link',
    )

    assert.equal(
      fs.readFileSync(source, 'utf8'), original,
      'the symlink target must be untouched — this is the data-loss case',
    )
  })

  test('--replace-symlinks replaces the link itself, never the target', () => {
    const dir = scratch('symlink-replace')
    const source = path.join(dir, 'AGENTS.md')
    const original = '# Source of truth\n'
    fs.writeFileSync(source, original)
    const link = path.join(dir, 'CLAUDE.md')
    fs.symlinkSync(source, link)

    const plan = planInstructionWrite(link)
    const result = applyInstructionWrite(plan, 'NEW CONTENT', { replaceSymlinks: true })

    assert.equal(result.applied, 'replaced-symlink')
    assert.equal(fs.lstatSync(link).isSymbolicLink(), false, 'link must become a real file')
    assert.match(fs.readFileSync(link, 'utf8'), /NEW CONTENT/)
    assert.equal(
      fs.readFileSync(source, 'utf8'), original,
      'the file the link pointed at must still be untouched',
    )
  })

  test('reports where a dangling symlink pointed rather than throwing', () => {
    const dir = scratch('symlink-dangling')
    const link = path.join(dir, 'CLAUDE.md')
    fs.symlinkSync(path.join(dir, 'gone.md'), link)
    const at = classify(link)
    assert.equal(at.kind, 'symlink')
    assert.match(at.resolved, /gone\.md$/)
  })

  test('refuses when a directory occupies the target path', () => {
    const dir = scratch('is-a-dir')
    const target = path.join(dir, 'CLAUDE.md')
    fs.mkdirSync(target)
    const plan = planInstructionWrite(target)
    assert.equal(plan.action, 'refuse')
    assert.throws(() => applyInstructionWrite(plan, 'x'), /directory/)
  })
})

describe('marker blocks', () => {
  test('appends to an existing file without disturbing its content', () => {
    const existing = '# Their notes\n\nSomething they wrote.\n'
    const result = upsertBlock(existing, 'ours')
    assert.ok(result.startsWith(existing), 'existing content must survive verbatim')
    assert.ok(hasBlock(result))
  })

  test('replaces only between the markers on a second run', () => {
    const first = upsertBlock('# Theirs\n', 'version one')
    const second = upsertBlock(first, 'version two')
    assert.ok(second.includes('version two'))
    assert.ok(!second.includes('version one'), 'stale content must be replaced')
    assert.ok(second.startsWith('# Theirs\n'), 'their content must survive an update')
    assert.equal(second.match(new RegExp(MARKER_BEGIN, 'g')).length, 1, 'must not duplicate the block')
  })

  test('is idempotent', () => {
    const once = upsertBlock('# Theirs\n', 'content')
    assert.equal(upsertBlock(once, 'content'), once)
  })

  test('removeBlock restores the file to its pre-install content', () => {
    const original = '# Theirs\n\nTheir paragraph.\n'
    const installed = upsertBlock(original, 'ours')
    assert.equal(removeBlock(installed), original)
  })

  test('removeBlock empties a file we created outright', () => {
    assert.equal(removeBlock(renderBlock('only ours')), '')
  })

  test('removeBlock is a no-op on a file that has no block', () => {
    const text = '# Untouched\n'
    assert.equal(removeBlock(text), text)
  })

  test('refuses to edit a file whose markers are inverted', () => {
    const broken = `${MARKER_END}\nstuff\n${MARKER_BEGIN}\n`
    assert.throws(() => upsertBlock(broken, 'x'), /out of order/)
  })

  test('preserves markdown that itself contains marker-like text', () => {
    const tricky = '# Doc\n\nWe use `<!-- BEGIN something-else -->` in our docs.\n'
    const result = upsertBlock(tricky, 'ours')
    assert.ok(result.includes('BEGIN something-else'), 'unrelated comment must survive')
    assert.equal(removeBlock(result), tricky)
  })
})

describe('planning an instruction write', () => {
  test('distinguishes create from append from update', () => {
    const dir = scratch('plan-states')
    const missing = path.join(dir, 'a.md')
    assert.equal(planInstructionWrite(missing).action, 'create')

    const plain = path.join(dir, 'b.md')
    fs.writeFileSync(plain, '# theirs\n')
    assert.equal(planInstructionWrite(plain).action, 'append')

    const withBlock = path.join(dir, 'c.md')
    fs.writeFileSync(withBlock, upsertBlock('# theirs\n', 'ours'))
    assert.equal(planInstructionWrite(withBlock).action, 'update')
  })

  test('an append reports how many of their lines are kept', () => {
    const dir = scratch('plan-count')
    const file = path.join(dir, 'd.md')
    fs.writeFileSync(file, 'one\ntwo\nthree\n')
    assert.match(planInstructionWrite(file).detail, /3 existing lines kept/)
  })
})

describe('skills', () => {
  test('installSkill replaces a previous copy rather than merging into it', () => {
    const dir = scratch('skill-replace')
    const src = path.join(dir, 'src', 'demo')
    fs.mkdirSync(src, { recursive: true })
    fs.writeFileSync(path.join(src, 'SKILL.md'), 'new')

    const dest = path.join(dir, 'dest', 'demo')
    fs.mkdirSync(dest, { recursive: true })
    fs.writeFileSync(path.join(dest, 'STALE.md'), 'left over from an older version')

    installSkill(src, dest)
    assert.equal(fs.readFileSync(path.join(dest, 'SKILL.md'), 'utf8'), 'new')
    assert.ok(!fs.existsSync(path.join(dest, 'STALE.md')), 'stale files must not survive')
  })

  test('installSkill preserves the previous copy when staging fails', (t) => {
    const dir = scratch('skill-stage-failure')
    const src = path.join(dir, 'src', 'demo')
    fs.mkdirSync(src, { recursive: true })
    fs.writeFileSync(path.join(src, 'SKILL.md'), 'new')

    const dest = path.join(dir, 'dest', 'demo')
    fs.mkdirSync(dest, { recursive: true })
    fs.writeFileSync(path.join(dest, 'SKILL.md'), 'old')
    fs.writeFileSync(path.join(dest, 'user-note.md'), 'keep')

    const copy = fs.cpSync
    fs.cpSync = () => { throw new Error('copy failed') }
    t.after(() => { fs.cpSync = copy })
    assert.throws(() => installSkill(src, dest))
    assert.equal(fs.readFileSync(path.join(dest, 'SKILL.md'), 'utf8'), 'old')
    assert.equal(fs.readFileSync(path.join(dest, 'user-note.md'), 'utf8'), 'keep')
  })

  test('installSkill preserves the previous copy when promotion rollback fails', (t) => {
    const dir = scratch('skill-rollback-failure')
    const src = path.join(dir, 'src', 'demo')
    fs.mkdirSync(src, { recursive: true })
    fs.writeFileSync(path.join(src, 'SKILL.md'), 'new')

    const dest = path.join(dir, 'dest', 'demo')
    fs.mkdirSync(dest, { recursive: true })
    fs.writeFileSync(path.join(dest, 'SKILL.md'), 'old')

    const rename = fs.renameSync
    fs.renameSync = (from, to) => {
      if (to === dest) {
        fs.mkdirSync(dest)
        throw new Error('promotion failed')
      }
      rename(from, to)
    }
    t.after(() => { fs.renameSync = rename })

    assert.throws(
      () => installSkill(src, dest),
      /previous copy remains at/,
    )

    const backupParent = fs.readdirSync(path.dirname(dest))
      .find((name) => name.startsWith('.demo-'))
    assert.ok(backupParent, 'the staging directory must remain for recovery')
    assert.equal(
      fs.readFileSync(path.join(path.dirname(dest), backupParent, 'previous', 'SKILL.md'), 'utf8'),
      'old',
    )
  })

  describe('generated managed files', () => {
    test('refuses a foreign file and preserves it', () => {
      const dir = scratch('managed-foreign')
      const file = path.join(dir, 'agent.md')
      fs.writeFileSync(file, 'theirs')
      const plan = planManagedFileWrite(file, 'ours')
      assert.equal(plan.action, 'refuse')
      assert.throws(() => applyManagedFileWrite(plan, 'ours'), /unowned/)
      assert.equal(fs.readFileSync(file, 'utf8'), 'theirs')
    })

    test('updates an owned unchanged file', () => {
      const dir = scratch('managed-update')
      const file = path.join(dir, 'agent.md')
      fs.writeFileSync(file, 'old')
      const plan = planManagedFileWrite(file, 'new', { file, sha256: contentDigest('old') })
      assert.equal(plan.action, 'update')
      applyManagedFileWrite(plan, 'new')
      assert.equal(fs.readFileSync(file, 'utf8'), 'new')
    })

    test('preserves a managed file modified by the user', () => {
      const dir = scratch('managed-modified')
      const file = path.join(dir, 'agent.md')
      fs.writeFileSync(file, 'user edit')
      const receipt = { file, sha256: contentDigest('installed') }
      assert.equal(planManagedFileWrite(file, 'updated', receipt).action, 'refuse')
      const removed = removeManagedFile(receipt)
      assert.equal(removed.removed, false)
      assert.equal(removed.reason, 'file was modified')
      assert.equal(fs.readFileSync(file, 'utf8'), 'user edit')
    })

    test('removes a byte-identical managed file', () => {
      const dir = scratch('managed-remove')
      const file = path.join(dir, 'agent.md')
      fs.writeFileSync(file, 'installed')
      assert.equal(removeManagedFile({ file, sha256: contentDigest('installed') }).removed, true)
      assert.equal(fs.existsSync(file), false)
    })
  })

  test('linkSkill creates an absolute symlink that resolves', () => {
    const dir = scratch('skill-link')
    const canonical = path.join(dir, '.agents', 'skills', 'demo')
    fs.mkdirSync(canonical, { recursive: true })
    fs.writeFileSync(path.join(canonical, 'SKILL.md'), 'body')

    const link = path.join(dir, '.claude', 'skills', 'demo')
    const mode = linkSkill(canonical, link)

    assert.equal(mode, 'symlink')
    assert.equal(fs.readlinkSync(link), canonical)
    assert.ok(path.isAbsolute(fs.readlinkSync(link)))
    assert.equal(fs.readFileSync(path.join(link, 'SKILL.md'), 'utf8'), 'body')
  })

  test('linkSkill --copy produces an independent copy', () => {
    const dir = scratch('skill-copy')
    const canonical = path.join(dir, 'canonical', 'demo')
    fs.mkdirSync(canonical, { recursive: true })
    fs.writeFileSync(path.join(canonical, 'SKILL.md'), 'body')

    const link = path.join(dir, 'copy', 'demo')
    assert.equal(linkSkill(canonical, link, { copy: true }), 'copy')
    assert.equal(fs.lstatSync(link).isSymbolicLink(), false)
    assert.equal(fs.readFileSync(path.join(link, 'SKILL.md'), 'utf8'), 'body')
  })

  test('linkSkill refuses to write through a provider-directory symlink', () => {
    const dir = scratch('skill-parent-symlink')
    const canonical = path.join(dir, 'canonical', 'demo')
    fs.mkdirSync(canonical, { recursive: true })
    fs.writeFileSync(path.join(canonical, 'SKILL.md'), 'body')

    const foreign = path.join(dir, 'foreign')
    fs.mkdirSync(foreign)
    fs.writeFileSync(path.join(foreign, 'keep.txt'), 'untouched')
    fs.mkdirSync(path.join(foreign, 'demo'))
    fs.writeFileSync(path.join(foreign, 'demo', 'SKILL.md'), 'foreign skill')
    const provider = path.join(dir, '.claude', 'skills')
    fs.mkdirSync(path.dirname(provider), { recursive: true })
    fs.symlinkSync(foreign, provider)

    assert.throws(
      () => linkSkill(canonical, path.join(provider, 'demo')),
      /refusing to write through/,
    )
    assert.equal(fs.readFileSync(path.join(foreign, 'keep.txt'), 'utf8'), 'untouched')
    assert.equal(
      fs.readFileSync(path.join(foreign, 'demo', 'SKILL.md'), 'utf8'),
      'foreign skill',
    )
  })

  test('installSkill refuses to replace content through a canonical-directory symlink', () => {
    const dir = scratch('canonical-parent-symlink')
    const source = path.join(dir, 'source', 'demo')
    fs.mkdirSync(source, { recursive: true })
    fs.writeFileSync(path.join(source, 'SKILL.md'), 'bundled skill')

    const foreign = path.join(dir, 'foreign')
    const foreignSkill = path.join(foreign, 'demo')
    fs.mkdirSync(foreignSkill, { recursive: true })
    fs.writeFileSync(path.join(foreignSkill, 'SKILL.md'), 'foreign skill')
    fs.writeFileSync(path.join(foreignSkill, 'notes.md'), 'keep me')
    const canonical = path.join(dir, '.agents', 'skills')
    fs.mkdirSync(path.dirname(canonical), { recursive: true })
    fs.symlinkSync(foreign, canonical)

    assert.throws(
      () => installSkill(source, path.join(canonical, 'demo')),
      /refusing to write through/,
    )
    assert.equal(fs.readFileSync(path.join(foreignSkill, 'SKILL.md'), 'utf8'), 'foreign skill')
    assert.equal(fs.readFileSync(path.join(foreignSkill, 'notes.md'), 'utf8'), 'keep me')
  })

  test('explicitly replaces a provider-directory symlink without touching its target', () => {
    const dir = scratch('skill-parent-replace')
    const foreign = path.join(dir, 'foreign')
    fs.mkdirSync(foreign)
    fs.writeFileSync(path.join(foreign, 'keep.txt'), 'untouched')
    const provider = path.join(dir, '.claude', 'skills')
    fs.mkdirSync(path.dirname(provider), { recursive: true })
    fs.symlinkSync(foreign, provider)

    const plan = planSkillLinkDirectory(provider)
    assert.equal(plan.action, 'refuse-symlink')
    const result = prepareSkillLinkDirectory(plan, { replaceSymlinks: true })

    assert.equal(result.applied, 'replaced-symlink')
    assert.equal(fs.lstatSync(provider).isSymbolicLink(), false)
    assert.equal(fs.readFileSync(path.join(foreign, 'keep.txt'), 'utf8'), 'untouched')
  })
})

describe('agent selection from the global prompt', () => {
  const ALL = ['claude-code', 'codex', 'github-copilot', 'opencode', 'cursor', 'gemini-cli']
  const preset = ['claude-code', 'codex']

  test('"a" and "all" both select every agent', () => {
    for (const answer of ['a', 'A', 'all', 'ALL', ' all ']) {
      assert.deepEqual(parseAgentSelection(answer, { preset }).agents, ALL, `failed for ${JSON.stringify(answer)}`)
    }
  })

  test('an empty answer takes the preset', () => {
    const result = parseAgentSelection('', { preset })
    assert.deepEqual(result.agents, preset)
    assert.equal(result.reason, 'preset')
  })

  test('numbers map to agents, in any separator style', () => {
    assert.deepEqual(parseAgentSelection('1 3', { preset }).agents, ['claude-code', 'github-copilot'])
    assert.deepEqual(parseAgentSelection('1,3', { preset }).agents, ['claude-code', 'github-copilot'])
    assert.deepEqual(parseAgentSelection('1, 3', { preset }).agents, ['claude-code', 'github-copilot'])
  })

  test('duplicates collapse', () => {
    assert.deepEqual(parseAgentSelection('2 2 2', { preset }).agents, ['codex'])
  })

  test('an unrecognised answer falls back rather than selecting nothing', () => {
    // Installing for no agents is never what someone meant by a typo.
    for (const answer of ['x', '99', '0', '-1']) {
      const result = parseAgentSelection(answer, { preset })
      assert.deepEqual(result.agents, preset, `"${answer}" should fall back`)
      assert.equal(result.reason, 'unrecognised')
    }
  })

  test('out-of-range numbers are dropped but valid ones still count', () => {
    assert.deepEqual(parseAgentSelection('1 99', { preset }).agents, ['claude-code'])
  })
})
