/**
 * Everything that touches the filesystem, and the rules that keep it safe.
 *
 * Two invariants matter more than anything else here:
 *
 *  1. **Never write through a symlink.** The previous README told people to run
 *     `ln -s /path/to/agent-conventions/AGENTS.md ~/.claude/CLAUDE.md`. Opening
 *     that path in append mode writes *into their clone of this repository* and
 *     corrupts the source of truth, which then gets committed. Every write
 *     lstats first and refuses to follow a link.
 *
 *  2. **Never remove a file we did not write.** Uninstall works from the
 *     receipt, not from a guess about what an install would have produced.
 */

import fs from 'node:fs'
import path from 'node:path'
import { MARKER_BEGIN, MARKER_END } from './targets.js'

/** What is actually at this path? Uses lstat, so a symlink reports as one. */
export function classify(file) {
  let st
  try {
    st = fs.lstatSync(file)
  } catch (err) {
    if (err.code === 'ENOENT') return { kind: 'absent' }
    throw err
  }
  if (st.isSymbolicLink()) {
    let resolved = null
    try {
      resolved = fs.realpathSync(file)
    } catch {
      resolved = fs.readlinkSync(file) // dangling link — report where it pointed
    }
    return { kind: 'symlink', resolved }
  }
  if (st.isDirectory()) return { kind: 'directory' }
  return { kind: 'file' }
}

/** Wrap content in the markers that make it removable later. */
export function renderBlock(content) {
  return `${MARKER_BEGIN}\n${content.trimEnd()}\n${MARKER_END}\n`
}

export function hasBlock(text) {
  return text.includes(MARKER_BEGIN) && text.includes(MARKER_END)
}

/**
 * Insert or replace our block, preserving everything outside it.
 *
 * Deliberately string-based rather than regex: the content can contain any
 * markdown, and a greedy pattern over user text is the kind of thing that
 * silently eats a paragraph.
 */
export function upsertBlock(existing, content) {
  const block = renderBlock(content)
  if (!hasBlock(existing)) {
    const sep = existing.length === 0 || existing.endsWith('\n\n') ? '' : existing.endsWith('\n') ? '\n' : '\n\n'
    return existing + sep + block
  }
  const start = existing.indexOf(MARKER_BEGIN)
  const end = existing.indexOf(MARKER_END) + MARKER_END.length
  if (end < start) throw new Error('markers are out of order; refusing to edit')
  const trailing = existing.slice(end).replace(/^\n/, '')
  return existing.slice(0, start) + block + trailing
}

/**
 * Strip our block and leave the rest untouched.
 *
 * `upsertBlock` inserts a blank-line separator before the block when appending
 * to a file that ends in a single newline, so removal has to take that
 * separator back out. Without this the file gains one blank line per
 * install/uninstall cycle — the round-trip tests below are what caught it.
 */
export function removeBlock(existing) {
  if (!hasBlock(existing)) return existing
  const start = existing.indexOf(MARKER_BEGIN)
  const end = existing.indexOf(MARKER_END) + MARKER_END.length
  const before = existing.slice(0, start)
  const after = existing.slice(end).replace(/^\n/, '')
  // Only collapse when the block sat at the end; mid-file, the surrounding
  // blank lines are the user's own and must survive untouched.
  const restored = after === '' ? before.replace(/\n\n$/, '\n') : before + after
  return restored.trim().length === 0 ? '' : restored
}

/**
 * Decide what an instruction write would do, without doing it.
 *
 * Returns an `action` the caller renders in the disclosure screen, so the user
 * sees "replace symlink" before it happens rather than after.
 */
export function planInstructionWrite(file) {
  const at = classify(file)
  if (at.kind === 'absent') return { file, action: 'create', detail: 'creates file' }
  if (at.kind === 'directory') return { file, action: 'refuse', detail: 'a directory exists here' }
  if (at.kind === 'symlink') {
    return {
      file,
      action: 'refuse-symlink',
      detail: `symlink → ${at.resolved}`,
      resolved: at.resolved,
    }
  }
  const text = fs.readFileSync(file, 'utf8')
  const kept = removeBlock(text).split('\n').filter(Boolean).length
  return {
    file,
    action: hasBlock(text) ? 'update' : 'append',
    detail: hasBlock(text) ? 'updates existing block' : `appends block (${kept} existing lines kept)`,
  }
}

/** Apply an instruction write. Refuses anything the plan marked as refusable. */
export function applyInstructionWrite(plan, content, { replaceSymlinks = false } = {}) {
  if (plan.action === 'refuse') {
    throw new Error(`${plan.file}: ${plan.detail}`)
  }
  if (plan.action === 'refuse-symlink' && !replaceSymlinks) {
    throw new Error(
      `${plan.file} is a symlink → ${plan.resolved}. Writing through it would modify ` +
        `that file. Re-run with --replace-symlinks to replace the link with a real file.`,
    )
  }
  fs.mkdirSync(path.dirname(plan.file), { recursive: true })
  if (plan.action === 'refuse-symlink') {
    fs.unlinkSync(plan.file) // replace the link itself, never follow it
    fs.writeFileSync(plan.file, renderBlock(content), 'utf8')
    return { ...plan, applied: 'replaced-symlink' }
  }
  const existing = plan.action === 'create' ? '' : fs.readFileSync(plan.file, 'utf8')
  fs.writeFileSync(plan.file, upsertBlock(existing, content), 'utf8')
  return { ...plan, applied: plan.action }
}

/** Copy a skill directory, replacing any previous copy of the same skill. */
export function installSkill(sourceDir, destDir) {
  fs.rmSync(destDir, { recursive: true, force: true })
  fs.mkdirSync(path.dirname(destDir), { recursive: true })
  fs.cpSync(sourceDir, destDir, { recursive: true })
}

/**
 * Link a skill into an agent-specific directory.
 *
 * Relative targets, so a committed project tree still resolves after a clone to
 * a different path. Falls back to a copy where symlinks are unavailable, which
 * is Windows without Developer Mode more often than anything else.
 */
export function linkSkill(canonicalDir, linkPath, { copy = false } = {}) {
  fs.rmSync(linkPath, { recursive: true, force: true })
  fs.mkdirSync(path.dirname(linkPath), { recursive: true })
  if (copy) {
    fs.cpSync(canonicalDir, linkPath, { recursive: true })
    return 'copy'
  }
  const rel = path.relative(path.dirname(linkPath), canonicalDir)
  try {
    fs.symlinkSync(rel, linkPath, 'dir')
    return 'symlink'
  } catch (err) {
    if (err.code !== 'EPERM' && err.code !== 'EACCES') throw err
    fs.cpSync(canonicalDir, linkPath, { recursive: true })
    return 'copy'
  }
}

export function readReceipt(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (err) {
    if (err.code === 'ENOENT') return null
    throw err
  }
}

export function writeReceipt(file, receipt) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(receipt, null, 2) + '\n', 'utf8')
}
