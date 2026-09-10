import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { describe, test } from 'node:test'

import {
  ROOT,
  loadMarketplace,
  marketplaceEntryFor,
  marketplacePath,
  pluginDirs,
  readJson,
  relative,
} from '../test-utils/repository.js'

const SEMVER = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/
const NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const AGENT_PLUGINS_SCHEMA = 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json'
const AGENT_PLUGINS_NAME = /^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/
const AGENT_PLUGINS_KEYS = new Set([
  '$schema', 'name', 'version', 'description', 'author',
  'homepage', 'repository', 'license', 'keywords', 'extensions',
])
const MANIFESTS = [
  'plugin.json',
  'gemini-extension.json',
  '.codex-plugin/plugin.json',
  '.claude-plugin/plugin.json',
  '.claude-plugin/marketplace.json',
  'package.json',
]
const VERSION_AT = {
  'plugin.json': (data) => data.version,
  'gemini-extension.json': (data) => data.version,
  '.codex-plugin/plugin.json': (data) => data.version,
  '.claude-plugin/plugin.json': (data) => data.version,
  '.claude-plugin/marketplace.json': (data) => data.metadata.version,
  'package.json': (data) => data.version,
}

describe('Claude marketplace manifests', () => {
  test('marketplace is valid JSON', () => {
    assert.doesNotThrow(() => JSON.parse(fs.readFileSync(marketplacePath(), 'utf8')))
  })

  test('marketplace has required fields', () => {
    const marketplace = loadMarketplace()
    for (const field of ['name', 'owner', 'plugins']) assert.ok(Object.hasOwn(marketplace, field))
    assert.match(marketplace.name, NAME)
    assert.ok(Array.isArray(marketplace.plugins) && marketplace.plugins.length > 0)
  })

  test('marketplace sources resolve to plugins', () => {
    for (const entry of loadMarketplace().plugins) {
      const source = path.resolve(ROOT, entry.source)
      assert.ok(fs.statSync(source).isDirectory(), `${entry.name}: source does not resolve`)
      assert.ok(fs.statSync(path.join(source, '.claude-plugin', 'plugin.json')).isFile())
    }
  })

  test('every plugin on disk is listed', () => {
    assert.deepEqual(pluginDirs().filter((dir) => !marketplaceEntryFor(dir)).map(relative), [])
  })

  for (const pluginDir of pluginDirs()) {
    test(`${relative(pluginDir) || '.'} plugin manifest is valid`, () => {
      const manifest = JSON.parse(fs.readFileSync(path.join(pluginDir, '.claude-plugin', 'plugin.json'), 'utf8'))
      for (const field of ['name', 'description', 'version']) assert.ok(Object.hasOwn(manifest, field))
      const entry = marketplaceEntryFor(pluginDir)
      assert.ok(entry)
      assert.equal(manifest.name, entry.name)
      assert.match(manifest.name, NAME)
      assert.match(manifest.version, SEMVER)
    })

    test(`${relative(pluginDir) || '.'} descriptions agree`, () => {
      const manifest = JSON.parse(fs.readFileSync(path.join(pluginDir, '.claude-plugin', 'plugin.json'), 'utf8'))
      assert.equal(marketplaceEntryFor(pluginDir).description, manifest.description)
    })
  }
})

describe('native install manifests', () => {
  for (const rel of MANIFESTS) {
    test(`${rel} exists and parses`, () => {
      assert.ok(fs.statSync(path.join(ROOT, rel)).isFile())
      assert.doesNotThrow(() => readJson(rel))
    })
    test(`${rel} is not empty`, () => {
      assert.ok(Object.keys(readJson(rel)).length > 0)
    })
  }

  test('Agent Plugins manifest declares its schema', () => {
    assert.equal(readJson('plugin.json').$schema, AGENT_PLUGINS_SCHEMA)
  })

  test('Agent Plugins name matches the published grammar', () => {
    const name = readJson('plugin.json').name ?? ''
    assert.match(name, AGENT_PLUGINS_NAME)
    assert.ok(name.length >= 1 && name.length <= 64)
  })

  test('Agent Plugins manifest has no unrecognised keys', () => {
    const extra = Object.keys(readJson('plugin.json')).filter((key) => !AGENT_PLUGINS_KEYS.has(key))
    assert.deepEqual(extra, [])
  })

  test('Agent Plugins manifest declares no component paths', () => {
    const forbidden = ['skills', 'mcp', 'agents', 'commands']
      .filter((key) => Object.hasOwn(readJson('plugin.json'), key))
    assert.deepEqual(forbidden, [])
  })

  test('Codex manifest points at the shared skills directory', () => {
    const declared = readJson('.codex-plugin/plugin.json').skills
    assert.ok(declared)
    assert.equal(path.resolve(ROOT, declared.replace(/^\.?\//, '')), path.join(ROOT, 'skills'))
  })

  test('Gemini extension name is lowercase dashed', () => {
    assert.match(readJson('gemini-extension.json').name ?? '', NAME)
  })

  for (const [rel, getVersion] of Object.entries(VERSION_AT).sort()) {
    test(`${rel} declares a semantic version`, () => {
      assert.match(getVersion(readJson(rel)), SEMVER)
    })
  }

  test('every manifest declares the same version', () => {
    const versions = Object.fromEntries(
      Object.entries(VERSION_AT).map(([rel, getVersion]) => [rel, getVersion(readJson(rel))]),
    )
    assert.equal(new Set(Object.values(versions)).size, 1, JSON.stringify(versions))
  })

  test('marketplace carries the metadata Copilot reads', () => {
    const metadata = loadMarketplace().metadata
    assert.ok(metadata)
    for (const field of ['description', 'version']) assert.ok(Object.hasOwn(metadata, field))
  })

  test('every marketplace plugin entry declares a version', () => {
    assert.deepEqual(
      loadMarketplace().plugins.filter((entry) => !Object.hasOwn(entry, 'version')).map((entry) => entry.name),
      [],
    )
  })
})
