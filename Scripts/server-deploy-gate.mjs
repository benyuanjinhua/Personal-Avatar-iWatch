#!/usr/bin/env node
// ESS-870: block install notifications when the production server checkout
// does not exactly match the intended main commit.

import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import process from 'node:process'

function usage() {
  return 'usage: server-deploy-gate.mjs --deploy <path> [--expected <commit-ish>]\n'
}

export function parseArgs(argv) {
  const args = { expected: 'origin/main' }
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--deploy') args.deploy = argv[++i]
    else if (argv[i] === '--expected') args.expected = argv[++i]
    else throw new Error(`unknown argument: ${argv[i]}`)
  }
  if (!args.deploy) throw new Error('--deploy is required')
  return args
}

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim()
}

export function evaluateDeployment({ deploy, expected = 'origin/main' }) {
  const repo = resolve(deploy)
  const deployedSha = git(repo, ['rev-parse', 'HEAD'])
  const expectedSha = git(repo, ['rev-parse', expected])
  const serverDrift = git(repo, [
    'status', '--porcelain', '--untracked-files=no', '--',
    'AudioRealtimeGateway', 'MacRemoteFrontendBridge',
  ])
  return {
    ok: deployedSha === expectedSha && serverDrift.length === 0,
    deploy: repo,
    expected_ref: expected,
    deployed_sha: deployedSha,
    expected_sha: expectedSha,
    server_drift: serverDrift ? serverDrift.split('\n') : [],
  }
}

export function main(argv = process.argv.slice(2)) {
  try {
    const result = evaluateDeployment(parseArgs(argv))
    process.stdout.write(JSON.stringify({ evt: 'server_deploy_gate', ...result }) + '\n')
    return result.ok ? 0 : 1
  } catch (error) {
    process.stderr.write(usage())
    process.stderr.write(`server deploy gate error: ${error.message}\n`)
    return 2
  }
}

if (process.argv[1] && import.meta.url === new URL(`file://${resolve(process.argv[1])}`).href) {
  process.exitCode = main()
}
