#!/usr/bin/env node
// ESS-56 / G8 门禁：开测前确认手表上装的是待验收 build。
//
//   node Scripts/watch-build-gate.mjs --log <bridge.log> --rev <commit-ish> [--repo <path>]
//   node Scripts/watch-build-gate.mjs --log <bridge.log> --built-after <ISO8601>
//
// 退出码 0 = 可以开测；非 0 = 不要开测（原因见输出）。
// R3 那轮如果先跑过这条命令，会直接被拦下，白梦林不必白做 17 次按住说话。
// CLI 公共部分在 Scripts/gate-cli.mjs（ESS-65 抽取，与 G9/preflight 共用）。

import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { latestWatchColdStart, evaluateBuildGate } from '../MacRemoteFrontendBridge/watch-build.mjs'
import { parseArgs, resolveRequiredBuiltAfter, readLogLines } from './gate-cli.mjs'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const args = parseArgs(process.argv.slice(2))
if (args.help || !args.log) {
  process.stdout.write(
    'usage: watch-build-gate.mjs --log <bridge.log> (--rev <commit-ish> [--repo <path>] | --built-after <ISO8601>)\n'
  )
  process.exit(args.help ? 0 : 2)
}

const requiredBuiltAfter = resolveRequiredBuiltAfter(args, REPO_ROOT)
const coldStart = latestWatchColdStart(readLogLines(args.log))
const verdict = evaluateBuildGate({ coldStart, requiredBuiltAfter })

process.stdout.write(`${verdict.pass ? 'PASS' : 'FAIL'} [${verdict.code}] ${verdict.message}\n`)
if (coldStart) {
  process.stdout.write(
    `  最近一次手表冷启动：bridge_ts=${coldStart.observedAt?.toISOString() ?? '?'} ` +
    `watch_ts=${coldStart.watchTs ?? '?'} detail=${JSON.stringify(coldStart.detail)}\n`
  )
}
process.exit(verdict.pass ? 0 : 1)
