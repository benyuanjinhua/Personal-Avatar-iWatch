// ESS-27 真网关验收（qwen-audio-agent v0.9.1 @ 127.0.0.1:3101，Codex 后端）
// 运行: node test/live-test.mjs <recover|restart|cancel|perm>
//
// recover — 真实 spawn_thinking Work；受理后立刻断开 Realtime WS（用户离线），
//           投影先 SSE、被强制中断一次（验证退避重连）、再永久禁用 SSE
//           （验证纯 REST 恢复）；校验终态恰好一次、结果非空、无重复 Work。
// restart — 真实 Work；投影 A 运行数秒后整体销毁（模拟 Bridge 崩溃/Watch 退出），
//           从账本重建投影 B → 终态照常交付；无重复 Work。
// cancel  — 真实长 Work；北向 cancel → DELETE /api/tasks/:id → cancelled 终态。
// perm    — 真网关权限 REST 契约：非法 decision → 400；不存在的 authorization → 404。
//
// 说明：textOnly 伪前端不参与语音所有权仲裁，不会干扰并行的 Bridge/ESS-26 会话；
// 每个场景使用独立 sessionId，只取消属于本场景 session 的任务。

import { writeFileSync, mkdirSync } from 'node:fs'
import { QwenTaskProjection, respondPermission, sleep } from '../task-projection.mjs'
import { ProjectionLedger } from '../projection-ledger.mjs'

const BASE = 'http://127.0.0.1:3101'
const WSBASE = 'ws://127.0.0.1:3101'
const RESULTS = new URL('../results/', import.meta.url).pathname
mkdirSync(RESULTS, { recursive: true })

const scenario = process.argv[2]
const sessionId = `ess27-${scenario}-${Date.now().toString(36)}`
const log = (...a) => console.error(new Date().toISOString(), ...a)

async function rest(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  })
  let json = null
  try { json = await res.json() } catch {}
  return { status: res.status, json }
}

// textOnly 伪前端：仅用于经 Realtime 层合法创建后台 Work（/api/tasks 无创建能力）
function openTextFrontend(sid) {
  const ws = new WebSocket(`${WSBASE}/api/realtime?sessionId=${encodeURIComponent(sid)}`)
  const events = []
  const waiters = []
  ws.addEventListener('message', m => {
    let e
    try { e = JSON.parse(m.data) } catch { return }
    events.push(e)
    if (e.type?.startsWith('task.') || ['transcript.final', 'error'].includes(e.type)) {
      log(`[ws] ${JSON.stringify(e).slice(0, 220)}`)
    }
    for (const w of [...waiters]) {
      if (w.pred(e)) { waiters.splice(waiters.indexOf(w), 1); clearTimeout(w.t); w.res(e) }
    }
  })
  const opened = new Promise((res, rej) => {
    ws.addEventListener('open', res)
    ws.addEventListener('error', () => rej(new Error('ws error')))
  })
  return {
    ws,
    async start() {
      await opened
      ws.send(JSON.stringify({
        type: 'connect', clientType: 'cli', clientLabel: 'ess27-projection-harness',
        clientInstanceId: `ess27-${Date.now()}`, textOnly: true,
        timeZone: 'Asia/Shanghai', locale: 'zh-CN',
      }))
      ws.send(JSON.stringify({ type: 'unmute' }))
    },
    sendText(text) {
      log(`[send] ${text.slice(0, 80)}…`)
      ws.send(JSON.stringify({ type: 'text.message', text, textOnly: true }))
    },
    waitFor(pred, ms, label) {
      return new Promise((res, rej) => {
        const hit = events.find(pred)
        if (hit) return res(hit)
        const t = setTimeout(() => rej(new Error(`timeout waiting ${label}`)), ms)
        waiters.push({ pred, res, t })
      })
    },
    close() { try { ws.close() } catch {} },
  }
}

async function sessionTasks(sid) {
  const { json } = await rest('GET', `/api/tasks?sessionId=${encodeURIComponent(sid)}`)
  return json?.tasks || []
}

// 经 Realtime 层创建一个真实后台 Work，返回 taskId；成功受理后按需断开 WS
async function createWork(prompt, { closeAfterAccept = true, timeoutMs = 240_000 } = {}) {
  const fe = openTextFrontend(sessionId)
  await fe.start()
  await sleep(1500)
  fe.sendText(prompt)
  const taskEvent = await fe.waitFor(
    e => e.type === 'task.running' && e.task?.id,
    timeoutMs,
    'task.running',
  )
  const taskId = taskEvent.task.id
  log(`[work] accepted task=${taskId}`)
  if (closeAfterAccept) {
    fe.close()   // 用户离线：结果交付绝不依赖 Realtime 播报窗口
    log('[work] realtime WS closed — user is now offline')
  }
  return { taskId, fe }
}

function makeProjection(taskId, requestId, events, over = {}) {
  return new QwenTaskProjection({
    gatewayHttp: BASE, taskId, requestId,
    deliver: e => { events.push(e); log(`[deliver] seq=${e.seq} state=${e.state} transport=${e.transport}`) },
    hardTimeoutMs: 300_000,
    log: entry => { if (entry.event !== 'deliver') log(`[proj] ${JSON.stringify(entry).slice(0, 200)}`) },
    ...over,
  })
}

const report = { scenario, sessionId, startedAt: new Date().toISOString() }

async function scenarioRecover() {
  const prompt = '请调用 spawn_thinking 创建一个后台任务，任务内容：只读地统计当前代码仓库里 Swift 源文件（.swift）的数量，并按顶层目录给出分布。明确要求：不要修改、创建或删除任何文件。'
  const before = await sessionTasks(sessionId)
  const { taskId } = await createWork(prompt)
  const requestId = `req-${sessionId}`
  const ledger = new ProjectionLedger({ path: `${RESULTS}/recover.ledger.json` })
  ledger.upsert(requestId, { taskId })

  const events = []
  const proj = makeProjection(taskId, requestId, events)
  const run = proj.start()

  // 中断 1：SSE 被掐断 → 应退避后重连 SSE
  await sleep(3000)
  log('[test] kill SSE #1 (resume allowed)')
  proj.killSse()
  // 一旦确认重连成功，立刻进入中断 2：SSE 永久不可用 → 纯 REST 轮询交付终态
  const resumeDeadline = Date.now() + 10_000
  let resumed = false
  while (Date.now() < resumeDeadline && !proj.settled) {
    if (proj.journal.filter(e => e.event === 'sse.open').length >= 2) { resumed = true; break }
    await sleep(200)
  }
  log(`[test] SSE resumed=${resumed}; kill SSE #2 (disable — force REST-only recovery)`)
  proj.killSse({ disable: true })

  await run
  const terminal = events.filter(e => ['completed', 'failed', 'cancelled'].includes(e.state))
  if (terminal.length && terminal[0].state === 'completed') ledger.markSettled(requestId, 'completed')
  const after = await sessionTasks(sessionId)

  report.checks = {
    acceptedFirst: events[0]?.state === 'background_accepted',
    sseResumedAfterKill: resumed,
    terminalCount: terminal.length,
    terminalState: terminal[0]?.state || null,
    terminalTransport: terminal[0]?.transport || null,
    terminalViaRestOnly: terminal[0]?.transport === 'rest',
    resultSpeech: terminal[0]?.result?.speech || null,
    resultInlineTitle: terminal[0]?.result?.inline?.title || null,
    noDuplicateWork: after.length === before.length + 1,
    sessionTaskCount: after.length,
    ledgerSettled: ledger.get(requestId)?.settled === true,
  }
  report.events = events.map(e => ({ seq: e.seq, state: e.state, transport: e.transport }))
  report.journalTail = proj.journal.slice(-25)
}

async function scenarioRestart() {
  const prompt = '请调用 spawn_thinking 创建一个后台任务，任务内容：只读地列出当前代码仓库根目录下的顶层目录和文件名（一层即可），简单说明每个的用途。明确要求：不要修改、创建或删除任何文件。'
  const before = await sessionTasks(sessionId)
  const { taskId } = await createWork(prompt)
  const requestId = `req-${sessionId}`
  const ledgerPath = `${RESULTS}/restart.ledger.json`
  const ledgerA = new ProjectionLedger({ path: ledgerPath })
  ledgerA.upsert(requestId, { taskId })

  // 投影 A：跑几秒后整体销毁（Bridge 崩溃 / Watch 退出页面）
  const eventsA = []
  const projA = makeProjection(taskId, requestId, eventsA)
  projA.start()
  await sleep(6000)
  projA.stop('simulated-bridge-crash')
  log('[test] projection A destroyed; task keeps running on gateway')
  await sleep(4000)

  // 投影 B：从账本恢复（重开页面），只读续接，绝不重放创建
  const ledgerB = new ProjectionLedger({ path: ledgerPath })
  const pending = ledgerB.unsettled()
  const eventsB = []
  const projB = makeProjection(pending[0].taskId, pending[0].requestId, eventsB)
  await projB.start()
  const terminal = eventsB.filter(e => ['completed', 'failed', 'cancelled'].includes(e.state))
  if (terminal.length) ledgerB.markSettled(requestId, terminal[0].state)
  const after = await sessionTasks(sessionId)

  report.checks = {
    ledgerRecoveredPending: pending.length === 1 && pending[0].taskId === taskId,
    projARanBeforeCrash: eventsA.some(e => e.state === 'background_processing'),
    projATerminal: eventsA.filter(e => ['completed', 'failed', 'cancelled'].includes(e.state)).length,  // 应为 0
    projBTerminalCount: terminal.length,
    projBTerminalState: terminal[0]?.state || null,
    resultSpeech: terminal[0]?.result?.speech || null,
    noDuplicateWork: after.length === before.length + 1,
    sessionTaskCount: after.length,
  }
  report.eventsA = eventsA.map(e => ({ seq: e.seq, state: e.state }))
  report.eventsB = eventsB.map(e => ({ seq: e.seq, state: e.state, transport: e.transport }))
}

async function scenarioCancel() {
  const prompt = '请调用 spawn_thinking 创建一个后台任务，任务内容：逐个文件详细审阅仓库中所有 Swift 源代码，为每个文件写详细总结，越详细越好。只读，不要修改任何文件。'
  const { taskId } = await createWork(prompt)
  const requestId = `req-${sessionId}`
  const events = []
  const proj = makeProjection(taskId, requestId, events)
  const run = proj.start()
  await sleep(6000)                         // 让任务进入 processing
  log('[test] northbound cancel → DELETE /api/tasks/:id')
  const outcome = await proj.cancel()
  await run
  const terminal = events.filter(e => ['completed', 'failed', 'cancelled'].includes(e.state))
  const { json: finalTask } = await rest('GET', `/api/tasks/${taskId}`)
  report.checks = {
    cancelAccepted: outcome.ok === true,
    terminalCount: terminal.length,
    terminalState: terminal[0]?.state || null,
    gatewayFinalStatus: finalTask?.status || null,
    statesSeen: [...new Set(events.map(e => e.state))],
  }
  report.events = events.map(e => ({ seq: e.seq, state: e.state, transport: e.transport }))
}

async function scenarioPerm() {
  const bad = await rest('POST', '/api/permissions/ess27-nonexistent', { decision: 'yes' })
  const missing = await respondPermission({ gatewayHttp: BASE, authorizationId: 'ess27-nonexistent', decision: 'reject' })
  const badLocal = await respondPermission({ gatewayHttp: BASE, authorizationId: 'ess27-nonexistent', decision: 'yes' })
  report.checks = {
    gatewayRejectsBadDecision: bad.status === 400,
    gatewayBadDecisionError: bad.json?.error || null,
    // 上游对未知 authorization id 抛通用错误 → 500 + HTML（只有 ACP 明确报
    // status 404 时才走 404 JSON 路径）。模块必须以稳定错误码兜住而非崩溃/误解析。
    moduleUnknownAuthStable: missing.ok === false
      && ['permission_not_found', 'bad_content_type'].includes(missing.code),
    moduleUnknownAuthCode: missing.code,
    moduleUnknownAuthStatus: missing.status ?? null,
    moduleValidatesDecision: badLocal.ok === false && badLocal.code === 'invalid_decision',
  }
}

const scenarios = { recover: scenarioRecover, restart: scenarioRestart, cancel: scenarioCancel, perm: scenarioPerm }
if (!scenarios[scenario]) {
  console.error('usage: node test/live-test.mjs <recover|restart|cancel|perm>')
  process.exit(1)
}
try {
  await scenarios[scenario]()
  report.finishedAt = new Date().toISOString()
} catch (error) {
  report.error = error.message
  report.stack = error.stack
}
writeFileSync(`${RESULTS}/live.${scenario}.report.json`, JSON.stringify(report, null, 2))
console.log(JSON.stringify(report.checks || { error: report.error }, null, 2))
process.exit(report.error ? 1 : 0)
