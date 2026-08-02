#!/usr/bin/env node
// ESS-65：人工验收前置门禁合并入口——一条命令同时判 G8（装的是不是新包）
// 与 G9（新包能不能用），输出两行结论。
//
//   node Scripts/preflight.mjs --log <bridge.log> --rev <commit-ish> [--repo <path>]
//   node Scripts/preflight.mjs --log <bridge.log> --built-after <ISO8601>
//
// 退出码 0 = 双门禁 PASS，可以进入 R4 人工验收（A1–A10）；非 0 = 不要开测。
// 白梦林的动作：装机 → 打开 App → 等自检跑完（约 10 秒）→ PM 跑本命令。

import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { latestWatchColdStart, evaluateBuildGate } from '../MacRemoteFrontendBridge/watch-build.mjs'
import { latestSelfCheckFinished, evaluateSmokeGate } from '../MacRemoteFrontendBridge/watch-smoke.mjs'
import { parseArgs, resolveRequiredBuiltAfter, readLogLines } from './gate-cli.mjs'

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const args = parseArgs(process.argv.slice(2))
if (args.help || !args.log) {
  process.stdout.write(
    'usage: preflight.mjs --log <bridge.log> (--rev <commit-ish> [--repo <path>] | --built-after <ISO8601>)\n'
  )
  process.exit(args.help ? 0 : 2)
}

const requiredBuiltAfter = resolveRequiredBuiltAfter(args, REPO_ROOT)
const lines = readLogLines(args.log)

const g8 = evaluateBuildGate({ coldStart: latestWatchColdStart(lines), requiredBuiltAfter })
const g9 = evaluateSmokeGate({ selfCheck: latestSelfCheckFinished(lines), requiredBuiltAfter })

process.stdout.write(`G8 装机指纹：${g8.pass ? 'PASS' : 'FAIL'} [${g8.code}] ${g8.message}\n`)
process.stdout.write(`G9 装机自检：${g9.pass ? 'PASS' : 'FAIL'} [${g9.code}] ${g9.message}\n`)
process.exit(g8.pass && g9.pass ? 0 : 1)
