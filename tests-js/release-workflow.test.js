import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { test } from 'node:test'

import { parse as parseYaml } from 'yaml'

import { ROOT } from '../test-utils/repository.js'

const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'release.yml')

test('release workflow uses bare numeric-looking tags and validates full semver', () => {
  const source = fs.readFileSync(WORKFLOW, 'utf8')
  const workflow = parseYaml(source)
  assert.deepEqual(workflow.on.push.tags, ['[0-9]*.[0-9]*.[0-9]*'])

  const verify = workflow.jobs.verify.steps.find((step) => step.name === 'Tag must match the manifests')
  assert.ok(verify, 'release workflow must verify its tag before publishing')
  assert.match(verify.run, /tag="\$GITHUB_REF_NAME"/)
  assert.match(verify.run, /bump-version\.mjs "\$tag" --check/)
  assert.doesNotMatch(verify.run, /#v/)
})
