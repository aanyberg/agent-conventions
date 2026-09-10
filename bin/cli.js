#!/usr/bin/env node
/**
 * agent-conventions installer.
 *
 * Deliberately dependency-free. This is run through `npx` on machines that have
 * never seen it before, so every dependency is a supply-chain decision made on
 * the user's behalf. Prompts are ~40 lines of readline; that is cheaper than
 * owning a prompt library's transitive tree.
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline/promises'
import { fileURLToPath } from 'node:url'

import { buildPlan, renderDisclosure } from '../src/plan.js'
import { SELECTABLE_AGENTS, parseAgentSelection } from '../src/targets.js'
import {
  applyInstructionWrite, applyManagedFileWrite, installSkill, linkSkill,
  prepareSkillLinkDirectory, readReceipt, removeBlock, removeManagedFile,
  removeSkillPath, writeReceipt,
} from '../src/write.js'

const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const PKG = JSON.parse(fs.readFileSync(path.join(PACKAGE_ROOT, 'package.json'), 'utf8'))

const USAGE = `
agent-conventions ${PKG.version}

  npx @anyberg/agent-conventions            install (prompts for scope and agents)
  npx @anyberg/agent-conventions uninstall  remove exactly what the receipt records

Options
  -g, --global            install for every project on this machine
  -p, --project           install into the current project only
  -a, --agent <list>      comma-separated, or "all" (claude-code, codex,
                          github-copilot, opencode, cursor, gemini-cli)
  -c, --components <list> skills,agents,instructions  (default: all at global
                          scope, skills and agents at project scope)
      --copy              copy instead of symlinking
      --replace-symlinks  replace an existing instruction or Claude skills
                          symlink with a real path. Without this, a symlink is
                          refused rather than written through.
      --dry-run           print the plan and exit without writing
  -y, --yes               skip the confirmation prompt (the plan is still printed)
  -h, --help
`.trim()

function parseArgs(argv) {
  const opts = {
    command: 'install', scope: null, agents: null, components: null,
    copy: false, replaceSymlinks: false, dryRun: false, yes: false, help: false,
  }
  const rest = [...argv]
  let commandSeen = false
  while (rest.length) {
    const arg = rest.shift()
    const optionValue = () => {
      const value = rest.shift()
      if (!value || value.startsWith('-')) throw new Error(`${arg} requires a value`)
      return value
    }
    switch (arg) {
      case 'install':
        if (commandSeen) throw new Error(`unexpected argument: ${arg}`)
        commandSeen = true
        opts.command = 'install'
        break
      case 'uninstall': case 'remove':
        if (commandSeen) throw new Error(`unexpected argument: ${arg}`)
        commandSeen = true
        opts.command = 'uninstall'
        break
      case '-g': case '--global': opts.scope = 'global'; break
      case '-p': case '--project': opts.scope = 'project'; break
      case '-a': case '--agent': opts.agents = optionValue(); break
      case '-c': case '--components': opts.components = optionValue(); break
      case '--copy': opts.copy = true; break
      case '--replace-symlinks': opts.replaceSymlinks = true; break
      case '--dry-run': opts.dryRun = true; break
      case '-y': case '--yes': opts.yes = true; break
      case '-h': case '--help': opts.help = true; break
      default:
        throw new Error(arg.startsWith('-') ? `unknown option: ${arg}` : `unexpected argument: ${arg}`)
    }
  }
  return opts
}

/**
 * Are we being driven by an agent rather than a person?
 *
 * A prompt nobody can answer is a hang, so anything non-interactive runs with
 * defaults and prints the plan instead of asking.
 */
function isInteractive() {
  if (process.env.CI) return false
  if (process.env.CLAUDECODE || process.env.CLAUDE_CODE) return false
  if (process.env.AGENT || process.env.OPENCODE || process.env.CURSOR_AGENT) return false
  return process.stdin.isTTY === true && process.stdout.isTTY === true
}

/** Which agents show evidence of being installed on this machine? */
function detectAgents(home) {
  const probes = {
    'claude-code': ['.claude'],
    codex: ['.codex'],
    'github-copilot': ['.copilot'],
    opencode: ['.config/opencode'],
    cursor: ['.cursor'],
    'gemini-cli': ['.gemini'],
  }
  return Object.entries(probes)
    .filter(([, dirs]) => dirs.some((d) => fs.existsSync(path.join(home, d))))
    .map(([id]) => id)
}

function resolveAgents(spec, detected) {
  const all = SELECTABLE_AGENTS.map((a) => a.id)
  if (!spec) return detected.length ? detected : all
  if (spec === 'all') return all
  const chosen = spec.split(',').map((s) => s.trim()).filter(Boolean)
  const unknown = chosen.filter((c) => !all.includes(c))
  if (unknown.length) throw new Error(`unknown agent(s): ${unknown.join(', ')}\nknown: ${all.join(', ')}`)
  return chosen
}

async function ask(rl, question, fallback) {
  const answer = (await rl.question(question)).trim()
  return answer === '' ? fallback : answer
}

async function promptForScope(rl) {
  console.log('Where should this be installed?\n')
  console.log('  1) Project  — this repository only')
  console.log('  2) Global   — every project on this machine\n')
  const answer = await ask(rl, 'Choose [1]: ', '1')
  return answer.startsWith('2') || answer.toLowerCase().startsWith('g') ? 'global' : 'project'
}

async function promptForAgents(rl, scope, detected) {
  const all = SELECTABLE_AGENTS.map((a) => a.id)

  if (scope === 'project') {
    // One write to .agents/skills already serves every agent here, so the only
    // real choice is whether to bridge Claude Code — which reads its own path.
    // Say so explicitly: "all agents" is the default, not something to opt into.
    console.log('\nInstalling for ALL agents. One .agents/skills/ directory covers Codex,')
    console.log('GitHub Copilot, OpenCode, Cursor, Gemini CLI and others.\n')
    console.log('Claude Code is the exception — it reads only .claude/skills/.\n')
    const answer = await ask(rl, 'Also link Claude Code? [Y/n]: ', 'y')
    return answer.toLowerCase().startsWith('n') ? all.filter((a) => a !== 'claude-code') : all
  }

  console.log('\nInstall for which agents?\n')
  SELECTABLE_AGENTS.forEach((a, i) => {
    const mark = detected.includes(a.id) ? '*' : ' '
    console.log(`  ${mark} ${i + 1}) ${a.label}`)
  })
  console.log('\n    a) All of the above')
  console.log('\n  * = detected on this machine')
  const preset = detected.length ? detected : all
  const answer = await ask(rl, `\nNumbers, "a" for all, or Enter for detected [${preset.join(', ')}]: `, '')
  const { agents, reason } = parseAgentSelection(answer, { preset })
  if (reason === 'unrecognised') {
    console.log(`Nothing recognised in "${answer}" — using the detected set.`)
  }
  return agents
}

async function runInstall(opts) {
  const home = os.homedir()
  const cwd = process.cwd()
  const detected = detectAgents(home)
  const interactive = isInteractive() && !opts.yes && !opts.dryRun

  let scope = opts.scope
  let agents = opts.agents ? resolveAgents(opts.agents, detected) : null

  if (interactive) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
    try {
      if (!scope) scope = await promptForScope(rl)
      if (!agents) agents = await promptForAgents(rl, scope, detected)
    } finally {
      rl.close()
    }
  }
  scope ??= 'project'
  agents ??= resolveAgents(opts.agents, detected)

  const components = opts.components
    ? opts.components.split(',').map((s) => s.trim()).filter(Boolean)
    : scope === 'global' ? ['skills', 'agents', 'instructions'] : ['skills', 'agents']
  const unknownComponents = components.filter((component) => !['skills', 'agents', 'instructions'].includes(component))
  if (unknownComponents.length) throw new Error(`unknown component(s): ${unknownComponents.join(', ')}`)

  const plan = buildPlan({ packageRoot: PACKAGE_ROOT, scope, components, agents, home, cwd, copy: opts.copy })

  console.log('\n' + renderDisclosure(plan, { packageVersion: PKG.version }) + '\n')
  if (opts.dryRun) {
    console.log('--dry-run: nothing was written.')
    return 0
  }

  if (interactive) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
    let answer
    try {
      answer = await ask(rl, 'Proceed? [y/N]: ', 'n')
    } finally {
      rl.close()
    }
    if (!answer.toLowerCase().startsWith('y')) {
      console.log('Aborted. Nothing was written.')
      return 1
    }
  }

  const receipt = {
    package: PKG.name, version: PKG.version, installedAt: new Date().toISOString(),
    scope,
    mode: plan.mode,
    skills: plan.skills ? null : (plan.previousReceipt?.skills ?? null),
    agents: [],
    instructions: [...(plan.previousReceipt?.instructions ?? [])]
      .filter((entry) => !plan.instructions.some((item) => item.file === entry.file)),
  }

  let incomplete = false
  if (plan.skills) {
    const written = []
    const retainedStalePaths = { dirs: [], links: [] }
    const retainedProviderLinks = []
    const removedStalePaths = new Set()
    let canonicalPrepared = false
    let canonicalReady = false
    try {
      const prepared = prepareSkillLinkDirectory(plan.skills.canonicalPlan, {
        replaceSymlinks: opts.replaceSymlinks,
      })
      canonicalPrepared = true
      if (prepared.applied === 'replaced-symlink') {
        console.log(`replaced-symlink   ${plan.skills.canonical}`)
      }
      for (const stale of plan.staleSkillPaths) {
        const result = removeSkillPath(stale.file)
        if (result.removed) {
          removedStalePaths.add(stale.file)
          console.log(`removed stale      ${stale.file}`)
        }
        else {
          incomplete = true
          retainedStalePaths[stale.kind].push(stale.file)
          console.error(`kept stale         ${stale.file}: ${result.reason}`)
        }
      }
      for (const skill of plan.skills.sources) {
        const dest = path.join(plan.skills.canonical, skill.name)
        installSkill(skill.dir, dest)
        written.push(dest)
      }
      canonicalReady = true
    } catch (err) {
      incomplete = true
      console.error(
        `SKIPPED skills     ${plan.skills.canonical}\n                   ${err.message}`,
      )
    }
    const links = []
    let mode = plan.mode
    for (const link of canonicalReady ? plan.skills.links : []) {
      try {
        const prepared = prepareSkillLinkDirectory(link, {
          replaceSymlinks: opts.replaceSymlinks,
        })
        if (prepared.applied === 'replaced-symlink') {
          console.log(`replaced-symlink   ${link.dir}`)
        }
        for (const name of plan.skills.names) {
          const linkPath = path.join(link.dir, name)
          mode = linkSkill(path.join(plan.skills.canonical, name), linkPath, { copy: opts.copy })
          links.push(linkPath)
        }
      } catch (err) {
        incomplete = true
        retainedProviderLinks.push(
          ...(plan.previousReceipt?.skills?.links ?? [])
            .filter((file) => path.dirname(file) === link.dir),
        )
        console.error(`SKIPPED            ${link.dir}\n                   ${err.message}`)
      }
    }
    const retainedPreviousPaths = (kind) => (
      plan.previousReceipt?.skills?.[kind]?.filter((file) => !removedStalePaths.has(file)) ?? []
    )
    receipt.skills = canonicalReady
      ? {
          canonical: plan.skills.canonical,
          dirs: [...written, ...retainedStalePaths.dirs],
          links: [...new Set([...links, ...retainedStalePaths.links, ...retainedProviderLinks])],
        }
      : canonicalPrepared
        ? {
            canonical: plan.skills.canonical,
            dirs: [...new Set([...retainedPreviousPaths('dirs'), ...written])],
            links: retainedPreviousPaths('links'),
          }
      : (plan.previousReceipt?.skills ?? null)
    receipt.mode = mode
    if (written.length) {
      console.log(`Installed ${written.length} skills to ${plan.skills.canonical}`)
    }
    if (links.length) console.log(`Linked ${links.length} into ${plan.skills.links.map((l) => l.dir).join(', ')} (${mode})`)
  }

  const selectedAgentProviders = new Set(plan.agents.map((target) => target.agent))
  receipt.agents = (plan.previousReceipt?.agents ?? [])
    .filter((entry) => !selectedAgentProviders.has(entry.provider))

  for (const item of plan.staleAgents) {
    const result = removeManagedFile(item)
    if (result.removed) {
      console.log(`removed stale      ${item.file}`)
    } else if (result.reason !== 'already absent') {
      incomplete = true
      receipt.agents.push(item)
      console.error(`kept stale         ${item.file}: ${result.reason}`)
    }
  }

  for (const target of plan.agents) {
    for (const item of target.files) {
      try {
        const applied = applyManagedFileWrite(item, item.content)
        receipt.agents.push({
          provider: target.agent,
          name: item.name,
          file: item.file,
          sha256: item.desiredDigest,
        })
        console.log(`${applied.applied.padEnd(18)} ${item.file}`)
      } catch (err) {
        incomplete = true
        if (item.owned) receipt.agents.push(item.owned)
        console.error(`SKIPPED            ${item.file}\n                   ${err.message}`)
      }
    }
  }

  if (plan.instructions.length) {
    const content = fs.readFileSync(path.join(PACKAGE_ROOT, 'AGENTS.md'), 'utf8')
    for (const item of plan.instructions) {
      try {
        const applied = applyInstructionWrite(item, content, { replaceSymlinks: opts.replaceSymlinks })
        receipt.instructions.push({ file: applied.file, applied: applied.applied })
        console.log(`${applied.applied.padEnd(18)} ${applied.file}`)
      } catch (err) {
        incomplete = true
        console.error(`SKIPPED            ${item.file}\n                   ${err.message}`)
        const previous = plan.previousReceipt?.instructions?.find((entry) => entry.file === item.file)
        if (previous) receipt.instructions.push(previous)
      }
    }
  }

  writeReceipt(plan.receipt, receipt)
  console.log(`\nReceipt: ${plan.receipt}`)
  // Both forms are printed because either may be the one that works: the
  // published name until the package is on npm, the git specifier after.
  const flag = scope === 'global' ? '-g' : '-p'
  console.log(`Undo:    npx ${PKG.name} uninstall ${flag}`)
  console.log(`         npx github:aanyberg/agent-conventions uninstall ${flag}`)
  if (incomplete) {
    console.error('Installation incomplete; resolve the reported paths and rerun the command.')
    return 1
  }
  return 0
}

async function runUninstall(opts) {
  const home = os.homedir()
  const cwd = process.cwd()
  const scope = opts.scope ?? 'project'
  const file = path.join(scope === 'global' ? home : cwd, '.agent-conventions.json')
  const receipt = readReceipt(file)
  if (!receipt) {
    console.error(`No receipt at ${file} — nothing recorded as installed at ${scope} scope.`)
    return 1
  }

  const remaining = {
    ...receipt,
    skills: receipt.skills ? { ...receipt.skills, dirs: [], links: [] } : null,
    agents: [],
    instructions: [],
  }
  let incomplete = false

  // Only ever remove what the receipt records. Never infer.
  for (const file of receipt.skills?.links ?? []) {
    const result = removeSkillPath(file)
    if (result.removed) console.log(`removed  ${file}`)
    else {
      incomplete = true
      remaining.skills.links.push(file)
      console.error(`kept     ${file}: ${result.reason}`)
    }
  }
  for (const file of receipt.skills?.dirs ?? []) {
    const result = removeSkillPath(file)
    if (result.removed) console.log(`removed  ${file}`)
    else {
      incomplete = true
      remaining.skills.dirs.push(file)
      console.error(`kept     ${file}: ${result.reason}`)
    }
  }
  for (const entry of receipt.agents ?? []) {
    const result = removeManagedFile(entry)
    if (result.removed || result.reason === 'already absent') console.log(`removed  ${entry.file}`)
    else {
      incomplete = true
      remaining.agents.push(entry)
      console.error(`kept     ${entry.file}: ${result.reason}`)
    }
  }
  for (const item of receipt.instructions ?? []) {
    try {
      // Always strip the block and judge by what is left, even for a file this
      // installer created. Keying off `applied === 'create'` and deleting
      // outright would take anything the user added to that file afterwards —
      // a small data-loss case, but the same class as the symlink one.
      const text = fs.readFileSync(item.file, 'utf8')
      const stripped = removeBlock(text)
      if (stripped === '') {
        fs.rmSync(item.file, { force: true })
        console.log(`removed  ${item.file}`)
      } else {
        fs.writeFileSync(item.file, stripped, 'utf8')
        console.log(`stripped ${item.file} (kept your content)`)
      }
    } catch (err) {
      if (err.code === 'ENOENT') {
        console.log(`removed  ${item.file}`)
        continue
      }
      incomplete = true
      remaining.instructions.push(item)
      console.error(`skipped  ${item.file}: ${err.message}`)
    }
  }
  if (remaining.skills && !remaining.skills.dirs.length && !remaining.skills.links.length) {
    remaining.skills = null
  }
  if (incomplete) {
    writeReceipt(file, remaining)
    console.error(`\nRemoval incomplete. Receipt retained: ${file}`)
    return 1
  }
  fs.rmSync(file, { force: true })
  console.log(`\nRemoved. Receipt deleted: ${file}`)
  return 0
}

async function main() {
  let opts
  try {
    opts = parseArgs(process.argv.slice(2))
  } catch (err) {
    console.error(err.message)
    return 2
  }
  if (opts.help) {
    console.log(USAGE)
    return 0
  }
  try {
    return opts.command === 'uninstall' ? await runUninstall(opts) : await runInstall(opts)
  } catch (err) {
    console.error(`error: ${err.message}`)
    return 1
  }
}

process.exitCode = await main()
