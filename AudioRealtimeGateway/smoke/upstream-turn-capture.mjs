#!/usr/bin/env node
// upstream-turn-capture.mjs — ESS-990 取证工具（live-only，不进 npm test）。
//
// 以伪前端身份连上 qwen-audio-agent 的 loopback WS `/api/realtime`（与
// QwenAgentTransport / MacRemoteFrontendBridge supervisor 同一端点、同一 connect
// 握手），用 `text.message` 驱动一个真实回合，并把**全部**上行/下行帧带时间戳
// 落盘，供判定：
//
//   1. `voice.state {state:'idle'}` 到底出现在哪 —— 只在回合真正结束时，还是
//      每段 `audio.done` 之后都出现；
//   2. 「段落 audio.done → 下一段 response.started」的实测分布
//      （标定 `segmentGapMs` / `segmentGapBusyMs` 的依据）。
//
// 口径提醒：本工具按 Bridge 的方言回 `playback.started` / `playback.ended`，
// 而 `QwenAgentTransport` 不回回执——上游的 `voice.state idle` 只由
// `playback.ended` 触发，所以真机 Watch 链路看不到这里抓到的那些 idle。
// 拿本工具的时间分布去标定网关常数时，必须把这条口径差一起写上（R-04.4）。
//
// 关键：**收到 idle 不停**。停在第一个 idle 上恰好会把要证的东西证没了；本工具
// 只在「idle 之后静默 quietMs 无任何新 response.started / audio.delta」时才收口。
//
// 播放回执按 supervisor 的口径回（首个 delta → playback.started，audio.done →
// playback.ended），否则上游不会继续下发 assistant transcript / 后续段落。
//
// 用法：
//   node smoke/upstream-turn-capture.mjs --prompt "杭州今天天气怎么样" \
//     [--runs 1] [--out capture.jsonl] [--quiet-ms 8000] [--timeout-ms 120000] [--takeover]
//
// 前置：qwen-audio-agent 网关在 127.0.0.1:3101 运行且 DashScope 已配置。

import WebSocket from 'ws'
import { appendFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'

const argv = process.argv.slice(2)
const flag = (name, fallback = null) => {
  const at = argv.indexOf(`--${name}`)
  return at >= 0 && argv[at + 1] !== undefined ? argv[at + 1] : fallback
}
const has = name => argv.includes(`--${name}`)

const GATEWAY = process.env.QWEN_GATEWAY_WS || 'ws://127.0.0.1:3101/api/realtime'
const PROMPT = flag('prompt', '杭州今天天气怎么样')
const RUNS = Number(flag('runs', '1'))
const OUT = flag('out', null)
const QUIET_MS = Number(flag('quiet-ms', '8000'))
const TIMEOUT_MS = Number(flag('timeout-ms', '120000'))
const READY_TIMEOUT_MS = Number(flag('ready-timeout-ms', '8000'))
const TAKEOVER = has('takeover')

const write = record => {
  const line = JSON.stringify(record)
  if (OUT) appendFileSync(OUT, line + '\n')
  else console.log(line)
}

function captureOnce(runIndex) {
  return new Promise((resolve, reject) => {
    const sessionId = `ess990-capture-${randomUUID().slice(0, 8)}`
    const ws = new WebSocket(`${GATEWAY}?sessionId=${encodeURIComponent(sessionId)}`)
    const frames = []
    const playbackStarted = new Set()
    let t0 = null                 // text.message 发出的时刻 = 回合时间轴原点
    let ready = false
    let settled = false
    let quietTimer = null

    const at = () => (t0 === null ? 0 : Number((performance.now() - t0).toFixed(3)))
    const record = (direction, payload) => {
      const entry = { run: runIndex, t_ms: at(), dir: direction, ...payload }
      frames.push(entry)
      return entry
    }
    const send = payload => {
      try { ws.send(JSON.stringify(payload)) } catch { return }
      record('up', { type: payload.type, responseId: payload.responseId ?? null })
    }

    const finish = (error, reason) => {
      if (settled) return
      settled = true
      clearTimeout(overallTimer)
      clearTimeout(readyTimer)
      clearTimeout(quietTimer)
      try { ws.close() } catch { /* best effort */ }
      if (error) return reject(error)
      resolve({ run: runIndex, sessionId, prompt: PROMPT, reason, frames })
    }

    // 「idle 之后还会不会有下文」只能靠等出来。任何新的段落活动都重置它。
    const armQuiet = () => {
      clearTimeout(quietTimer)
      quietTimer = setTimeout(() => finish(null, 'quiet_after_idle'), QUIET_MS)
      quietTimer.unref?.()
    }
    const bumpQuiet = () => { if (quietTimer) armQuiet() }

    const overallTimer = setTimeout(() => finish(null, 'overall_timeout'), TIMEOUT_MS)
    const readyTimer = setTimeout(() => {
      if (!ready) finish(Object.assign(new Error('voice not ready'), { code: 'NOT_READY' }))
    }, READY_TIMEOUT_MS)

    ws.on('open', () => {
      ws.send(JSON.stringify({
        type: 'connect',
        clientType: 'cli',
        clientLabel: 'ess990-capture',
        clientInstanceId: `ess990_${randomUUID()}`,
        voiceEnabled: true,
        takeover: TAKEOVER,
        timeZone: 'Asia/Shanghai',
        locale: 'zh-CN',
      }))
    })
    ws.on('error', error => finish(error))
    ws.on('close', () => finish(null, 'upstream_closed'))
    ws.on('message', raw => {
      let event
      try { event = JSON.parse(raw.toString()) } catch { return }

      if (!ready && (event.type === 'voice.ready'
        || (event.type === 'voice.ownership' && event.state === 'active'))) {
        ready = true
        clearTimeout(readyTimer)
        t0 = performance.now()
        record('down', { type: event.type, state: event.state ?? null })
        send({ type: 'text.message', text: PROMPT })
        return
      }

      // announcement 是与本回合无关的后台播报，记录但不参与判定（ESS-36）。
      const isAnnouncement = event.origin === 'announcement'

      if (event.type === 'audio.delta') {
        const bytes = event.audio ? Buffer.from(event.audio, 'base64').length : 0
        record('down', {
          type: 'audio.delta', responseId: event.responseId ?? null,
          origin: event.origin ?? null, sequence: event.sequence ?? null,
          bytes, announcement: isAnnouncement || undefined,
        })
        if (!isAnnouncement && event.responseId && !playbackStarted.has(event.responseId)) {
          playbackStarted.add(event.responseId)
          send({ type: 'playback.started', responseId: event.responseId })
        }
        bumpQuiet()
        return
      }

      // 其余帧全量落盘（audio 字段已在上面单独处理，这里不会有大 payload）。
      record('down', {
        type: event.type,
        responseId: event.responseId ?? null,
        origin: event.origin ?? null,
        state: event.state ?? null,
        role: event.role ?? null,
        turnId: event.turnId ?? null,
        taskId: event.taskId ?? null,
        task: event.task ?? null,
        content: typeof event.content === 'string' ? event.content.slice(0, 200) : undefined,
        code: event.code ?? undefined,
        message: event.message ?? undefined,
        announcement: isAnnouncement || undefined,
      })

      if (isAnnouncement) return

      if (event.type === 'response.started') { bumpQuiet(); return }
      if (event.type === 'audio.done') {
        if (event.responseId) send({ type: 'playback.ended', responseId: event.responseId })
        bumpQuiet()
        return
      }
      if (event.type === 'voice.state' && event.state === 'idle') { armQuiet(); return }
      if (event.type === 'error' || event.type === 'session.error' || event.type === 'voice.error') {
        finish(null, `upstream_error:${event.code ?? event.message ?? 'unknown'}`)
      }
    })
  })
}

// 一次采样的派生量：段落边界、终态位置、以及要标定的两个间隔。
function summarize(capture) {
  const f = capture.frames.filter(x => x.dir === 'down' && !x.announcement)
  const starts = f.filter(x => x.type === 'response.started')
  const dones = f.filter(x => x.type === 'audio.done')
  const idles = f.filter(x => x.type === 'voice.state' && x.state === 'idle')
  const tasks = f.filter(x => typeof x.type === 'string' && x.type.startsWith('task.'))
  const lastDone = dones.at(-1) ?? null
  const lastIdle = idles.at(-1) ?? null
  const gaps = []
  for (const done of dones) {
    const next = starts.find(s => s.t_ms > done.t_ms)
    if (next) gaps.push(Number((next.t_ms - done.t_ms).toFixed(1)))
  }
  return {
    run: capture.run, session_id: capture.sessionId, prompt: capture.prompt,
    reason: capture.reason,
    segments: dones.length,
    response_started: starts.map(x => ({ t_ms: x.t_ms, origin: x.origin, responseId: x.responseId, taskId: x.taskId })),
    audio_done: dones.map(x => ({ t_ms: x.t_ms, responseId: x.responseId })),
    voice_state_idle: idles.map(x => x.t_ms),
    task_events: tasks.map(x => ({ t_ms: x.t_ms, type: x.type, id: x.task?.id ?? x.taskId ?? null, status: x.task?.status ?? null })),
    // 本单要标定的两个量
    segment_done_to_next_start_ms: gaps,
    last_done_to_last_idle_ms: lastDone && lastIdle
      ? Number((lastIdle.t_ms - lastDone.t_ms).toFixed(1)) : null,
    // 「idle 是否只在回合末尾出现」的直接判据：idle 之后是否还有段落开始
    idle_followed_by_new_segment: idles.some(i => starts.some(s => s.t_ms > i.t_ms)),
    first_idle_before_last_done: Boolean(idles[0] && lastDone && idles[0].t_ms < lastDone.t_ms),
  }
}

const summaries = []
for (let run = 1; run <= RUNS; run += 1) {
  process.stderr.write(`[ess990] run ${run}/${RUNS} …\n`)
  let capture
  try {
    capture = await captureOnce(run)
  } catch (error) {
    process.stderr.write(`[ess990] run ${run} failed: ${error.code ?? ''} ${error.message}\n`)
    summaries.push({ run, error: error.code ?? error.message })
    continue
  }
  for (const frame of capture.frames) write(frame)
  const summary = summarize(capture)
  summaries.push(summary)
  process.stderr.write(`[ess990] run ${run}: ${JSON.stringify(summary)}\n`)
}
console.error(JSON.stringify({ summaries }, null, 2))
