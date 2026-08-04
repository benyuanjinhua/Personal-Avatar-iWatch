#!/usr/bin/env node
// ESS-184：下行链路探针裁决 CLI —— 从 bridge.log 里判定固定语音下发到手表
// 的端到端路径是否走通。G8/G9 只证明「装的是新包 / 本地音频链路能用」，都不
// 经过下行通道；这条命令补的是「Mac 生成语音 → 手表实际听得到 + Bridge 收到
// 回执」这一段。
//
//   node Scripts/downlink-probe.mjs --log <bridge.log> --request-id <probe-id> [--timeout 60] [--since <RFC3339>]
//
// 退出码 0 = 5 跳齐、耗时在阈值内；非 0 = 未通过（原因见输出）。
//
// 前置：调用方需要先发起一次探针注入 —— 见「探针注入怎么产生」小节。本 CLI 只
// 判定；不注入。
//
// 探针注入怎么产生（本单 Bridge 侧已就绪，Watch/iOS 侧走子单 —— 见 issue
// 评论 §「实施进度」）：
// 1. 预生成音频：`node MacRemoteFrontendBridge/generate-probe-audio.mjs \
//        ./audiopipe ./Watch/Resources/ProbeSpeech.m4a`
//    （前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行；文案固定为
//    「你好Jackson，我是你的数字分身」——白梦林 2026-08-03 拍板）
// 2. 由 Bridge 端注入下行（后续 PR）：以 kind=probe 打包成 turn.state completed
//    经 WSS 下发；ESS-57 白名单已在本单里开了 kind=probe 的门。
// 3. Watch/iOS 侧处理 kind=probe（子单 ESS-186）：不走 journal/ledger 生产链路，
//    直接播放 + 回执 probe_acked。
// 4. 本 CLI 读 bridge.log 判 5 跳。
//
// 判定原则与 G8/G9 一致，全部 fail-closed。

import { readFileSync } from 'node:fs'
import { parseArgs } from './gate-cli.mjs'
import {
  HOP_DESCRIPTIONS,
  PROBE,
  evaluateProbe,
  parseProbeHops,
} from '../MacRemoteFrontendBridge/downlink-probe.mjs'

const USAGE =
  'usage: downlink-probe.mjs --log <bridge.log> --request-id <probe-id> [--timeout <sec>] [--since <RFC3339>]\n'

const args = parseArgs(process.argv.slice(2))
if (args.help || !args.log || !args['request-id']) {
  process.stdout.write(USAGE)
  process.exit(args.help ? 0 : 2)
}

const requestId = String(args['request-id'])
const timeoutMs = args.timeout ? Math.round(Number(args.timeout) * 1000) : 60_000
if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
  process.stderr.write(`--timeout 无法解析为正数秒：${args.timeout}\n`)
  process.exit(2)
}

let lines
try {
  lines = readFileSync(args.log, 'utf8').split('\n')
} catch (error) {
  process.stderr.write(`读不到日志文件 ${args.log}：${error.message}\n`)
  process.exit(2)
}

let since = null
if (args.since) {
  const parsed = Date.parse(args.since)
  if (Number.isNaN(parsed)) {
    process.stderr.write(`--since 无法解析为 RFC3339 时间：${args.since}\n`)
    process.exit(2)
  }
  since = new Date(parsed)
}

const hopResult = parseProbeHops(lines, requestId, since ? { window: { since } } : {})
const verdict = evaluateProbe(hopResult, { timeoutMs })

process.stdout.write(`${verdict.pass ? 'PASS' : 'FAIL'} [${verdict.code}] ${verdict.message}\n`)
process.stdout.write(`  request_id=${requestId}\n`)
for (const row of verdict.summary) {
  const check = row.present ? (row.inferred ? '≈' : '✓') : '✗'
  const at = row.at ?? '—'
  const stop = row.is_stopped_at ? '  ← 停在这里' : ''
  process.stdout.write(`  ${check} ${row.hop}  ${row.description.padEnd(48, ' ')}  ${at}${stop}\n`)
}
if (verdict.timings?.totalMs !== null && verdict.timings?.totalMs !== undefined) {
  const per = verdict.timings.perHopMs ?? {}
  const perStr = Object.entries(per)
    .filter(([, ms]) => ms !== null && ms !== undefined)
    .map(([hop, ms]) => `${hop}:${ms}ms`)
    .join(' ')
  process.stdout.write(`  逐跳耗时：${perStr}  合计=${verdict.timings.totalMs}ms\n`)
}
if (!verdict.pass && verdict.stoppedAt) {
  process.stdout.write(`  停机跳描述：${HOP_DESCRIPTIONS[verdict.stoppedAt] ?? ''}\n`)
}

process.exit(verdict.pass ? 0 : (verdict.code === PROBE.REJECTED ? 3 : 1))
