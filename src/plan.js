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
import { instructionTargets, receiptPath, skillTargets } from './targets.js'
import { planInstructionWrite } from './write.js'

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
  const plan = { scope, components, mode: copy ? 'copy' : 'symlink', skills: null, instructions: [] }

  if (components.includes('skills')) {
    const targets = skillTargets(scope, { home, cwd })
    const skills = bundledSkills(packageRoot)
    // Claude Code is the only agent needing a link; skip it if unselected.
    const links = targets.links.filter((l) => agents.includes(l.agent))
    plan.skills = {
      canonical: targets.canonical,
      canonicalReadBy: targets.canonicalReadBy,
      names: skills.map((s) => s.name),
      sources: skills,
      links,
    }
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

  plan.receipt = receiptPath(scope, { home, cwd })
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
    lines.push(`      ${plan.skills.names.length} skills — read by ${plan.skills.canonicalReadBy.join(', ')}`)
    for (const link of plan.skills.links) {
      lines.push(`  ${link.dir}`)
      lines.push(`      ${plan.mode} → the directory above (${link.label} does not read .agents/skills)`)
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

  const refusals = plan.instructions.filter((i) => i.action.startsWith('refuse'))
  if (refusals.length) {
    lines.push('  REFUSED without --replace-symlinks:')
    for (const r of refusals) {
      lines.push(`    ${r.file} is a ${r.detail}`)
    }
    lines.push('    Writing through a symlink would modify the file it points at.')
    lines.push('')
  }

  lines.push(`  receipt: ${plan.receipt}`)
  return lines.join('\n')
}
