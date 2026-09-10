/**
 * Build the complete set of writes before performing any of them.
 *
 * Planning is separate from writing so the disclosure screen shows exactly what
 * `--dry-run` would do and exactly what a confirmed run will do — the same
 * structure, rendered once and executed once. A preview that is computed
 * differently from the action it previews is worse than no preview.
 */

import fs from 'node:fs'
import path from 'node:path'
import { bundledAgents, renderAgent } from './agents.js'
import { agentTargets, instructionTargets, receiptPath, skillTargets } from './targets.js'
import {
  planInstructionWrite, planManagedFileRemoval, planManagedFileWrite,
  planSkillLinkDirectory, readReceipt,
} from './write.js'

/** Skill directories shipped in this package. */
export function bundledSkills(packageRoot) {
  const dir = path.join(packageRoot, 'skills')
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && fs.existsSync(path.join(dir, e.name, 'SKILL.md')))
    .map((e) => ({ name: e.name, dir: path.join(dir, e.name) }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

export function buildPlan({
  packageRoot,
  scope,
  components,
  agents,
  home,
  cwd,
  copy = false,
}) {
  const receipt = receiptPath(scope, { home, cwd })
  const previousReceipt = readReceipt(receipt)
  const plan = {
    scope,
    components,
    mode: copy ? 'copy' : 'symlink',
    skills: null,
    staleSkillPaths: [],
    agents: [],
    staleAgents: [],
    instructions: [],
    previousReceipt,
    receipt,
  }

  if (components.includes('skills')) {
    const targets = skillTargets(scope, { home, cwd })
    const skills = bundledSkills(packageRoot)
    // Claude Code is the only agent needing a link; skip it if unselected.
    const links = targets.links
      .filter((link) => agents.includes(link.agent))
      .map((link) => ({ ...link, ...planSkillLinkDirectory(link.dir) }))
    plan.skills = {
      canonical: targets.canonical,
      canonicalPlan: planSkillLinkDirectory(targets.canonical),
      canonicalReadBy: targets.canonicalReadBy,
      names: skills.map((s) => s.name),
      sources: skills,
      links,
    }
    const desiredSkillPaths = new Set([
      ...skills.map((skill) => path.join(targets.canonical, skill.name)),
      ...links.flatMap((link) => skills.map((skill) => path.join(link.dir, skill.name))),
    ])
    plan.staleSkillPaths = [
      ...(previousReceipt?.skills?.dirs ?? []),
      ...(previousReceipt?.skills?.links ?? []),
    ].filter((file) => !desiredSkillPaths.has(file))
  }

  if (components.includes('agents')) {
    const sources = bundledAgents(packageRoot)
    const owned = new Map((previousReceipt?.agents ?? []).map((entry) => [entry.file, entry]))
    plan.agents = agentTargets(scope, { home, cwd })
      .filter((target) => agents.includes(target.agent))
      .map((target) => ({
        ...target,
        files: sources.map((source) => {
          const content = renderAgent(source, target.agent)
          const file = path.join(target.dir, `${source.name}${target.suffix}`)
          return {
            name: source.name,
            content,
            ...planManagedFileWrite(file, content, owned.get(file)),
          }
        }),
      }))
    const desired = new Set(plan.agents.flatMap((target) => target.files.map((file) => file.file)))
    const selectedProviders = new Set(plan.agents.map((target) => target.agent))
    plan.staleAgents = (previousReceipt?.agents ?? [])
      .filter((entry) => selectedProviders.has(entry.provider) && !desired.has(entry.file))
      .map(planManagedFileRemoval)
  }

  if (components.includes('instructions')) {
    // Global only. A project's own AGENTS.md belongs to the project, and
    // overwriting it with ours is never the right default.
    if (scope !== 'global') {
      plan.instructionsSkipped = 'instructions install at global scope only'
    } else {
      plan.instructions = instructionTargets({ home })
        .filter((t) => agents.includes(t.agent))
        .map((t) => ({ ...planInstructionWrite(t.file), label: t.label, agent: t.agent }))
    }
  }

  return plan
}

/** Render the plan as the disclosure the user confirms against. */
export function renderDisclosure(plan, { packageVersion }) {
  const lines = []
  const where = plan.scope === 'global' ? 'GLOBAL' : 'PROJECT'
  lines.push(`agent-conventions ${packageVersion} — ${where} scope`)
  lines.push('')

  if (plan.scope === 'global') {
    lines.push('These paths live outside your project and affect every repo on this machine.')
    lines.push('')
  }

  if (plan.skills) {
    lines.push(`  ${plan.skills.canonical}`)
    if (plan.skills.canonicalPlan.action === 'create' ||
        plan.skills.canonicalPlan.action === 'use') {
      lines.push(`      ${plan.skills.names.length} skills — read by ${plan.skills.canonicalReadBy.join(', ')}`)
    } else {
      lines.push(`      refused: ${plan.skills.canonicalPlan.detail}`)
    }
    for (const link of plan.skills.links) {
      lines.push(`  ${link.dir}`)
      if (link.action === 'create' || link.action === 'use') {
        lines.push(`      ${plan.mode} entries → the directory above (${link.label} does not read .agents/skills)`)
      } else {
        lines.push(`      refused: ${link.detail}`)
      }
    }
    lines.push('')
  }

  if (plan.staleSkillPaths.length) {
    lines.push('  stale managed skill paths removed during update:')
    for (const file of plan.staleSkillPaths) lines.push(`      remove    ${file}`)
    lines.push('')
  }

  if (plan.agents.length) {
    for (const target of plan.agents) {
      lines.push(`  ${target.dir}`)
      lines.push(`      ${target.files.length} generated agents for ${target.label}`)
      for (const file of target.files) {
        lines.push(`      ${file.action.padEnd(9)} ${file.file}`)
      }
    }
    lines.push('')
  }

  if (plan.staleAgents.length) {
    lines.push('  stale generated agents:')
    for (const item of plan.staleAgents) {
      lines.push(`      ${item.action.padEnd(9)} ${item.file} (${item.detail})`)
    }
    lines.push('')
  }

  if (plan.instructionsSkipped) {
    lines.push(`  instructions: skipped — ${plan.instructionsSkipped}`)
    lines.push('')
  }

  if (plan.instructions.length) {
    for (const item of plan.instructions) {
      lines.push(`  ${item.file}`)
      lines.push(`      ${item.detail}`)
    }
    lines.push('')
    lines.push('  Content is wrapped in <!-- BEGIN/END aanyberg/agent-conventions --> markers.')
    lines.push('  Everything outside the markers is preserved; uninstall removes only the block.')
    lines.push('')
  }

  const replaceableInstructionSymlinks = plan.instructions.filter(
    (item) => item.action === 'refuse-symlink',
  )
  const replaceableSkillSymlinks = plan.skills?.links.filter(
    (link) => link.action === 'refuse-symlink',
  ) ?? []
  const replaceableCanonicalSymlink = plan.skills?.canonicalPlan.action === 'refuse-symlink'
    ? [plan.skills.canonicalPlan]
    : []
  if (replaceableInstructionSymlinks.length || replaceableSkillSymlinks.length ||
      replaceableCanonicalSymlink.length) {
    lines.push('  REFUSED without --replace-symlinks:')
    for (const link of [...replaceableCanonicalSymlink, ...replaceableSkillSymlinks]) {
      lines.push(`    ${link.dir} is a ${link.detail}`)
    }
    for (const r of replaceableInstructionSymlinks) {
      lines.push(`    ${r.file} is a ${r.detail}`)
    }
    lines.push('    Writing through a symlink would modify the path it points at.')
    lines.push('')
  }

  const pathConflicts = [
    ...(plan.skills?.canonicalPlan.action === 'refuse'
      ? [{ file: plan.skills.canonicalPlan.dir, detail: plan.skills.canonicalPlan.detail }]
      : []),
    ...(plan.skills?.links.filter((link) => link.action === 'refuse') ?? [])
      .map((link) => ({ file: link.dir, detail: link.detail })),
    ...plan.instructions.filter((item) => item.action === 'refuse'),
  ]
  if (pathConflicts.length) {
    lines.push('  REFUSED path conflicts:')
    for (const item of pathConflicts) lines.push(`    ${item.file}: ${item.detail}`)
    lines.push('    Move or rename the conflicting path before installing this component.')
    lines.push('')
  }

  const agentRefusals = plan.agents.flatMap(
    (target) => target.files.filter((file) => file.action === 'refuse'),
  )
  if (agentRefusals.length) {
    lines.push('  REFUSED generated agent writes:')
    for (const item of agentRefusals) lines.push(`    ${item.file}: ${item.detail}`)
    lines.push('    Only byte-identical files recorded in this package receipt may be replaced.')
    lines.push('')
  }

  lines.push(`  receipt: ${plan.receipt}`)
  return lines.join('\n')
}
