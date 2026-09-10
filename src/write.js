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
import crypto from 'node:crypto'
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

export function contentDigest(content) {
  return crypto.createHash('sha256').update(content).digest('hex')
}

/** Plan a generated whole-file write without claiming an unowned path. */
export function planManagedFileWrite(file, content, owned = null) {
  const desiredDigest = contentDigest(content)
  const at = classify(file)
  if (at.kind === 'absent') {
    return { file, action: 'create', detail: 'creates file', desiredDigest, owned }
  }
  if (at.kind === 'directory') {
    return { file, action: 'refuse', detail: 'a directory exists here', desiredDigest, owned }
  }
  if (at.kind === 'symlink') {
    return {
      file, action: 'refuse', detail: `symlink → ${at.resolved}`, desiredDigest, owned,
    }
  }
  if (!owned) {
    return { file, action: 'refuse', detail: 'an unowned file exists here', desiredDigest, owned }
  }
  const currentDigest = contentDigest(fs.readFileSync(file))
  if (currentDigest !== owned.sha256) {
    return {
      file, action: 'refuse', detail: 'managed file was modified', desiredDigest, owned,
    }
  }
  return {
    file,
    action: currentDigest === desiredDigest ? 'unchanged' : 'update',
    detail: currentDigest === desiredDigest ? 'already current' : 'updates managed file',
    desiredDigest,
    owned,
  }
}

export function applyManagedFileWrite(plan, content) {
  if (plan.action === 'refuse') throw new Error(`${plan.file}: ${plan.detail}`)
  if (plan.action !== 'unchanged') {
    fs.mkdirSync(path.dirname(plan.file), { recursive: true })
    fs.writeFileSync(plan.file, content, 'utf8')
  }
  return { ...plan, applied: plan.action }
}

/** Remove a generated file only while it is still byte-identical to our receipt. */
export function removeManagedFile(entry) {
  const at = classify(entry.file)
  if (at.kind === 'absent') return { ...entry, removed: false, reason: 'already absent' }
  if (at.kind !== 'file') return { ...entry, removed: false, reason: `path is a ${at.kind}` }
  const currentDigest = contentDigest(fs.readFileSync(entry.file))
  if (currentDigest !== entry.sha256) {
    return { ...entry, removed: false, reason: 'file was modified' }
  }
  fs.rmSync(entry.file, { force: true })
  return { ...entry, removed: true }
}

export function planManagedFileRemoval(entry) {
  const at = classify(entry.file)
  if (at.kind === 'absent') return { ...entry, action: 'forget', detail: 'already absent' }
  if (at.kind !== 'file') return { ...entry, action: 'keep', detail: `path is a ${at.kind}` }
  const currentDigest = contentDigest(fs.readFileSync(entry.file))
  if (currentDigest !== entry.sha256) {
    return { ...entry, action: 'keep', detail: 'managed file was modified' }
  }
  return { ...entry, action: 'remove', detail: 'removes stale managed file' }
}

/** Plan a provider skill root without following an unowned symlink. */
export function planSkillLinkDirectory(dir) {
  const at = classify(dir)
  if (at.kind === 'absent') return { dir, action: 'create', detail: 'creates directory' }
  if (at.kind === 'directory') return { dir, action: 'use', detail: 'uses existing directory' }
  if (at.kind === 'symlink') {
    return {
      dir,
      action: 'refuse-symlink',
      detail: `symlink → ${at.resolved}`,
      resolved: at.resolved,
    }
  }
  return { dir, action: 'refuse', detail: 'a file exists here' }
}

/** Prepare a planned provider skill root, replacing only an explicitly approved symlink. */
export function prepareSkillLinkDirectory(plan, { replaceSymlinks = false } = {}) {
  if (plan.action === 'refuse') throw new Error(`${plan.dir}: ${plan.detail}`)
  if (plan.action === 'refuse-symlink' && !replaceSymlinks) {
    throw new Error(
      `${plan.dir} is a symlink → ${plan.resolved}. Writing below it would modify ` +
        `that directory. Re-run with --replace-symlinks to replace the link itself.`,
    )
  }
  if (plan.action === 'refuse-symlink') fs.unlinkSync(plan.dir)
  fs.mkdirSync(plan.dir, { recursive: true })
  return {
    ...plan,
    applied: plan.action === 'refuse-symlink' ? 'replaced-symlink' : plan.action,
  }
}

/** Remove a receipt-owned skill path only through a real parent directory. */
export function removeSkillPath(file) {
  const parent = path.dirname(file)
  const at = classify(parent)
  if (at.kind === 'symlink') {
    return {
      file,
      removed: false,
      reason: `parent is a symlink → ${at.resolved}; refusing to remove through it`,
    }
  }
  if (at.kind === 'absent') return { file, removed: true }
  if (at.kind !== 'directory') {
    return { file, removed: false, reason: `parent is ${at.kind}` }
  }
  fs.rmSync(file, { recursive: true, force: true })
  return { file, removed: true }
}

/** Copy a skill directory, replacing any previous copy of the same skill. */
export class SkillInstallRecoveryError extends Error {
  constructor(destination, recoveryPath, cause) {
    super(
      `Failed to install skill at ${destination}; previous copy remains at ${recoveryPath}. ` +
        'Resolve the conflicting destination before recovering it.',
      { cause },
    )
    this.name = 'SkillInstallRecoveryError'
    this.destination = destination
    this.recoveryPath = recoveryPath
  }
}

export function installSkill(sourceDir, destDir) {
  const parent = path.dirname(destDir)
  const at = classify(parent)
  if (at.kind === 'symlink') {
    throw new Error(`${parent} is a symlink → ${at.resolved}; refusing to write through it`)
  }
  if (at.kind === 'file') throw new Error(`${parent} is a file; expected a directory`)
  fs.mkdirSync(parent, { recursive: true })
  const stagingParent = fs.mkdtempSync(path.join(parent, `.${path.basename(destDir)}-`))
  const staged = path.join(stagingParent, path.basename(destDir))
  const previous = path.join(stagingParent, 'previous')
  let movedPrevious = false
  let preserveRecoveryCopy = false
  try {
    fs.cpSync(sourceDir, staged, { recursive: true })
    if (classify(destDir).kind !== 'absent') {
      fs.renameSync(destDir, previous)
      movedPrevious = true
    }
    try {
      fs.renameSync(staged, destDir)
    } catch (err) {
      if (movedPrevious) {
        try {
          fs.renameSync(previous, destDir)
        } catch (rollbackErr) {
          preserveRecoveryCopy = true
          throw new SkillInstallRecoveryError(destDir, previous, rollbackErr)
        }
      }
      throw err
    }
  } finally {
    if (!preserveRecoveryCopy) fs.rmSync(stagingParent, { recursive: true, force: true })
  }
}

/**
 * Link a skill into an agent-specific directory.
 *
 * Absolute targets make the installed destination explicit when inspecting it
 * with filesystem tools. Falls back to a copy where symlinks are unavailable,
 * which is Windows without Developer Mode more often than anything else.
 */
export function linkSkill(canonicalDir, linkPath, { copy = false } = {}) {
  const parent = path.dirname(linkPath)
  const at = classify(parent)
  if (at.kind === 'symlink') {
    throw new Error(`${parent} is a symlink → ${at.resolved}; refusing to write through it`)
  }
  if (at.kind === 'file') throw new Error(`${parent} is a file; expected a directory`)
  fs.rmSync(linkPath, { recursive: true, force: true })
  fs.mkdirSync(parent, { recursive: true })
  if (copy) {
    fs.cpSync(canonicalDir, linkPath, { recursive: true })
    return 'copy'
  }
  const target = path.resolve(canonicalDir)
  try {
    fs.symlinkSync(target, linkPath, 'dir')
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

export function prepareReceiptWrite(file) {
  const parent = path.dirname(file)
  fs.mkdirSync(parent, { recursive: true })
  fs.accessSync(parent, fs.constants.W_OK)
}

export function writeReceipt(file, receipt) {
  const parent = path.dirname(file)
  prepareReceiptWrite(file)
  const stagingParent = fs.mkdtempSync(path.join(parent, `.${path.basename(file)}-`))
  const staged = path.join(stagingParent, path.basename(file))
  try {
    fs.writeFileSync(staged, JSON.stringify(receipt, null, 2) + '\n', 'utf8')
    fs.renameSync(staged, file)
  } finally {
    fs.rmSync(stagingParent, { recursive: true, force: true })
  }
}
