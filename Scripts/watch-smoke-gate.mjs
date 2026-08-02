#!/usr/bin/env node
// ESS-65 / G9 门禁：装机后 App 自动跑的音频自检（录音/播放/交替/会话复位）
// 是否在待验收 build 上通过。
//
//   node Scripts/watch-smoke-gate.mjs --log <bridge.log> --rev <commit-ish> [--repo <path>]
//   node Scripts/watch-smoke-gate.mjs --log <bridge.log> --built-after <ISO8601>
//
// 退出码 0 = 音频链路可用，可以进入人工验收；非 0 = 不要开测（原因见输出）。
// G8（watch-build-gate.mjs）拦「装的是旧包」，本门禁拦「新包不能用」——
// ESS-61 那个 -50 若早有此门禁，S3 会在白梦林抬腕前就 FAIL。

import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { latestSelfCheckFinished, evaluateSmokeGate } from '../MacRemoteFrontendBridge/watch-smoke.mjs'
import { parseArgs, resolveRequiredBuiltAfter, readLogLines } from './gate-cli.mjs'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const args = parseArgs(process.argv.slice(2))
if (args.help || !args.log) {
  process.stdout.write(
    'usage: watch-smoke-gate.mjs --log <bridge.log> (--rev <commit-ish> [--repo <path>] | --built-after <ISO8601>)\n'
  )
  process.exit(args.help ? 0 : 2)
}

const requiredBuiltAfter = resolveRequiredBuiltAfter(args, REPO_ROOT)
const selfCheck = latestSelfCheckFinished(readLogLines(args.log))
const verdict = evaluateSmokeGate({ selfCheck, requiredBuiltAfter })

process.stdout.write(`${verdict.pass ? 'PASS' : 'FAIL'} [${verdict.code}] ${verdict.message}\n`)
if (selfCheck) {
  process.stdout.write(
    `  最近一次装机自检：bridge_ts=${selfCheck.observedAt?.toISOString() ?? '?'} ` +
    `watch_ts=${selfCheck.watchTs ?? '?'} detail=${JSON.stringify(selfCheck.detail)}` +
    `${selfCheck.errorCode ? ` error_code=${selfCheck.errorCode}` : ''}\n`
  )
}
process.exit(verdict.pass ? 0 : 1)
