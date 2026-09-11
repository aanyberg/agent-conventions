import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { test } from 'node:test'

import { parse as parseYaml } from 'yaml'

import { ROOT } from '../test-utils/repository.js'

const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'release.yml')
const VALIDATE_WORKFLOW = path.join(ROOT, '.github', 'workflows', 'validate.yml')

test('release workflow uses bare numeric-looking tags and validates full semver', () => {
  const source = fs.readFileSync(WORKFLOW, 'utf8')
  const workflow = parseYaml(source)
  assert.deepEqual(workflow.on.push.tags, ['[0-9]*.[0-9]*.[0-9]*'])

  const verify = workflow.jobs.verify.steps.find((step) => step.name === 'Tag must match the manifests')
  assert.ok(verify, 'release workflow must verify its tag before publishing')
  assert.match(verify.run, /tag="\$GITHUB_REF_NAME"/)
  assert.match(verify.run, /bump-version\.mjs "\$tag" --check/)
  assert.doesNotMatch(verify.run, /#v/)
}),

test('release workflow pins npm to a Node 20-compatible major', () => {
  const source = fs.readFileSync(WORKFLOW, 'utf8')
  const workflow = parseYaml(source)
  const installNpm = workflow.jobs.publish.steps.find((step) => step.run?.includes('npm install -g npm@'))

  assert.ok(installNpm, 'publish job must install npm for trusted publishing')
  assert.match(installNpm.run, /^npm install -g npm@11$/)
  assert.doesNotMatch(installNpm.run, /npm@latest/)
  assert.ok(
    workflow.jobs.publish.steps.some((step) => step.run === 'npm stage publish --access public'),
    'publish job must stage rather than directly publish the package',)
}),

test('validation runs on the minimum supported and release Node.js versions', () => {
  const workflow = parseYaml(fs.readFileSync(VALIDATE_WORKFLOW, 'utf8'))
  assert.deepEqual(workflow.jobs.validate.strategy.matrix.node, ['18.17', '20'])
  const setup = workflow.jobs.validate.steps.find((step) => step.uses === 'actions/setup-node@v4')
  assert.equal(setup.with['node-version'], '${{ matrix.node }}')
})
