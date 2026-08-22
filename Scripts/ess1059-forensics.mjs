#!/usr/bin/env node
// ESS-1059 取证复核 CLI —— 只读地重跑「qwen-audio-agent → Codex CLI 工具调用
// 链路」的每一条结论，输出带口径的原始计数，供复审逐条核对。
//
//   node Scripts/ess1059-forensics.mjs [--from <ISO>] [--to <ISO>] [--reveal-text]
//
// 只用 readFileSync 读文件，不写、不改、不连网、不启服务；对任何一份数据源缺失
// 都降级成 `E?: UNAVAILABLE` 而不是崩溃，所以在没有真机日志的机器上也能跑完。
//
// 为什么要有这个脚本：ESS-1061 架构复审判定「结论可信但没有命令+输出可复跑」。
// 评论里的摘录是人挑的，挑选本身就是未经复核的一步；这里把每条结论还原成
// 「数据源 + 过滤口径 + 计数」，复审只需要看口径对不对，不需要相信我抄得对。
//
// 脱敏口径：默认不打印任何用户语音文本（ASR / 播报文案 / 记忆内容），只打印
// 结构化标识和计数。`--reveal-text` 才会打印 final_asr —— 仅供本机运维排查，
// 输出不要贴进 issue。凭据类字段（API key、token、authorizationId）在任何模式
// 下都不读取、不打印。
//
// 退出码 0 = 所有可用数据源的结论与 ESS-1059 报告一致；非 0 = 至少一条对不上
// （逐条打印 MISMATCH），或没有任何数据源可读。

import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()

// 真机批次窗口（UTC）。默认值 = ESS-1059 报告采信的那一批 5 个会话；改窗口只
// 影响 E1/E2/E5，E3/E4/E6 是全量统计，与窗口无关。
const DEFAULT_FROM = '2026-08-22T15:42:00Z'
const DEFAULT_TO = '2026-08-22T15:44:30Z'

const SOURCES = {
  // 本仓库部署实例的结构化日志（一行一个 JSON，evt 字段）
  gatewayLog: join(HOME, 'Services/Personal-Avatar-iWatch/AudioRealtimeGateway/logs/gateway.log'),
  // 上游 qwen-audio-agent 的日志：每条事件写两遍（文本前缀行 + 纯 JSON 行），
  // 这里只解析纯 JSON 行，所以计数不会翻倍。
  upstreamLog: join(HOME, '.config/qwaudio/logs/gateway.log'),
  tasks: join(HOME, '.config/qwaudio/tasks.json'),
  acpSessions: join(HOME, '.config/qwaudio/state/acp-sessions.json'),
}

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = args.indexOf(name)
  return i === -1 || i + 1 >= args.length ? fallback : args[i + 1]
}
const FROM = flag('--from', DEFAULT_FROM)
const TO = flag('--to', DEFAULT_TO)
const REVEAL = args.includes('--reveal-text')

let failures = 0
let sourcesRead = 0
const fail = message => { failures += 1; console.log(`      MISMATCH: ${message}`) }
const redact = text => REVEAL ? text : `<redacted ${Buffer.byteLength(text, 'utf8')}B>`

const readLines = path => {
  if (!existsSync(path)) return null
  sourcesRead += 1
  return readFileSync(path, 'utf8').split('\n')
}

// 两份日志都是「一行一个 JSON」，但上游日志混了文本前缀行，非 JSON 行直接跳过。
const jsonLines = (lines, tsKey) => {
  const out = []
  for (const line of lines) {
    if (!line.startsWith('{')) continue
    try {
      const parsed = JSON.parse(line)
      if (parsed[tsKey] != null) out.push(parsed)
    } catch { /* 截断的尾行：跳过而不是中止整份取证 */ }
  }
  return out
}

const inWindow = ts => ts >= FROM && ts <= TO
const section = (id, title) => console.log(`\n${id}: ${title}`)
const unavailable = (id, path) => {
  console.log(`\n${id}: UNAVAILABLE — 数据源不存在：${path}`)
}

console.log('# ESS-1059 取证复核')
console.log(`窗口（UTC）: ${FROM} .. ${TO}`)
console.log(`文本脱敏: ${REVEAL ? 'OFF（--reveal-text）' : 'ON（默认）'}`)

// ---------------------------------------------------------------------------
// E1 本仓库网关：真机批次的会话账本
//
// 口径：窗口内出现过 `ws_upgrade` 的 session_id 即一个会话；每个会话记录它的
// 工具调用、回合终态、播报丢弃量和 `done_emitted`。这一段同时喂 F3 / F4 / F7。
// ---------------------------------------------------------------------------
{
  const lines = readLines(SOURCES.gatewayLog)
  if (!lines) unavailable('E1', SOURCES.gatewayLog)
  else {
    section('E1', `AudioRealtimeGateway 会话账本（${SOURCES.gatewayLog}）`)
    const events = jsonLines(lines, 'ts').filter(e => inWindow(e.ts))
    const sessions = new Map()
    const of = id => {
      if (!sessions.has(id)) {
        sessions.set(id, {
          id, first: null, last: null, toolCall: false, taskIds: new Set(),
          terminal: null, doneEmitted: null, endReason: null,
          announcementFrames: 0, announcementBytes: 0,
          playbackStarted: null, playbackEnded: null, commitTimeout: false,
        })
      }
      return sessions.get(id)
    }
    for (const e of events) {
      if (!e.session_id) continue
      const s = of(e.session_id)
      s.first ??= e.ts
      s.last = e.ts
      switch (e.evt) {
        case 'upstream_tool_call_pending': s.toolCall = true; break
        case 'upstream_task_state': s.taskIds.add(e.task_id); break
        case 'upstream_turn_terminal':
          s.terminal = { ts: e.ts, reason: e.reason, outstanding: e.outstanding_tasks }
          break
        case 'upstream_announcement_audio_done_dropped':
          s.announcementFrames += e.dropped_frames ?? 0
          s.announcementBytes += e.dropped_bytes ?? 0
          break
        case 'playback_started': s.playbackStarted = e.ts; break
        case 'playback_ended': s.playbackEnded = e.ts; break
        case 'commit_deadline_timeout': s.commitTimeout = true; break
        case 'session_ended':
          s.doneEmitted = e.done_emitted
          s.endReason = e.reason
          break
        default: break
      }
    }
    console.log(`   窗口内会话数: ${sessions.size}`)
    for (const s of sessions.values()) {
      const short = s.id.slice(0, 8)
      console.log(`   - ${short} ${s.first} .. ${s.last}`)
      console.log(`       tool_call=${s.toolCall} tasks=[${[...s.taskIds].join(',') || '-'}]`)
      console.log(`       terminal=${s.terminal ? `${s.terminal.reason}@${s.terminal.ts} outstanding_tasks=${s.terminal.outstanding}` : 'NONE'}`)
      console.log(`       done_emitted=${s.doneEmitted} end_reason=${s.endReason} commit_timeout=${s.commitTimeout}`)
      console.log(`       announcement_dropped=${s.announcementFrames}帧/${s.announcementBytes}字节`)
      console.log(`       playback=${s.playbackStarted ?? '-'} .. ${s.playbackEnded ?? '-'}`)
    }

    // F3：回合在还有未终结任务时收口。
    section('E1.F3', 'tool_result_done 是否在 outstanding_tasks>0 时收口')
    const early = [...sessions.values()].filter(
      s => s.terminal?.reason === 'tool_result_done' && s.terminal.outstanding > 0)
    if (early.length === 0) console.log('   未复现（窗口内没有这种回合）')
    for (const s of early) {
      console.log(`   ${s.id.slice(0, 8)} 于 ${s.terminal.ts} 收口，outstanding_tasks=${s.terminal.outstanding}`)
    }

    // F7：直答回合（无工具调用）是否拿不到 done。
    section('E1.F7', '无工具调用的回合是否发出过 agent.audio.done')
    for (const s of [...sessions.values()].filter(x => !x.toolCall && !x.commitTimeout)) {
      console.log(`   ${s.id.slice(0, 8)} done_emitted=${s.doneEmitted} end_reason=${s.endReason}`)
      if (s.doneEmitted === true) fail(`${s.id.slice(0, 8)} 实际发出了 done，与 F7 结论不符`)
    }
  }
}

// ---------------------------------------------------------------------------
// E2 上游 qwen-audio-agent：任务生命周期 + 进程重启点
//
// 口径：只解析纯 JSON 行（`time` 字段）。`task.*` 给 F3 的时间差；pid 变化给
// F1 的「重启触发 resume」这一步。
// ---------------------------------------------------------------------------
let upstreamEvents = null
{
  const lines = readLines(SOURCES.upstreamLog)
  if (!lines) unavailable('E2', SOURCES.upstreamLog)
  else {
    section('E2', `上游任务生命周期与重启点（${SOURCES.upstreamLog}）`)
    upstreamEvents = jsonLines(lines, 'time')
    for (const e of upstreamEvents.filter(x => inWindow(x.time) && String(x.event).startsWith('task.'))) {
      console.log(`   ${e.time} ${e.event} task=${e.taskId} status=${e.status} hasError=${e.hasError} elapsedMs=${e.elapsedMs}`)
    }
    section('E2.restart', '进程重启点（pid 变化，当天 10:00Z 起）')
    let lastPid = null
    for (const e of upstreamEvents) {
      if (!(e.time >= '2026-08-22T10:00:00Z')) continue
      if (e.pid === lastPid) continue
      lastPid = e.pid
      console.log(`   ${e.time} pid=${e.pid} (${e.event})`)
    }
  }
}

// ---------------------------------------------------------------------------
// E3 tasks.json：委派任务的真实成败
//
// 口径（这是「连续 14 次零成功」的定义，复审请先看这里）：
//   • 样本 = tasks.json 中 status='completed' 的任务，按 createdAt 升序；
//   • 判失败 = result 能解析成 JSON 且 .type === 'error'，或 result 以
//     '{"type":"error"' 开头（后者兜住被截断的 result）;
//   • 「连续零成功」= 从最后一个非失败任务之后到最新一条为止的长度。
// 注意 status 本身不参与判失败 —— F2 说的正是 status 撒谎。
// ---------------------------------------------------------------------------
{
  if (!existsSync(SOURCES.tasks)) unavailable('E3', SOURCES.tasks)
  else {
    sourcesRead += 1
    section('E3', `委派任务成败（${SOURCES.tasks}）`)
    const raw = JSON.parse(readFileSync(SOURCES.tasks, 'utf8'))
    const all = (Array.isArray(raw.tasks) ? raw.tasks : Object.values(raw.tasks ?? {}))
      .filter(t => t.status === 'completed')
      .sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0))
    const isError = t => {
      const r = t.result
      if (typeof r !== 'string') return false
      if (r.startsWith('{"type":"error"')) return true
      try { return JSON.parse(r)?.type === 'error' } catch { return false }
    }
    let streak = 0
    let lastSuccess = null
    for (const t of all) {
      if (isError(t)) streak += 1
      else { streak = 0; lastSuccess = t }
    }
    console.log(`   status=completed 的任务总数: ${all.length}`)
    console.log(`   末尾连续「completed 但 result 是 error」条数: ${streak}`)
    console.log(`   最后一次真正成功: ${lastSuccess ? `${new Date(lastSuccess.createdAt).toISOString()} ${lastSuccess.id}` : '无'}`)
    const errs = all.filter(isError)
    const distinct = new Set(errs.map(t => t.result))
    console.log(`   失败任务数: ${errs.length}，不同错误正文数: ${distinct.size}`)
    if (distinct.size === 1) {
      const only = [...distinct][0]
      const id = only.match(/'(msg_[0-9a-f-]+)'/)?.[1] ?? '(未匹配到 msg_ id)'
      console.log(`   唯一错误指向的条目 id: ${id}`)
    }

    // F2：失败被标成成功。
    section('E3.F2', 'result 是 error 的任务，其 status / hasError / speech 长什么样')
    const sample = errs.at(-1)
    if (!sample) console.log('   无样本')
    else {
      const speech = sample.resultMetadata?.presentation?.speech
      console.log(`   ${sample.id} status=${sample.status} error=${JSON.stringify(sample.error)}`)
      console.log(`   presentation.speech 是否就是那段错误 JSON: ${speech === sample.result}`)
      console.log(`   voice_session_id=${sample.sessionId}`)
      if (sample.status !== 'completed') fail(`${sample.id} 的 status 不是 completed，F2 结论需要重判`)
      if (sample.error !== null) fail(`${sample.id} 的 error 字段非 null，F2 结论需要重判`)
    }
  }
}

// ---------------------------------------------------------------------------
// E4 acp-sessions.json + Codex rollout：F1 的根因链
//
// 口径：rollout 路径不写死 —— 从 acp-sessions.json 读到 sessionId 后按文件名
// 去 ~/.codex/sessions 下匹配，匹配不到就如实报 UNAVAILABLE。
// ---------------------------------------------------------------------------
{
  if (!existsSync(SOURCES.acpSessions)) unavailable('E4', SOURCES.acpSessions)
  else {
    sourcesRead += 1
    section('E4', `Codex ACP 会话复用（${SOURCES.acpSessions}）`)
    const state = JSON.parse(readFileSync(SOURCES.acpSessions, 'utf8'))
    const codex = state.coordinators?.['codex:user_personal:backend']
    if (!codex) console.log('   未找到 codex:user_personal:backend')
    else {
      console.log(`   sessionId=${codex.sessionId}`)
      console.log(`   cwd=${codex.cwd}`)
      console.log(`   updatedAt=${new Date(codex.updatedAt).toISOString()}`)

      const found = findRollout(codex.sessionId)
      if (!found) console.log(`   rollout: UNAVAILABLE（~/.codex/sessions 下没有 ${codex.sessionId} 的记录）`)
      else {
        sourcesRead += 1
        section('E4.rollout', `被复用的会话记录（${found}）`)
        const stat = statSync(found)
        const lines = readFileSync(found, 'utf8').split('\n').filter(Boolean)
        console.log(`   大小=${stat.size} 字节  行数=${lines.length}`)
        const compactions = []
        const badReasoning = []
        const errors400 = []
        lines.forEach((line, i) => {
          let o
          try { o = JSON.parse(line) } catch { return }
          const n = i + 1
          const p = o.payload ?? {}
          if (o.type === 'compacted' || p.type === 'context_compacted') compactions.push({ n, ts: o.timestamp })
          // 关键判据：reasoning 条目的 id 必须以 rs_ 开头，否则 Responses API 拒收。
          if (o.type === 'response_item' && p.type === 'reasoning' && p.id && !String(p.id).startsWith('rs_')) {
            badReasoning.push({ n, ts: o.timestamp, id: p.id })
          }
          if (p.type === 'task_complete' && typeof p.error?.message === 'string'
            && p.error.message.includes('invalid_id_prefix')) {
            errors400.push({ n, ts: o.timestamp, id: p.error.message.match(/'(msg_[0-9a-f-]+)'/)?.[1] ?? null })
          }
        })
        console.log(`   compaction 次数: ${compactions.length}`)
        for (const c of compactions.slice(-3)) console.log(`     行 ${c.n} ${c.ts}`)
        console.log(`   id 不以 rs_ 开头的 reasoning 条目: ${badReasoning.length}`)
        for (const b of badReasoning.slice(-3)) console.log(`     行 ${b.n} ${b.ts} id=${b.id}`)
        console.log(`   invalid_id_prefix 400 的 task_complete: ${errors400.length}`)
        const blamed = new Set(errors400.map(e => e.id))
        console.log(`   400 点名的条目 id: ${[...blamed].join(', ') || '(无)'}`)
        if (errors400.length > 0) {
          console.log(`   首次 400: ${errors400[0].ts}   最近一次: ${errors400.at(-1).ts}`)
          // 结论成立的充要条件：被点名的那条 id 确实躺在这份被复用的历史里。
          const present = badReasoning.some(b => blamed.has(b.id))
          console.log(`   被点名的条目是否就在这份复用历史中: ${present}`)
          if (!present) fail('400 点名的 id 不在本会话历史内，F1 的因果链需要重查')
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// E5 F4：后台任务结果的投递通道
//
// 口径：上游 `response.started origin=announcement` 的 `taskIds` 就是这次播报
// 要交付的任务；把它和本仓库网关同一时刻的 `upstream_announcement_audio_
// done_dropped` 对上，就能证明「唯一的回送通道被整段丢弃」。
// ---------------------------------------------------------------------------
{
  const lines = readLines(SOURCES.gatewayLog)
  if (!upstreamEvents || !lines) unavailable('E5', `${SOURCES.upstreamLog} + ${SOURCES.gatewayLog}`)
  else {
    section('E5', '后台任务结果只走 announcement，且被本网关丢弃')
    const dropped = jsonLines(lines, 'ts')
      .filter(e => e.evt === 'upstream_announcement_audio_done_dropped' && inWindow(e.ts))
    const byResponse = new Map(dropped.map(e => [e.upstream_response_id, e]))
    for (const e of upstreamEvents) {
      if (!inWindow(e.time) || e.event !== 'response.started' || e.origin !== 'announcement') continue
      const drop = byResponse.get(e.responseId)
      console.log(`   ${e.time} ${e.responseId} taskIds=[${(e.taskIds ?? []).join(',') || '-'}]`)
      console.log(`       本网关丢弃: ${drop ? `${drop.dropped_frames}帧/${drop.dropped_bytes}字节` : '未找到对应丢弃记录'}`)
    }
  }
}

// ---------------------------------------------------------------------------
// E6 F5/F6：哪些回合能反查出用户原话
//
// 口径：只有走了 spawn_thinking 的回合，其请求信封才会落进 Codex rollout，
// 因此才有 final_asr 可查。不走委派的回合在服务端任何一层都没有 ASR 落盘 ——
// 这正是 F5 只能停在「待验证」的原因，此处把它变成可复核的事实而不是说法。
// ---------------------------------------------------------------------------
{
  if (!existsSync(SOURCES.acpSessions)) unavailable('E6', SOURCES.acpSessions)
  else {
    section('E6', '窗口内可反查到 final_asr 的回合')
    const state = JSON.parse(readFileSync(SOURCES.acpSessions, 'utf8'))
    const codex = state.coordinators?.['codex:user_personal:backend']
    const found = codex && findRollout(codex.sessionId)
    if (!found) console.log('   rollout 不可用，跳过')
    else {
      let hits = 0
      for (const line of readFileSync(found, 'utf8').split('\n')) {
        if (!line.startsWith('{')) continue
        let o
        try { o = JSON.parse(line) } catch { continue }
        if (!inWindow(o.timestamp ?? '')) continue
        const message = o.payload?.type === 'user_message' ? o.payload.message : null
        if (typeof message !== 'string') continue
        const asr = message.match(/"final_asr":\s*"((?:[^"\\]|\\.)*)"/)?.[1]
        const workId = message.match(/"request_id":\s*"(work_[0-9a-f-]+)"/)?.[1]
        const voiceSession = message.match(/"voice_session_id":\s*"([^"]+)"/)?.[1]
        if (!asr) continue
        hits += 1
        console.log(`   ${o.timestamp} work=${workId} voice_session=${voiceSession}`)
        console.log(`       final_asr=${redact(asr)}`)
      }
      console.log(`   可反查回合数: ${hits}（其余回合服务端无 ASR 落盘）`)
    }
  }
}

function findRollout(sessionId) {
  // rollout 文件名形如 rollout-<ISO>-<sessionId>.jsonl，按年月日分目录存放。
  const root = join(HOME, '.codex/sessions')
  if (!existsSync(root)) return null
  const stack = [root]
  while (stack.length > 0) {
    const dir = stack.pop()
    let entries
    try { entries = readdirSyncSafe(dir) } catch { continue }
    for (const entry of entries) {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) stack.push(full)
      else if (entry.isFile() && entry.name.includes(sessionId)) return full
    }
  }
  return null
}

function readdirSyncSafe(dir) {
  // 单独包一层：~/.codex/sessions 下可能有权限受限的子目录，跳过而不是中止。
  return readdirSync(dir, { withFileTypes: true })
}

console.log(`\n数据源读到: ${sourcesRead} 份`)
if (sourcesRead === 0) {
  console.log('结论: 无法取证 —— 本机没有任何一份数据源。')
  process.exit(2)
}
console.log(failures === 0
  ? '结论: 与 ESS-1059 报告一致（上列口径下无 MISMATCH）。'
  : `结论: ${failures} 条与报告不一致，见上面的 MISMATCH。`)
process.exit(failures === 0 ? 0 : 1)
