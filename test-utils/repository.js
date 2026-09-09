import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { parse as parseYaml } from 'yaml'

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

export const SPEC_FRONTMATTER_KEYS = new Set([
  'name',
  'description',
  'license',
  'compatibility',
  'metadata',
  'allowed-tools',
])

export function relative(file) {
  return path.relative(ROOT, file).split(path.sep).join('/')
}

export function walk(dir, predicate) {
  const files = []
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === 'node_modules') continue
    const file = path.join(dir, entry.name)
    if (entry.isDirectory()) files.push(...walk(file, predicate))
    else if (entry.isFile() && predicate(file)) files.push(file)
  }
  return files.sort()
}

export function parseFrontmatter(file) {
  const text = fs.readFileSync(file, 'utf8')
  if (!text.startsWith('---\n')) throw new Error(`${relative(file)} does not start with YAML frontmatter`)
  const end = text.indexOf('\n---\n', 4)
  if (end === -1) throw new Error(`${relative(file)} has no closing frontmatter delimiter`)
  const frontmatter = parseYaml(text.slice(4, end))
  if (!frontmatter || typeof frontmatter !== 'object' || Array.isArray(frontmatter)) {
    throw new Error(`${relative(file)} frontmatter is not a mapping`)
  }
  return { path: file, rel: relative(file), frontmatter, body: text.slice(end + 5) }
}

export function skillFiles() {
  const dir = path.join(ROOT, 'skills')
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(dir, entry.name, 'SKILL.md'))
    .filter(fs.existsSync)
    .sort()
}

export function agentFiles() {
  const dir = path.join(ROOT, 'agent-sources')
  return fs.readdirSync(dir)
    .filter((name) => name.endsWith('.md'))
    .map((name) => path.join(dir, name))
    .sort()
}

export function markdownFiles() {
  return walk(ROOT, (file) => file.endsWith('.md'))
}

export function shellScripts() {
  return walk(path.join(ROOT, 'skills'), (file) => file.endsWith('.sh'))
}

export function readJson(rel) {
  return JSON.parse(fs.readFileSync(path.join(ROOT, rel), 'utf8'))
}

export function marketplacePath() {
  return path.join(ROOT, '.claude-plugin', 'marketplace.json')
}

export function loadMarketplace() {
  return readJson('.claude-plugin/marketplace.json')
}

export function pluginDirs() {
  const candidates = [ROOT]
  const plugins = path.join(ROOT, 'plugins')
  if (fs.existsSync(plugins)) {
    candidates.push(
      ...fs.readdirSync(plugins, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => path.join(plugins, entry.name)),
    )
  }
  return candidates.filter((dir) => fs.existsSync(path.join(dir, '.claude-plugin', 'plugin.json')))
}

export function marketplaceEntryFor(pluginDir) {
  return loadMarketplace().plugins.find(
    (entry) => path.resolve(ROOT, entry.source) === path.resolve(pluginDir),
  )
}

export function difference(values, allowed) {
  return [...values].filter((value) => !allowed.has(value)).sort()
}

export function duplicates(values) {
  const counts = new Map()
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1)
  return [...counts].filter(([, count]) => count > 1).map(([value]) => value)
}
