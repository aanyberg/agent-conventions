/**
 * The one place that knows where anything goes.
 *
 * Two facts keep this table small, and both were verified by running the
 * ecosystem's own installer rather than read off documentation:
 *
 *  1. `.agents/skills/` is universal. Codex, GitHub Copilot, OpenCode, Cursor,
 *     Gemini CLI, Cline, Zed and Amp all read it. Claude Code is the sole
 *     holdout, so it gets a symlink into the same files rather than a copy.
 *  2. That holds at BOTH scopes. `~/.agents/skills/` is universal too, so the
 *     global case needs no per-agent table either.
 *
 * Instructions are the opposite: every tool keeps global guidance in its own
 * directory, and two of them expect a different filename there. That is why the
 * instruction table has real entries while the skills one has two.
 */

import os from 'node:os'
import path from 'node:path'

/** Skills: one real directory, plus the agents that need a link into it. */
export function skillTargets(scope, { home = os.homedir(), cwd = process.cwd() } = {}) {
  const root = scope === 'global' ? home : cwd
  return {
    // The real files. Everything else points here.
    canonical: path.join(root, '.agents', 'skills'),
    canonicalReadBy: [
      'Codex', 'GitHub Copilot', 'OpenCode', 'Cursor',
      'Gemini CLI', 'Cline', 'Zed', 'Amp',
    ],
    // Agents that do not read `.agents/skills` and need their own path.
    links: [{ agent: 'claude-code', label: 'Claude Code', dir: path.join(root, '.claude', 'skills') }],
  }
}

/**
 * Instructions: global only, and never the project's own AGENTS.md.
 *
 * A consumer's project-root AGENTS.md belongs to them. Writing it would clobber
 * their content with ours, so this installer does not offer to.
 */
export const INSTRUCTION_TARGETS = [
  { agent: 'claude-code', label: 'Claude Code', rel: ['.claude', 'CLAUDE.md'] },
  { agent: 'github-copilot', label: 'GitHub Copilot', rel: ['.copilot', 'copilot-instructions.md'] },
  { agent: 'codex', label: 'Codex', rel: ['.codex', 'AGENTS.md'] },
  { agent: 'gemini-cli', label: 'Gemini CLI', rel: ['.gemini', 'GEMINI.md'] },
]

export function instructionTargets({ home = os.homedir() } = {}) {
  return INSTRUCTION_TARGETS.map((t) => ({ ...t, file: path.join(home, ...t.rel) }))
}

/** Agents selectable at global scope. Project scope needs no selection: one write covers all. */
export const SELECTABLE_AGENTS = [
  { id: 'claude-code', label: 'Claude Code' },
  { id: 'codex', label: 'Codex' },
  { id: 'github-copilot', label: 'GitHub Copilot' },
  { id: 'opencode', label: 'OpenCode' },
  { id: 'cursor', label: 'Cursor' },
  { id: 'gemini-cli', label: 'Gemini CLI' },
]

/** Where the receipt lives, so update and uninstall touch only what we wrote. */
export function receiptPath(scope, { home = os.homedir(), cwd = process.cwd() } = {}) {
  const root = scope === 'global' ? home : cwd
  return path.join(root, '.agent-conventions.json')
}

export const MARKER_BEGIN = '<!-- BEGIN aanyberg/agent-conventions -->'
export const MARKER_END = '<!-- END aanyberg/agent-conventions -->'

/**
 * Interpret an answer to the global agent prompt.
 *
 * Pure so it can be tested without a terminal: the prompt itself needs a TTY,
 * but the rule for turning "1 3", "a" or "" into a set of agents is the part
 * with edge cases worth pinning down.
 *
 * An answer that matches nothing is treated as a typo and falls back to the
 * preset — installing for no agents at all is never what someone meant.
 */
export function parseAgentSelection(answer, { preset }) {
  const all = SELECTABLE_AGENTS.map((a) => a.id)
  const text = String(answer ?? '').trim()
  if (text === '') return { agents: preset, reason: 'preset' }
  if (/^(a|all)$/i.test(text)) return { agents: all, reason: 'all' }
  const chosen = text
    .split(/[,\s]+/)
    .filter(Boolean)
    .map((n) => SELECTABLE_AGENTS[Number(n) - 1])
    .filter(Boolean)
    .map((a) => a.id)
  const unique = [...new Set(chosen)]
  return unique.length ? { agents: unique, reason: 'chosen' } : { agents: preset, reason: 'unrecognised' }
}
