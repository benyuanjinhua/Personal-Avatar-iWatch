#!/usr/bin/env node
// ESS-56 / G8 门禁：开测前确认手表上装的是待验收 build。
//
//   node Scripts/watch-build-gate.mjs --log <bridge.log> --rev <commit-ish> [--repo <path>]
//   node Scripts/watch-build-gate.mjs --log <bridge.log> --built-after <ISO8601>
//
// 退出码 0 = 可以开测；非 0 = 不要开测（原因见输出）。
// R3 那轮如果先跑过这条命令，会直接被拦下，白梦林不必白做 17 次按住说话。

import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { latestWatchColdStart, evaluateBuildGate } from '../MacRemoteFrontendBridge/watch-build.mjs'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function parseArgs(argv) {
  const args = {}
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]
    if (!token.startsWith('--')) continue
    const key = token.slice(2)
    const next = argv[i + 1]
    if (next === undefined || next.startsWith('--')) { args[key] = true; continue }
    args[key] = next
    i += 1
  }
  return args
}

function fail(message) {
  process.stderr.write(`${message}\n`)
  process.exit(2)
}

function commitTime(rev, repo) {
  try {
    return execFileSync('git', ['-C', repo, 'log', '-1', '--format=%cI', rev], { encoding: 'utf8' }).trim()
  } catch {
    fail(`无法在 ${repo} 解析 commit ${rev} 的提交时间`)
  }
}

const args = parseArgs(process.argv.slice(2))
if (args.help || (!args.log && !args.stdin)) {
  process.stdout.write(
    'usage: watch-build-gate.mjs --log <bridge.log> (--rev <commit-ish> [--repo <path>] | --built-after <ISO8601>)\n'
  )
  process.exit(args.help ? 0 : 2)
}
if (!args.rev && !args['built-after']) fail('必须给 --rev 或 --built-after 之一')

const requiredBuiltAfter = args['built-after'] || commitTime(args.rev, args.repo || REPO_ROOT)

let raw
try {
  raw = readFileSync(args.log, 'utf8')
} catch (error) {
  fail(`读不到日志文件 ${args.log}：${error.message}`)
}

const coldStart = latestWatchColdStart(raw.split('\n'))
const verdict = evaluateBuildGate({ coldStart, requiredBuiltAfter })

process.stdout.write(`${verdict.pass ? 'PASS' : 'FAIL'} [${verdict.code}] ${verdict.message}\n`)
if (coldStart) {
  process.stdout.write(
    `  最近一次手表冷启动：bridge_ts=${coldStart.observedAt?.toISOString() ?? '?'} ` +
    `watch_ts=${coldStart.watchTs ?? '?'} detail=${JSON.stringify(coldStart.detail)}\n`
  )
}
process.exit(verdict.pass ? 0 : 1)
