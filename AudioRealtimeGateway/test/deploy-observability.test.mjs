// ESS-887: gateway_ready 带可追溯的部署锚点（git_sha + 工作区 clean/dirty）。
// readDeployState 是纯函数（env/cwd 可注入），本套用临时 git 仓库构造
// 干净 / 脏 / 非 git 三种状态，验证三项字段的判定与优雅降级。

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { execSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { readDeployState } from '../server.mjs'

function makeRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'gw-deploy-state-'))
  const git = args => execSync(`git ${args}`, { cwd: dir, encoding: 'utf8' }).trim()
  git('init -q -b main')
  git('config user.email test@example.com')
  git('config user.name "deploy-test"')
  writeFileSync(join(dir, 'server.mjs'), 'export const x = 1\n')
  git('add server.mjs')
  git('commit -q -m init')
  return { dir, git }
}

test('clean repo → git_sha=HEAD, git_clean=true, dirty_count=0', () => {
  const { dir, git } = makeRepo()
  const state = readDeployState({ cwd: dir })
  assert.equal(state.git_sha, git('rev-parse HEAD'))
  assert.equal(state.git_clean, true)
  assert.equal(state.git_dirty_count, 0)
})

test('untracked file → git_clean=false, dirty_count=1', () => {
  const { dir } = makeRepo()
  writeFileSync(join(dir, 'hotfix.txt'), 'x\n')
  const state = readDeployState({ cwd: dir })
  assert.equal(state.git_clean, false)
  assert.equal(state.git_dirty_count, 1)
})

test('modified tracked file → dirty', () => {
  const { dir } = makeRepo()
  appendFileSync(join(dir, 'server.mjs'), '\nexport const y = 2\n')
  const state = readDeployState({ cwd: dir })
  assert.equal(state.git_clean, false)
  assert.equal(state.git_dirty_count, 1)
})

test('DEPLOY_SHA 覆盖 git 解析', () => {
  const { dir } = makeRepo()
  const state = readDeployState({ env: { DEPLOY_SHA: 'deadbeef' }, cwd: dir })
  assert.equal(state.git_sha, 'deadbeef')
})

test('非 git 目录 → 三项均为 null，优雅降级', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gw-deploy-nogit-'))
  const state = readDeployState({ cwd: dir })
  assert.equal(state.git_sha, null)
  assert.equal(state.git_clean, null)
  assert.equal(state.git_dirty_count, null)
})

test('非 git 目录但注入 DEPLOY_SHA → sha 保留，clean/dirty 为 null', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gw-deploy-nogit-'))
  const state = readDeployState({ env: { DEPLOY_SHA: 'abc123' }, cwd: dir })
  assert.equal(state.git_sha, 'abc123')
  assert.equal(state.git_clean, null)
  assert.equal(state.git_dirty_count, null)
})
