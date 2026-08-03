#!/usr/bin/env node
// ESS-228 Phase 1 (E2)：把 bridge.log 里的 `session_interruption` 事件按
// `watch_ts + state` 去重，还原真实系统级中断次数，并按 `instance=` 拆分
// 每个 observer 的观察计数，验证「4 个实例各持一份 observer」的假说。
//
//   node Scripts/interruption-dedup.mjs --log <bridge.log> [--window <ISO8601>~<ISO8601>]
//
// 输出（stdout）：
//   raw_lines           所有 [player] session_interruption 原始行数
//   deduped_events      按 (watch_ts, state) 去重后的独立系统事件数
//   dedup_ratio         raw / deduped —— 恒为 observer 数即符合放大假说
//   per_state           began / ended 各多少
//   per_instance        按 instance= 分组的原始计数（新字段落地后才有）
//   with_reason         按 reason= 分组的计数（.appWasSuspended 是否命中）
//
// 不联网、不写文件。仅只读 stdin/参数指定的 log 文件。

import fs from 'node:fs'

const args = new Map()
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i]
  if (arg.startsWith('--')) args.set(arg.slice(2), process.argv[++i])
}
if (!args.get('log')) {
  process.stderr.write('usage: interruption-dedup.mjs --log <bridge.log> [--window ISO~ISO]\n')
  process.exit(2)
}

const [winStart, winEnd] = (args.get('window') || '').split('~')

const lines = fs.readFileSync(args.get('log'), 'utf8').split('\n')

const raw = []
for (const line of lines) {
  const trimmed = line.trim()
  if (!trimmed) continue
  let json
  try { json = JSON.parse(trimmed) } catch { continue }
  if (json.evt !== 'watch_client_log') continue
  if (json.module !== 'player' || json.event !== 'session_interruption') continue
  const watchTs = json.watch_ts
  if (winStart && watchTs < winStart) continue
  if (winEnd && watchTs > winEnd) continue
  raw.push(json)
}

const kv = (detail, key) => {
  const m = detail?.match(new RegExp(`(?:^|\\s)${key}=([^\\s]+)`))
  return m ? m[1] : null
}

const dedupSet = new Set()
const perState = { began: 0, ended: 0, other: 0 }
const perInstance = {}
const perReason = {}
for (const r of raw) {
  const state = kv(r.detail, 'state') || 'other'
  const instance = kv(r.detail, 'instance') || 'legacy_no_tag'
  const reason = kv(r.detail, 'reason') || 'legacy_no_field'
  dedupSet.add(`${r.watch_ts}|${state}`)
  perState[state] = (perState[state] || 0) + 1
  perInstance[instance] = (perInstance[instance] || 0) + 1
  perReason[reason] = (perReason[reason] || 0) + 1
}

const raw_lines = raw.length
const deduped_events = dedupSet.size
const dedup_ratio = deduped_events === 0 ? null : Number((raw_lines / deduped_events).toFixed(2))

process.stdout.write(JSON.stringify({
  window: { start: winStart || null, end: winEnd || null },
  raw_lines,
  deduped_events,
  dedup_ratio,
  per_state: perState,
  per_instance: perInstance,
  per_reason: perReason
}, null, 2) + '\n')
