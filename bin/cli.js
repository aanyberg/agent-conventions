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
import { SELECTABLE_AGENTS } from '../src/targets.js'
import {
  applyInstructionWrite, installSkill, linkSkill, readReceipt, removeBlock, writeReceipt,
} from '../src/write.js'

const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const PKG = JSON.parse(fs.readFileSync(path.join(PACKAGE_ROOT, 'package.json'), 'utf8'))

const USAGE = `
agent-conventions ${PKG.version}

  npx @aanyberg/agent-conventions            install (prompts for scope and agents)
  npx @aanyberg/agent-conventions uninstall  remove exactly what the receipt records

Options
  -g, --global            install for every project on this machine
  -p, --project           install into the current project only
  -a, --agent <list>      comma-separated, or "all" (claude-code, codex,
                          github-copilot, opencode, cursor, gemini-cli)
  -c, --components <list> skills,instructions  (default: both at global scope,
                          skills only at project scope)
      --copy              copy instead of symlinking
      --replace-symlinks  replace an existing instruction symlink with a real
                          file. Without this, a symlink is refused rather than
                          written through.
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
  while (rest.length) {
    const arg = rest.shift()
    switch (arg) {
      case 'install': opts.command = 'install'; break
      case 'uninstall': case 'remove': opts.command = 'uninstall'; break
      case '-g': case '--global': opts.scope = 'global'; break
      case '-p': case '--project': opts.scope = 'project'; break
      case '-a': case '--agent': opts.agents = rest.shift(); break
      case '-c': case '--components': opts.components = rest.shift(); break
      case '--copy': opts.copy = true; break
      case '--replace-symlinks': opts.replaceSymlinks = true; break
      case '--dry-run': opts.dryRun = true; break
      case '-y': case '--yes': opts.yes = true; break
      case '-h': case '--help': opts.help = true; break
      default:
        if (arg.startsWith('-')) throw new Error(`unknown option: ${arg}`)
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
  if (scope === 'project') {
    // One write covers every agent but Claude Code, so there is nothing to pick.
    console.log('\n.agents/skills/ covers Codex, GitHub Copilot, OpenCode, Cursor, Gemini CLI and others.')
    console.log('Claude Code reads only .claude/skills/.\n')
    const answer = await ask(rl, 'Also link Claude Code? [Y/n]: ', 'y')
    const claude = !answer.toLowerCase().startsWith('n')
    return claude ? SELECTABLE_AGENTS.map((a) => a.id) : SELECTABLE_AGENTS.map((a) => a.id).filter((a) => a !== 'claude-code')
  }
  console.log('\nInstall for which agents?\n')
  SELECTABLE_AGENTS.forEach((a, i) => {
    const mark = detected.includes(a.id) ? '*' : ' '
    console.log(`  ${mark} ${i + 1}) ${a.label}`)
  })
  console.log('\n  * = detected on this machine')
  const preset = detected.length ? detected : SELECTABLE_AGENTS.map((a) => a.id)
  const answer = await ask(rl, `\nNumbers, or Enter for detected [${preset.join(', ')}]: `, '')
  if (!answer) return preset
  return answer
    .split(/[,\s]+/).filter(Boolean)
    .map((n) => SELECTABLE_AGENTS[Number(n) - 1])
    .filter(Boolean)
    .map((a) => a.id)
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
    : scope === 'global' ? ['skills', 'instructions'] : ['skills']

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
    scope, mode: plan.mode, skills: null, instructions: [],
  }

  if (plan.skills) {
    const written = []
    for (const skill of plan.skills.sources) {
      const dest = path.join(plan.skills.canonical, skill.name)
      installSkill(skill.dir, dest)
      written.push(dest)
    }
    const links = []
    let mode = plan.mode
    for (const link of plan.skills.links) {
      for (const name of plan.skills.names) {
        const linkPath = path.join(link.dir, name)
        mode = linkSkill(path.join(plan.skills.canonical, name), linkPath, { copy: opts.copy })
        links.push(linkPath)
      }
    }
    receipt.skills = { canonical: plan.skills.canonical, dirs: written, links }
    receipt.mode = mode
    console.log(`Installed ${plan.skills.names.length} skills to ${plan.skills.canonical}`)
    if (links.length) console.log(`Linked ${links.length} into ${plan.skills.links.map((l) => l.dir).join(', ')} (${mode})`)
  }

  if (plan.instructions.length) {
    const content = fs.readFileSync(path.join(PACKAGE_ROOT, 'AGENTS.md'), 'utf8')
    for (const item of plan.instructions) {
      try {
        const applied = applyInstructionWrite(item, content, { replaceSymlinks: opts.replaceSymlinks })
        receipt.instructions.push({ file: applied.file, applied: applied.applied })
        console.log(`${applied.applied.padEnd(18)} ${applied.file}`)
      } catch (err) {
        console.error(`SKIPPED            ${item.file}\n                   ${err.message}`)
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

  // Only ever remove what the receipt records. Never infer.
  for (const link of receipt.skills?.links ?? []) fs.rmSync(link, { recursive: true, force: true })
  for (const dir of receipt.skills?.dirs ?? []) fs.rmSync(dir, { recursive: true, force: true })
  for (const item of receipt.instructions ?? []) {
    try {
      if (item.applied === 'create' || item.applied === 'replaced-symlink') {
        fs.rmSync(item.file, { force: true })
      } else {
        const text = fs.readFileSync(item.file, 'utf8')
        const stripped = removeBlock(text)
        if (stripped === '') fs.rmSync(item.file, { force: true })
        else fs.writeFileSync(item.file, stripped, 'utf8')
      }
      console.log(`removed  ${item.file}`)
    } catch (err) {
      console.error(`skipped  ${item.file}: ${err.message}`)
    }
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
