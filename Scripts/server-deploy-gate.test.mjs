import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { evaluateDeployment } from './server-deploy-gate.mjs'

function git(repo, ...args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim()
}

function fixture() {
  const repo = mkdtempSync(join(tmpdir(), 'ess870-deploy-gate-'))
  git(repo, 'init', '-q')
  git(repo, 'config', 'user.name', 'ESS-870 test')
  git(repo, 'config', 'user.email', 'ess870@example.invalid')
  mkdirSync(join(repo, 'AudioRealtimeGateway'))
  writeFileSync(join(repo, 'AudioRealtimeGateway', 'server.mjs'), 'v1\n')
  git(repo, 'add', '.')
  git(repo, 'commit', '-qm', 'v1')
  const oldSha = git(repo, 'rev-parse', 'HEAD')
  writeFileSync(join(repo, 'AudioRealtimeGateway', 'server.mjs'), 'v2\n')
  git(repo, 'commit', '-qam', 'v2')
  const tipSha = git(repo, 'rev-parse', 'HEAD')
  return { repo, oldSha, tipSha }
}

test('passes only at the expected clean commit', () => {
  const { repo, tipSha } = fixture()
  assert.equal(evaluateDeployment({ deploy: repo, expected: tipSha }).ok, true)
})

test('blocks a deployment deliberately left one commit behind', () => {
  const { repo, oldSha, tipSha } = fixture()
  git(repo, 'checkout', '-q', oldSha)
  const result = evaluateDeployment({ deploy: repo, expected: tipSha })
  assert.equal(result.ok, false)
  assert.equal(result.deployed_sha, oldSha)
  assert.equal(result.expected_sha, tipSha)
})

test('blocks tracked server drift even when HEAD matches', () => {
  const { repo, tipSha } = fixture()
  writeFileSync(join(repo, 'AudioRealtimeGateway', 'server.mjs'), 'manual patch\n')
  const result = evaluateDeployment({ deploy: repo, expected: tipSha })
  assert.equal(result.ok, false)
  assert.deepEqual(result.server_drift, ['M AudioRealtimeGateway/server.mjs'])
})
