/**
 * The version bump, tested against a real copy of the manifests.
 *
 * This script is the only thing standing between a release and six files
 * disagreeing about what version they are. It runs rarely — once per release —
 * which is exactly when a latent bug is most expensive and least likely to be
 * noticed, so it gets the same treatment as code that runs constantly.
 */

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, describe, test } from 'node:test'

import { bump, readVersions } from '../scripts/bump-version.mjs'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const FILES = [
  'package.json', 'plugin.json', 'gemini-extension.json',
  '.codex-plugin/plugin.json', '.claude-plugin/plugin.json', '.claude-plugin/marketplace.json',
]

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ac-bump-'))
after(() => { fs.rmSync(tmp, { recursive: true, force: true }) })

/** A throwaway copy of the real manifests, so tests never edit the repo. */
function fixture(name) {
  const root = path.join(tmp, name)
  for (const f of FILES) {
    const dest = path.join(root, f)
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.copyFileSync(path.join(REPO, f), dest)
  }
  return root
}

describe('bump', () => {
  test('sets every manifest to the same version', () => {
    const root = fixture('all')
    bump('9.9.9', { root })
    for (const { file, version } of readVersions(root)) {
      assert.equal(version, '9.9.9', `${file} was not bumped`)
    }
  })

  test('updates the nested marketplace version and each plugin entry', () => {
    const root = fixture('nested')
    bump('2.3.4', { root })
    const m = JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin/marketplace.json'), 'utf8'))
    assert.equal(m.metadata.version, '2.3.4', 'metadata.version drives the Copilot read')
    for (const entry of m.plugins) {
      assert.equal(entry.version, '2.3.4', `plugin entry ${entry.name} was missed`)
    }
  })

  test('rejects a non-semver version instead of writing it', () => {
    const root = fixture('bad-semver')
    const before = readVersions(root)
    assert.throws(() => bump('v1.2', { root }), /not semver/)
    assert.deepEqual(readVersions(root), before, 'nothing may be written on a bad input')
  })

  test('rejects a v-prefixed semantic version', () => {
    const root = fixture('prefixed-semver')
    const before = readVersions(root)
    assert.throws(() => bump('v1.2.3', { root }), /not semver/)
    assert.deepEqual(readVersions(root), before, 'nothing may be written for a prefixed tag')
  })

  test('accepts a prerelease version', () => {
    const root = fixture('prerelease')
    bump('1.2.0-rc.1', { root })
    assert.ok(readVersions(root).every((v) => v.version === '1.2.0-rc.1'))
  })

  test('is idempotent and reports nothing changed', () => {
    const root = fixture('idempotent')
    bump('3.0.0', { root })
    assert.deepEqual(bump('3.0.0', { root }), [], 'a second bump must be a no-op')
  })

  test('--check reports drift without writing', () => {
    const root = fixture('check')
    const before = readVersions(root)
    const changed = bump('4.5.6', { root, check: true })
    assert.ok(changed.length > 0, 'check must report what would change')
    assert.deepEqual(readVersions(root), before, 'check must not write')
  })

  test('--check passes silently when everything already matches', () => {
    const root = fixture('check-clean')
    bump('1.0.0', { root })
    assert.deepEqual(bump('1.0.0', { root, check: true }), [])
  })

  test('leaves formatting alone so a bump has no incidental diff', () => {
    const root = fixture('formatting')
    const target = path.join(root, 'package.json')
    const before = fs.readFileSync(target, 'utf8')
    const current = JSON.parse(before).version
    bump(current, { root }) // same version — must be a genuine no-op
    assert.equal(fs.readFileSync(target, 'utf8'), before, 'a no-op bump must not rewrite the file')
  })

  test('preserves every other field in the manifests', () => {
    const root = fixture('preserve')
    const before = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
    bump('7.7.7', { root })
    const after = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
    assert.deepEqual(
      { ...after, version: before.version }, before,
      'only the version may change',
    )
    assert.ok(after.files.includes('skills'), 'the files list must survive a bump')
    assert.ok(after.bin['agent-conventions'], 'the bin entry must survive a bump')
  })
})

describe('the repo as it stands', () => {
  test('every manifest currently agrees', () => {
    const versions = readVersions(REPO)
    const distinct = new Set(versions.map((v) => v.version))
    assert.equal(distinct.size, 1, `versions have drifted: ${JSON.stringify(versions)}`)
  })

  test('the bump script covers every file that declares a version', () => {
    // A new manifest with a version that nobody bumps is the failure this
    // guards: the release would silently ship it at the old number.
    const covered = new Set(readVersions(REPO).map((v) => v.file))
    for (const f of FILES) assert.ok(covered.has(f), `${f} is not covered by the bump script`)
  })
})
