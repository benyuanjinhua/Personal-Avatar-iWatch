// ESS-1159 —— 超过 12 秒 / 超过 30 秒的委派回合，上游 socket 必须全程存活。
//
// 2026-09-05 最新真机复测（白梦林）两条委派用例全部无最终语音：
//   • 天气：session `watch-direct-B4C6D281-…-1`，task
//     `work_9e37b3be-6764-4840-90a6-8e1813075509`。客户端 **12.157s** 断开，
//     网关随即对上游 `mute` + `terminate`，Codex 在 22.272s 才完成，答案丢失；
//   • 知识库：session `watch-direct-518197E7-…-1`，task
//     `work_11ecbeaf-18ee-4be7-8a8e-6a8e8353a5c1`。客户端约 **12.4s** 断开，
//     服务端记 `task.stream.frame_dropped reason=socket_closed`，Codex 在
//     18.985s 才完成。
//
// 12 这个数字在整条链路上只有一个来源：`config.json` 的
// `agent_segment_gap_busy_ms = 12000`——委派回合里阶段播报段落收口之后的
// 「忙碌段落间隔」。ESS-1145 之前的既有用例都把这个窗口调到几十毫秒来跑得快，
// 于是**没有任何一条回归真的跨过 12 秒**，更没有跨过 30 秒的
// `toolCallWindowMs` / `taskAnswerWindowMs`。本文件刻意用**生产配置的真实窗口
// 与真实时钟**跑两条长回合，代价是约 45 秒挂钟时间——这正是本单验收第 4 条
// 「增加超过 12 秒、超过 30 秒的天气/知识库委派回归」要买的东西。
//
// 断言的直接事实是真机症状的反面：
//   1. 上游 socket 全程 OPEN，交付终态之前网关一帧 `mute` / `interrupt` 都没发；
//   2. 交付终态之前一帧 `agent.audio.done` 都不许出现（提前收口 = 客户端提前走）；
//   3. 最终文本与最终 `agent.audio.done` 各恰好一次，且 done 是最后一帧。

import assert from 'node:assert/strict'
import { after, test } from 'node:test'
import { WebSocket, WebSocketServer } from 'ws'

import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

const servers = []
after(async () => {
  await Promise.all(servers.splice(0).map(server => new Promise(resolve => {
    for (const client of server.clients) client.terminate()
    server.close(resolve)
  })))
})

const send = (ws, event) => ws.send(JSON.stringify(event))
const audioDelta = (ws, sequence, text) => send(ws, {
  type: 'audio.delta', sequence, audio: Buffer.from(text).toString('base64'), sampleRate: 24_000,
})
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function waitFor(predicate, timeoutMs = 5_000) {
  const started = Date.now()
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (predicate()) return resolve()
      if (Date.now() - started > timeoutMs) return reject(new Error('waitFor timeout'))
      setTimeout(poll, 10)
    }
    poll()
  })
}

/// 假上游。除了照常应答，还把网关**发过来**的每一帧记下来——真机症状里那条
/// `{type:'mute'}` 就是从这里发出去的，钉住它比钉任何日志都直接。
async function upstream(onCommit) {
  const inbound = []
  const sockets = []
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on('connection', ws => {
    sockets.push(ws)
    ws.on('message', raw => {
      const message = JSON.parse(raw.toString())
      inbound.push(message)
      if (message.type === 'connect') return send(ws, { type: 'voice.ready' })
      if (message.type === 'audio.commit') return onCommit(ws)
    })
  })
  await new Promise(resolve => server.once('listening', resolve))
  return {
    url: `ws://127.0.0.1:${server.address().port}/api/realtime`,
    inbound,
    /// 上游这一侧看到的 socket 状态。`mute` + `terminate` 之后它不再是 OPEN。
    isOpen: () => sockets.length > 0 && sockets.every(ws => ws.readyState === WebSocket.OPEN),
  }
}

/// **生产配置**的窗口，一个字都不调小——本文件的全部意义就在这里。
function harness(url, sessionId) {
  const events = []
  const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url,
    responseTimeoutMs: 0,
    doneSettleMs: 20,
    segmentGapMs: 2_500,
    segmentGapBusyMs: 12_000,
    toolCallWindowMs: 30_000,
    taskAnswerWindowMs: 30_000,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: `r-${sessionId}`, sessionId, deviceId: 'd1159', generation: 1,
    responseId: `r-${sessionId}:gen1`,
    onEvent: event => events.push(event),
  })
  return { events, logs, turn }
}

/// 委派回合的骨架，与 ESS-1145 的夹具同源：段1 判定要调工具 → 任务受理 →
/// 段2 阶段播报「我去查一下」收口。段2 收口的那一刻起，12 秒的忙碌段落间隔
/// 开始计时——真机上客户端正是在这段时间的尾巴上走掉的。
function delegationPrologue(ws, taskId, sessionId) {
  send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
  audioDelta(ws, 0, '我正在查询')
  send(ws, { type: 'response.done', responseId: 'up-1', origin: 'model', hasFunctionCall: true })
  send(ws, { type: 'audio.done', responseId: 'up-1' })
  send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
  send(ws, { type: 'task.accepted', task: { id: taskId, status: 'queued' } })
  send(ws, {
    type: 'task.stream', protocolVersion: 1,
    taskId, requestId: taskId, sessionId, generation: 1,
    category: 'progress', seq: 0, message: 'running', status: 'running',
  })
  send(ws, { type: 'task.running', task: { id: taskId, status: 'running' } })
  setTimeout(() => {
    send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
    audioDelta(ws, 1, '我去查一下')
    send(ws, { type: 'response.done', responseId: 'up-2', origin: 'agent', hasFunctionCall: false })
    send(ws, { type: 'audio.done', responseId: 'up-2' })
  }, 10)
}

/// 交付：生命周期终态 → 答案文本 → 答案语音 → 唯一一帧交付终态。
function deliverAnswer(ws, taskId, sessionId, answer) {
  send(ws, { type: 'task.completed', task: { id: taskId, status: 'completed' } })
  send(ws, {
    type: 'task.stream', protocolVersion: 1,
    taskId, requestId: taskId, sessionId, generation: 1,
    category: 'text', seq: 0, delta: answer,
  })
  send(ws, { type: 'task.stream.first_audio', taskId, sequence: 0, latency_ms: 12 })
  send(ws, { type: 'response.started', responseId: 'up-3', origin: 'agent' })
  audioDelta(ws, 2, 'answer-audio')
  send(ws, { type: 'response.done', responseId: 'up-3', origin: 'agent', hasFunctionCall: false })
  send(ws, { type: 'audio.done', responseId: 'up-3' })
  send(ws, { type: 'task.stream.segment', taskId, sequence: 0, text: answer })
  send(ws, {
    type: 'task.stream', protocolVersion: 1,
    taskId, requestId: taskId, sessionId, generation: 1,
    category: 'terminal', seq: 0, status: 'completed', finalAudioSequence: 0,
  })
  send(ws, { type: 'task.stream.done', taskId, final_sequence: 0 })
}

/// 两条长回合共用的断言：socket 活着、没提前收口、最终文本与终态各一次。
async function assertHeldThenDelivered({ events, logs, source, answer, holdMs, taskId }) {
  // 先等这条上游 socket 真的建起来，否则「还活着」在 0ms 处只是「还没连上」。
  await waitFor(() => source.isOpen())
  const started = Date.now()
  // 跨过忙碌段落间隔（12s）/ 工具与交付窗口（30s）的整段时间里持续复核。
  while (Date.now() - started < holdMs) {
    assert.ok(source.isOpen(), `${Date.now() - started}ms：上游 socket 必须还活着`)
    assert.ok(!source.inbound.some(m => m.type === 'mute'),
      `${Date.now() - started}ms：不得对上游发 mute —— 那正是真机上答案丢失的那一步`)
    assert.ok(!source.inbound.some(m => m.type === 'interrupt'),
      `${Date.now() - started}ms：任务还在跑，不得 interrupt`)
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 0,
      `${Date.now() - started}ms：交付终态没到，一帧 agent.audio.done 都不许发`)
    await sleep(500)
  }

  await waitFor(() => events.some(e => e.type === 'agent.audio.done'), 10_000)
  await sleep(150)

  const answers = events.filter(e => e.type === 'agent.task' && e.answer?.delta)
  assert.equal(answers.length, 1, '最终文本恰好一次')
  assert.equal(answers[0].answer.delta, answer)

  const dones = events.filter(e => e.type === 'agent.audio.done')
  assert.equal(dones.length, 1, '最终 agent.audio.done 恰好一次')
  assert.equal(events.at(-1).type, 'agent.audio.done', '收口必须是最后一帧')
  assert.ok(events.indexOf(answers[0]) < events.indexOf(dones[0]),
    '最终文本必须排在收口之前')

  const lifecycle = events.filter(e => e.type === 'agent.task'
    && e.task?.id === taskId && e.task?.status === 'completed')
  assert.equal(lifecycle.length, 1, '权威生命周期终态恰好一次')
  assert.ok(events.indexOf(lifecycle[0]) < events.indexOf(dones[0]),
    "agent.task{status:'completed'} 必须排在 agent.audio.done 之前")

  // 12 秒那一枪确实开过（忙碌段落间隔到点），但被在飞任务挡下了。
  const deferred = logs.filter(l => l.evt === 'upstream_turn_terminal_deferred')
  assert.ok(deferred.length > 0,
    '忙碌段落间隔到点必须留下 upstream_turn_terminal_deferred —— 没有它就说明这条回归根本没跨过窗口')
  const terminal = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminal.length, 1, '整轮终态恰好一次')
  assert.equal(terminal[0].awaiting_delivery, 0)
  assert.equal(terminal[0].outstanding_tasks, 0)
}

test('ESS-1159 · 杭州天气：任务跑满 13 秒（跨过 12s 忙碌段落间隔）不得收口', async () => {
  const taskId = 'work_9e37b3be-6764-4840-90a6-8e1813075509'
  const sessionId = 'B4C6D281-550C-4679-8FB3-685831B223BC'
  const answer = '杭州当前天气：气温约 26℃，多云，湿度 84%，北风 2 级，空气质量优。'
  const source = await upstream(ws => {
    delegationPrologue(ws, taskId, sessionId)
    // 真机上 Codex 在 22.272s 才完成；这里压到 13s，仍然跨过 12s 的窗口。
    // 期间**没有任何上游帧**——刻意不靠 `task_activity` 续期，钉的是
    // 「在飞任务本身」就足以否决收口。
    setTimeout(() => deliverAnswer(ws, taskId, sessionId, answer), 13_000)
  })
  const { events, logs, turn } = harness(source.url, sessionId)
  turn.commit()
  try {
    await assertHeldThenDelivered({
      events, logs, source, answer, taskId, holdMs: 12_800,
    })
  } finally { turn.close() }
})

test('ESS-1159 · 知识库：任务跑满 31 秒（跨过 30s 工具/交付窗口）不得收口', async () => {
  const taskId = 'work_11ecbeaf-18ee-4be7-8a8e-6a8e8353a5c1'
  const sessionId = '518197E7-CA2A-4B7B-899F-EE2F4738F236'
  const answer = '最新一篇的核心观点：每日额度尚未官方确认，Responses API 更适合长程任务。'
  const source = await upstream(ws => {
    delegationPrologue(ws, taskId, sessionId)
    // 长任务的真实形状：每 5 秒一帧进展。它既让展示面动起来，也是网关
    // 「上游还在推进」的续期证据（ESS-1111）。
    const ticks = []
    for (let second = 5; second <= 30; second += 5) {
      ticks.push(setTimeout(() => send(ws, {
        type: 'task.stream', protocolVersion: 1,
        taskId, requestId: taskId, sessionId, generation: 1,
        category: 'progress', seq: second, message: `reading ${second}`, status: 'running',
      }), second * 1_000))
    }
    ticks.push(setTimeout(() => deliverAnswer(ws, taskId, sessionId, answer), 31_000))
    ws.on('close', () => { for (const t of ticks) clearTimeout(t) })
  })
  const { events, logs, turn } = harness(source.url, sessionId)
  turn.commit()
  try {
    await assertHeldThenDelivered({
      events, logs, source, answer, taskId, holdMs: 30_800,
    })
  } finally { turn.close() }
})
