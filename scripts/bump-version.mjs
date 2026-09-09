#!/usr/bin/env node
/**
 * Set the release version in every manifest that declares one.
 *
 * Six files state a version, and a release that updates five ships an
 * inconsistent set that no single tool can detect — a Gemini user and a Codex
 * user would see different versions of the same release. `tests/
 * test_install_manifests.py::test_every_manifest_declares_the_same_version`
 * fails on that, and this script is how you avoid tripping it by hand.
 *
 * Written in Node rather than shell on purpose: these are JSON documents, and
 * editing JSON with `sed` is precisely the class of fragility the repo's
 * BSD/GNU portability rules exist to prevent. `JSON.parse` either round-trips
 * or throws.
 *
 *   node scripts/bump-version.mjs 1.2.0
 *   node scripts/bump-version.mjs 1.2.0 --check    # verify only, write nothing
 */

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

// Each entry says how to read and how to write the version for that file, so a
// manifest with a nested version needs no special-casing at the call site.
const MANIFESTS = [
  { file: 'package.json', get: (d) => d.version, set: (d, v) => { d.version = v } },
  { file: 'plugin.json', get: (d) => d.version, set: (d, v) => { d.version = v } },
  { file: 'gemini-extension.json', get: (d) => d.version, set: (d, v) => { d.version = v } },
  { file: '.codex-plugin/plugin.json', get: (d) => d.version, set: (d, v) => { d.version = v } },
  { file: '.claude-plugin/plugin.json', get: (d) => d.version, set: (d, v) => { d.version = v } },
  {
    file: '.claude-plugin/marketplace.json',
    get: (d) => d.metadata?.version,
    set: (d, v) => {
      d.metadata.version = v
      // The marketplace also carries a version per plugin entry, which Copilot
      // CLI reads. Missing these is invisible until a Copilot user installs.
      for (const entry of d.plugins ?? []) entry.version = v
    },
  },
]

const SEMVER = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/

export function readVersions(root = ROOT) {
  return MANIFESTS.map(({ file, get }) => ({
    file,
    version: get(JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'))),
  }))
}

export function bump(version, { root = ROOT, check = false } = {}) {
  if (!SEMVER.test(version)) {
    throw new Error(`"${version}" is not semver (expected e.g. 1.2.0)`)
  }
  const changed = []
  for (const { file, get, set } of MANIFESTS) {
    const full = path.join(root, file)
    const raw = fs.readFileSync(full, 'utf8')
    const data = JSON.parse(raw)
    const before = get(data)
    if (before === version) continue
    changed.push({ file, from: before, to: version })
    if (!check) {
      set(data, version)
      // Two-space indent and a trailing newline, matching every manifest in
      // the repo, so a bump produces no incidental formatting diff.
      fs.writeFileSync(full, JSON.stringify(data, null, 2) + '\n', 'utf8')
    }
  }
  return changed
}

function main(argv) {
  const version = argv.find((a) => !a.startsWith('-'))
  const check = argv.includes('--check')
  if (!version) {
    console.error('usage: node scripts/bump-version.mjs <version> [--check]')
    return 2
  }
  let changed
  try {
    changed = bump(version, { check })
  } catch (err) {
    console.error(`error: ${err.message}`)
    return 1
  }
  if (changed.length === 0) {
    console.log(`All ${MANIFESTS.length} manifests already at ${version}.`)
    return 0
  }
  for (const c of changed) console.log(`${check ? 'would set' : 'set'}  ${c.file}  ${c.from} → ${c.to}`)
  if (check) {
    console.error(`\n${changed.length} manifest(s) are not at ${version}.`)
    return 1
  }
  console.log(`\n${changed.length} manifest(s) updated. Commit, then tag v${version}.`)
  return 0
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exitCode = main(process.argv.slice(2))
}
