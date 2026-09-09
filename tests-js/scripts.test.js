/**
 * Behavioural tests for the shell scripts the package ships.
 *
 * Each test runs the real script in a throwaway git repository with a
 * controllable `gh` stub, so no test depends on GitHub auth or the network.
 */

import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, test } from 'node:test'

import { parse as parseYaml } from 'yaml'

import { shellcheckPath } from '../scripts/ensure-shellcheck.mjs'
import { ROOT, relative, shellScripts } from '../test-utils/repository.js'

const SCRIPTS = path.join(ROOT, 'skills', 'backlog-management', 'scripts')
const DETECT = path.join(SCRIPTS, 'detect-backend.sh')
const GENERATE = path.join(SCRIPTS, 'generate-policy.sh')
const TEMPLATE = path.join(ROOT, 'policy.example.yml')

const GH_STUB = `#!/usr/bin/env bash
case "$1 \${2:-}" in
  "auth status") [[ "\${STUB_GH_AUTHED:-0}" == "1" ]] && exit 0 || exit 1 ;;
esac
if [[ "$1" == "api" ]]; then
  [[ "\${STUB_GH_AUTHED:-0}" == "1" ]] || exit 1
  echo "\${STUB_GH_HAS_ISSUES:-false}"
  exit 0
fi
exit 1
`

function sandbox(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-conventions-scripts-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: root })

  const stubBin = path.join(root, 'stub-bin')
  fs.mkdirSync(stubBin)
  const gh = path.join(stubBin, 'gh')
  fs.writeFileSync(gh, GH_STUB)
  fs.chmodSync(gh, 0o755)
  return { root, stubBin }
}

function run(script, cwd, stubBin, stubEnv = {}) {
  return spawnSync('bash', [script], {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${stubBin}${path.delimiter}${process.env.PATH ?? ''}`,
      ...stubEnv,
    },
  })
}

function writePolicy(root, backendLine) {
  const planning = path.join(root, '.planning')
  fs.mkdirSync(planning, { recursive: true })
  fs.writeFileSync(
    path.join(planning, 'policy.yml'),
    `backlog:
  ${backendLine}
  render_file: BACKLOG.md
`,
  )
}

function addGithubRemote(root) {
  execFileSync(
    'git',
    ['remote', 'add', 'origin', 'https://github.com/example/repo.git'],
    { cwd: root },
  )
}

describe('detect-backend.sh', () => {
  test('reports none in an empty repo', (t) => {
    const { root, stubBin } = sandbox(t)
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout.trim(), 'none')
    assert.equal(result.status, 1, 'callers branch on the exit code, not just the output')
  })

  test('falls back to markdown when a backlog file exists', (t) => {
    const { root, stubBin } = sandbox(t)
    fs.writeFileSync(path.join(root, 'BACKLOG.md'), '# Backlog\n')
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout.trim(), 'markdown')
    assert.equal(result.status, 0)
  })

  for (const [backendLine, expected] of [
    ['backend: markdown', 'markdown'],
    ['backend: github-issues', 'github-issues'],
    ['backend: markdown # pinned by hand', 'markdown'],
    ['backend:   markdown', 'markdown'],
  ]) {
    test(`honours an explicit backend: ${backendLine}`, (t) => {
      const { root, stubBin } = sandbox(t)
      writePolicy(root, backendLine)
      const result = run(DETECT, root, stubBin)
      assert.equal(result.stdout.trim(), expected)
      assert.equal(
        result.stdout.trim(),
        result.stdout.trim().trim(),
        `output ${JSON.stringify(result.stdout)} carries stray whitespace; callers compare it literally`,
      )
    })
  }

  test('output has no surrounding whitespace', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: markdown')
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout, 'markdown\n')
  })

  test('prefers auto detection over backend auto', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: auto')
    fs.writeFileSync(path.join(root, 'BACKLOG.md'), '# Backlog\n')
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout.trim(), 'markdown')
  })

  test('uses GitHub when auto and issues are enabled', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: auto')
    addGithubRemote(root)
    const result = run(DETECT, root, stubBin, {
      STUB_GH_AUTHED: '1',
      STUB_GH_HAS_ISSUES: 'true',
    })
    assert.equal(result.stdout.trim(), 'github-issues')
  })

  test('ignores GitHub when gh is not authenticated', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: auto')
    addGithubRemote(root)
    fs.writeFileSync(path.join(root, 'BACKLOG.md'), '# Backlog\n')
    const result = run(DETECT, root, stubBin, { STUB_GH_AUTHED: '0' })
    assert.equal(result.stdout.trim(), 'markdown')
  })

  test('ignores GitHub when issues are disabled', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: auto')
    addGithubRemote(root)
    fs.writeFileSync(path.join(root, 'BACKLOG.md'), '# Backlog\n')
    const result = run(DETECT, root, stubBin, {
      STUB_GH_AUTHED: '1',
      STUB_GH_HAS_ISSUES: 'false',
    })
    assert.equal(result.stdout.trim(), 'markdown')
  })

  test('guards against an incomplete GitHub migration', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: github-issues')
    fs.writeFileSync(path.join(root, 'BACKLOG.md'), '| 001 | do a thing | ready |\n')
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout.trim(), 'markdown')
    assert.match(result.stderr, /migration incomplete/, 'the reason must reach stderr')
    assert.equal(result.status, 0)
  })

  test('trusts GitHub once migration is recorded', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: github-issues')
    fs.writeFileSync(path.join(root, 'BACKLOG.md'), '| 001 | do a thing | ready |\n')
    fs.writeFileSync(path.join(root, '.planning', 'backlog-migration.json'), '{}')
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout.trim(), 'github-issues')
  })

  test('ignores a rendered backlog with no live rows', (t) => {
    const { root, stubBin } = sandbox(t)
    writePolicy(root, 'backend: github-issues')
    fs.writeFileSync(
      path.join(root, 'BACKLOG.md'),
      '# Backlog\n\nRendered from GitHub Issues.\n',
    )
    const result = run(DETECT, root, stubBin)
    assert.equal(result.stdout.trim(), 'github-issues')
  })
})

describe('generate-policy.sh', () => {
  test('creates a policy file', (t) => {
    const { root, stubBin } = sandbox(t)
    const result = run(GENERATE, root, stubBin)
    assert.equal(result.status, 0, result.stderr)
    const generated = path.join(root, '.planning', 'policy.yml')
    assert.ok(fs.statSync(generated).isFile())
    const policy = parseYaml(fs.readFileSync(generated, 'utf8'))
    assert.ok(policy && typeof policy === 'object' && !Array.isArray(policy))
  })

  test('differs from the template only in the backend line', (t) => {
    const { root, stubBin } = sandbox(t)
    run(GENERATE, root, stubBin)
    const generated = fs.readFileSync(path.join(root, '.planning', 'policy.yml'), 'utf8').split('\n')
    const template = fs.readFileSync(TEMPLATE, 'utf8').split('\n')
    assert.equal(generated.length, template.length, 'generation must not add or drop lines')
    const differences = template.flatMap((line, index) => (
      line === generated[index] ? [] : [[line, generated[index]]]
    ))
    assert.deepEqual(differences, [['  backend: auto', '  backend: markdown']])
  })

  test('is idempotent', (t) => {
    const { root, stubBin } = sandbox(t)
    run(GENERATE, root, stubBin)
    const generated = path.join(root, '.planning', 'policy.yml')
    fs.writeFileSync(
      generated,
      fs.readFileSync(generated, 'utf8').replace('markdown', 'github-issues'),
    )
    const edited = fs.readFileSync(generated, 'utf8')

    const second = run(GENERATE, root, stubBin)
    assert.equal(second.status, 0)
    assert.equal(
      fs.readFileSync(generated, 'utf8'),
      edited,
      'a second run must never overwrite local edits',
    )
    assert.match(second.stdout, /already exists/)
  })

  test('detects GitHub issues', (t) => {
    const { root, stubBin } = sandbox(t)
    addGithubRemote(root)
    const result = run(GENERATE, root, stubBin, {
      STUB_GH_AUTHED: '1',
      STUB_GH_HAS_ISSUES: 'true',
    })
    const policy = parseYaml(
      fs.readFileSync(path.join(root, '.planning', 'policy.yml'), 'utf8'),
    )
    assert.equal(policy.backlog.backend, 'github-issues')
    assert.match(result.stdout, /github-issues/, 'the report must state what it detected')
  })

  test('defaults to markdown without GitHub', (t) => {
    const { root, stubBin } = sandbox(t)
    const result = run(GENERATE, root, stubBin)
    const policy = parseYaml(
      fs.readFileSync(path.join(root, '.planning', 'policy.yml'), 'utf8'),
    )
    assert.equal(policy.backlog.backend, 'markdown')
    assert.match(result.stdout, /markdown/)
  })

  test('fails loudly when the template is missing', (t) => {
    const { root, stubBin } = sandbox(t)
    const copied = path.join(root, 'plugin-copy')
    const scripts = path.join(copied, 'skills', 'backlog-management', 'scripts')
    fs.mkdirSync(scripts, { recursive: true })
    fs.copyFileSync(GENERATE, path.join(scripts, path.basename(GENERATE)))
    assert.ok(!fs.existsSync(path.join(copied, 'policy.example.yml')))

    const result = run(path.join(scripts, 'generate-policy.sh'), root, stubBin)
    assert.equal(result.status, 1)
    assert.match(result.stderr, /Template not found/)
    assert.ok(
      !fs.existsSync(path.join(root, '.planning', 'policy.yml')),
      'must not leave a partial file',
    )
  })
})

describe('the two scripts together', () => {
  for (const [authed, hasIssues, expected] of [
    ['0', 'false', 'markdown'],
    ['1', 'true', 'github-issues'],
  ]) {
    test(`generated ${expected} policy is read back identically`, (t) => {
      const { root, stubBin } = sandbox(t)
      addGithubRemote(root)
      const stubEnv = { STUB_GH_AUTHED: authed, STUB_GH_HAS_ISSUES: hasIssues }
      run(GENERATE, root, stubBin, stubEnv)
      const result = run(DETECT, root, stubBin, stubEnv)
      assert.equal(
        result.stdout,
        `${expected}\n`,
        `generate-policy.sh wrote ${JSON.stringify(expected)} but ` +
          `detect-backend.sh returned ${JSON.stringify(result.stdout)}`,
      )
    })
  }
})

const SHELLCHECK = shellcheckPath()

describe('static analysis', () => {
  test('shellcheck is available', () => {
    assert.ok(
      fs.existsSync(SHELLCHECK),
      'shellcheck not available — is the dev dependency installed?',
    )
    if (process.platform !== 'win32') fs.accessSync(SHELLCHECK, fs.constants.X_OK)
  })

  for (const script of shellScripts()) {
    test(`${relative(script)} is shellcheck-clean`, () => {
      const result = spawnSync(
        SHELLCHECK,
        ['--severity=warning', '--shell=bash', script],
        { encoding: 'utf8' },
      )
      assert.equal(result.status, 0, `\n${result.stdout}${result.stderr}`)
    })
  }
})

const GNU_ONLY_ESCAPES = new Map([
  ['\\s', '[[:space:]]'],
  ['\\S', '[^[:space:]]'],
  ['\\d', '[[:digit:]]'],
  ['\\D', '[^[:digit:]]'],
  ['\\w', '[[:alnum:]_]'],
  ['\\W', '[^[:alnum:]_]'],
  ['\\b', 'an explicit delimiter'],
  ['\\B', 'an explicit delimiter'],
])

const GNU_ONLY_FLAGS = new Map([
  ['grep -P', 'BSD grep has no PCRE mode; use -E with POSIX classes'],
  ['sed -i ', "BSD sed requires a backup suffix; use `sed -i ''` or a temp file"],
  ['readlink -f', 'BSD readlink has no -f; use a cd/pwd subshell'],
  ['date -d', 'BSD date has no -d; use -j -f'],
])

function regexLines(script) {
  return fs.readFileSync(script, 'utf8').split('\n').flatMap((line, index) => (
    (line.includes('sed') || line.includes('grep')) && !line.trimStart().startsWith('#')
      ? [[index + 1, line]]
      : []
  ))
}

describe('portability', () => {
  for (const script of shellScripts()) {
    test(`${relative(script)} has no GNU-only regex escapes`, () => {
      const findings = regexLines(script).flatMap(([lineNumber, line]) => (
        [...GNU_ONLY_ESCAPES].flatMap(([escape, replacement]) => (
          line.includes(escape)
            ? [`line ${lineNumber}: ${JSON.stringify(escape)} is GNU-only — ` +
              `use ${replacement} (${line.trim()})`]
            : []
        ))
      ))
      assert.deepEqual(
        findings,
        [],
        `${relative(script)} would behave differently under BSD sed/grep:\n  ` +
          findings.join('\n  '),
      )
    })

    test(`${relative(script)} has no GNU-only flags`, () => {
      const text = fs.readFileSync(script, 'utf8')
      const findings = [...GNU_ONLY_FLAGS].flatMap(([flag, why]) => (
        text.includes(flag) ? [`${JSON.stringify(flag)}: ${why}`] : []
      ))
      assert.deepEqual(findings, [], `${relative(script)}:\n  ${findings.join('\n  ')}`)
    })
  }
})
