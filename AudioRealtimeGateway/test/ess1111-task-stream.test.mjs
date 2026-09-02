// ESS-1111 — Codex 长任务的**增量**（进展 + 答案文本）必须一路到达客户端，
// 且任务还在推进时不得按固定窗口收口。
//
// 上游侧（ESS-1110，`server/src/voice/task-stream-protocol.mjs`）已经把
// reasoning/progress/tool/answer 投影成有序的 `task.stream` 帧：
//   `{type:'task.stream', protocolVersion, taskId, requestId, sessionId,
//     generation, category:'progress'|'text'|'audio'|'terminal', seq, …}`
// 本网关此前**一个 category 都不认**：`task.stream` 会掉进通用 `task.` 分支，
// 被当成一个字面量状态 `'stream'` 原样下发，答案增量则整段丢失。
//
// 本文件钉三件事：
//   1. 投影：progress → `progress_text`，text → `answer_delta`，两条序号互不
//      干扰，未知 category 忽略（加性契约的向前兼容）；
//   2. 线格：无进展 / 无答案时 `task.state` 一个键都不多（老客户端不受影响）；
//   3. 续期：任何一帧真实任务活动都刷新窗口——ESS-1109 真机取证里的 24 s
//      Codex 任务不能因为 12 s / 30 s 的固定预算被判成「没动静」；而真的
//      哑掉时窗口仍然到点收口，不会永久锁死。

import assert from 'node:assert/strict'
import { after, describe, it, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'
import { projectStreamProgress } from '../task-progress.mjs'

// ---------------------------------------------------------------------------
// 投影层（纯函数）
// ---------------------------------------------------------------------------

describe('ESS-1111 · task.stream 进展投影', () => {
  it('把上游状态投影成中文短语，不把协议词原样显示', () => {
    assert.deepEqual(
      projectStreamProgress({ category: 'progress', message: 'running', status: 'running' }),
      { text: '正在处理', category: 'running' },
    )
    assert.deepEqual(
      projectStreamProgress({ category: 'progress', message: 'queued', status: 'queued' }),
      { text: '正在排队', category: 'queued' },
    )
  })

  it('没有已知状态时显示上游那句 message，客户端不自己编', () => {
    assert.deepEqual(
      projectStreamProgress({ category: 'progress', message: '正在查询相关信息' }),
      { text: '正在查询相关信息', category: 'progress' },
    )
  })

  it('终态帧不产出进展文字（终态由 status 独占表达）', () => {
    for (const status of ['completed', 'failed', 'cancelled']) {
      assert.equal(projectStreamProgress({ category: 'progress', message: 'x', status }), null)
    }
  })

  it('空消息 / 非对象一律 null，绝不产出一行空白', () => {
    assert.equal(projectStreamProgress(null), null)
    assert.equal(projectStreamProgress({ category: 'progress', message: '   ' }), null)
  })

  it('老路径的口径不受影响：running 仍然由 activity 决定，不被新表劫持', async () => {
    const { projectTaskProgress } = await import('../task-progress.mjs')
    assert.deepEqual(
      projectTaskProgress({
        status: 'running',
        activity: [{ kind: 'tool', tool: 'web_search', status: 'running', category: 'search' }],
      }, 'task.progress'),
      { text: '正在查询相关信息', category: 'search' },
    )
  })
})

// ---------------------------------------------------------------------------
// 线格层（RealtimeSession）
// ---------------------------------------------------------------------------

function harness() {
  const sent = []
  const logs = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'd-1', session_id: 's-1', request_id: 'r-1', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  return { session, sent, logs, agent }
}

const taskState = sent => sent.filter(f => f.type === 'task.state')
const RESPONSE_ID = 'r-1:gen1'

describe('ESS-1111 · task.state 携带答案增量', () => {
  it('答案增量下发 answer_delta + 每会话单调的 answer_seq', () => {
    const { sent, agent } = harness()
    for (const delta of ['杭州', '今天', '晴']) {
      agent.emit('r-1', {
        type: 'agent.task', response_id: RESPONSE_ID,
        task: { id: 'work_1', status: 'running' }, answer: { delta },
      })
    }
    const frames = taskState(sent)
    assert.deepEqual(frames.map(f => f.answer_delta), ['杭州', '今天', '晴'])
    assert.deepEqual(frames.map(f => f.answer_seq), [1, 2, 3])
    assert.ok(frames.every(f => f.progress_text === undefined),
      '答案帧不得夹带进展键')
  })

  it('进展与答案各走各的序号空间，互不推进', () => {
    const { sent, agent } = harness()
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, progress: { text: '正在查询相关信息', category: 'search' },
    })
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, answer: { delta: '杭州' },
    })
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, progress: { text: '正在整理结果', category: 'text' },
    })
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, answer: { delta: '今天晴' },
    })
    const frames = taskState(sent)
    assert.deepEqual(
      frames.map(f => [f.progress_seq ?? null, f.answer_seq ?? null]),
      [[1, null], [null, 1], [2, null], [null, 2]],
    )
  })

  it('答案增量不占用音频 sequence：音频序号逐字节不受影响', () => {
    const { sent, agent } = harness()
    const audio = sequence => ({
      type: 'agent.audio.delta', response_id: RESPONSE_ID, sequence,
      sample_rate: 24_000, codec: 'pcm_s16le',
      audio: Buffer.from([sequence]).toString('base64'),
    })
    agent.emit('r-1', audio(0))
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, answer: { delta: '杭州' },
    })
    agent.emit('r-1', audio(1))
    assert.deepEqual(
      sent.filter(f => f.type === 'audio.delta').map(f => f.sequence), [0, 1],
    )
  })

  it('无答案的任务帧一个键都不多（老客户端逐字节不受影响）', () => {
    const { sent, agent } = harness()
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID, task: { id: 'work_1', status: 'running' },
    })
    const frame = taskState(sent)[0]
    assert.deepEqual(Object.keys(frame).sort(),
      ['generation', 'request_id', 'session_id', 'status', 'task_id', 'type'].sort())
  })

  it('空字符串增量不下发：一个没有文字的「答案」对用户是零信息', () => {
    const { sent, agent } = harness()
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, answer: { delta: '' },
    })
    assert.equal(taskState(sent)[0].answer_delta, undefined)
  })

  it('日志只记序号与长度，不落答案原文（用户内容）', () => {
    const { logs, agent } = harness()
    agent.emit('r-1', {
      type: 'agent.task', response_id: RESPONSE_ID,
      task: { id: 'work_1', status: 'running' }, answer: { delta: '杭州今天晴' },
    })
    const line = logs.find(l => l.evt === 'downlink_task_state')
    assert.equal(line.answer_seq, 1)
    assert.equal(line.answer_delta_length, 5)
    assert.ok(!JSON.stringify(line).includes('杭州'))
  })
})

// ---------------------------------------------------------------------------
// 适配层（QwenAgentTransport）—— 真实上游 socket
// ---------------------------------------------------------------------------

const servers = []
after(async () => {
  await Promise.all(servers.splice(0).map(server => new Promise(resolve => {
    // 一条断言失败会跳过 `turn.close()`，留下的 socket 会让 `server.close()`
    // 一直等下去——那会把一次可读的断言失败变成一次不可读的整文件超时。
    for (const client of server.clients) client.terminate()
    server.close(resolve)
  })))
})

async function upstream(onMessage) {
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on('connection', ws => {
    ws.on('message', raw => onMessage(ws, JSON.parse(raw.toString())))
  })
  await new Promise(resolve => server.once('listening', resolve))
  return `ws://127.0.0.1:${server.address().port}/api/realtime`
}

function waitFor(predicate, timeoutMs = 4_000) {
  const started = Date.now()
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (predicate()) return resolve()
      if (Date.now() - started > timeoutMs) return reject(new Error('waitFor timeout'))
      setTimeout(poll, 5)
    }
    poll()
  })
}

const send = (ws, event) => ws.send(JSON.stringify(event))
const audioDelta = (ws, sequence, text) => send(ws, {
  type: 'audio.delta', sequence, audio: Buffer.from(text).toString('base64'), sampleRate: 24_000,
})
const streamFrame = (over = {}) => ({
  type: 'task.stream', protocolVersion: 1,
  taskId: 'work_codex', requestId: 'work_codex', sessionId: 's1', generation: 1,
  ...over,
})

test('ESS-1111 · task.stream 的进展与答案增量各自投影，不再被当成状态 `stream`', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, streamFrame({ category: 'progress', seq: 0, message: 'running', status: 'running' }))
      send(ws, streamFrame({ category: 'progress', seq: 1, message: '正在查询相关信息' }))
      send(ws, streamFrame({ category: 'text', seq: 0, delta: '杭州' }))
      send(ws, streamFrame({ category: 'text', seq: 1, delta: '今天晴' }))
      // 加性契约：未来新增的 category 必须被忽略，而不是下发成垃圾帧。
      send(ws, streamFrame({ category: 'reasoning_v2', seq: 0, message: 'x' }))
      send(ws, streamFrame({ category: 'audio', seq: 0 }))
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0, segmentGapMs: 60_000, segmentGapBusyMs: 60_000,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r1', sessionId: 's1', deviceId: 'd1', generation: 1, responseId: 'r1:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  try {
  await waitFor(() => events.filter(e => e.type === 'agent.task').length === 4)
  await new Promise(resolve => setTimeout(resolve, 80))

  const tasks = events.filter(e => e.type === 'agent.task')
  assert.equal(tasks.length, 4, '未知 category 与 audio 不产生下发事件')
  assert.deepEqual(tasks.map(e => e.progress?.text ?? null),
    ['正在处理', '正在查询相关信息', null, null])
  assert.deepEqual(tasks.map(e => e.answer?.delta ?? null),
    [null, null, '杭州', '今天晴'])
  assert.ok(tasks.every(e => e.task.status !== 'stream'),
    '`task.stream` 不得被当成一个名叫 stream 的任务状态')
  assert.ok(tasks.every(e => e.task.id === 'work_codex'))
  // 取证线存在，且不落答案原文。
  const streamLogs = logs.filter(l => l.evt === 'upstream_task_stream')
  assert.equal(streamLogs.length, 6, '每一帧都留证，含被忽略的 category')
  assert.equal(streamLogs.find(l => l.category === 'text').delta_length, 2)
  assert.ok(!JSON.stringify(streamLogs).includes('杭州'))
  } finally { turn.close() }
})

test('ESS-1111 · 任务持续报进展时不按固定窗口收口（ESS-1109 的 24 s 复现夹具）', async () => {
  // 窗口按 1:100 缩放跑真机时序：忙档 12 s → 120 ms，任务窗口 30 s → 300 ms，
  // 任务全长 24 s → 240 ms，进展每秒 → 每 10 ms。旧代码下两个窗口都是从
  // 「段落收口 / 首次挂起」一次性起表，必然在任务结束前收口。
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'task.running', task: { id: 'work_codex', status: 'running' } })
      send(ws, { type: 'audio.done' })
      // 24 s 的 Codex 任务：每 10 ms 一帧进展，最后才终态。
      let ticks = 0
      const timer = setInterval(() => {
        ticks += 1
        send(ws, streamFrame({ category: 'progress', seq: ticks, message: 'running', status: 'running' }))
        if (ticks === 24) {
          clearInterval(timer)
          send(ws, streamFrame({ category: 'text', seq: 0, delta: '杭州今天晴' }))
          send(ws, { type: 'task.completed', task: { id: 'work_codex', status: 'completed' } })
        }
      }, 10)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0,
    // 两个窗口都**短于**任务全长（240 ms）：一次性预算必然在任务结束前到点，
    // 只有「按静默时长续期」才能让这一条通过。
    segmentGapMs: 40, segmentGapBusyMs: 100, toolCallWindowMs: 100,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r2', sessionId: 's2', deviceId: 'd2', generation: 1, responseId: 'r2:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()

  try {
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    // 顺序即结论：答案增量必须排在回合终态**之前**。旧代码下固定窗口会在
    // 第 12 帧进展附近收口，答案那一帧根本到不了客户端。
    const answerAt = events.findIndex(e => e.type === 'agent.task' && e.answer)
    const doneAt = events.findIndex(e => e.type === 'agent.audio.done')
    assert.ok(answerAt >= 0, '答案增量必须到达客户端')
    assert.ok(answerAt < doneAt, '答案增量必须早于回合终态——那正是真机丢答案的入口')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1, '终态只发一次')
    assert.equal(logs.filter(l => l.evt === 'upstream_turn_terminal').length, 1)
    assert.equal(logs.find(l => l.evt === 'upstream_turn_terminal').reason,
      'task_terminal_audio_done', '收口理由必须是任务真的完成了，不是窗口到点')
    assert.ok(events.filter(e => e.type === 'agent.task' && e.progress).length >= 20,
      '24 帧进展应当基本无损地到达客户端')
    // 续期确实发生过：挂起的终态窗口逐帧重新起表，而不是一次性预算。
    assert.ok(logs.filter(l => l.evt === 'upstream_task_terminal_window_armed').length > 1,
      '挂起的终态窗口必须逐帧续期，而不是一次性预算')
  } finally {
    turn.close()
  }
})

test('ESS-1111 · 上游真的哑掉时窗口照常到点收口，续期不等于永久锁死', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'task.running', task: { id: 'work_stuck', status: 'running' } })
      send(ws, streamFrame({ taskId: 'work_stuck', category: 'progress', seq: 0, message: 'running', status: 'running' }))
      send(ws, { type: 'audio.done' })
      // 之后彻底沉默：既没有进展，也没有终态。
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0,
    segmentGapMs: 40, segmentGapBusyMs: 80, toolCallWindowMs: 150,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r3', sessionId: 's3', deviceId: 'd3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'), 5_000)
    const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
    assert.equal(terminal.reason, 'tool_task_timeout', '静默超时仍然收口，理由可判定')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1)
  } finally { turn.close() }
})

test('ESS-1111 · 分段回合里，任务活动把停放段落的空闲窗口从这一刻重算', async () => {
  // 与上一条的区别只有一个：上游发 `voice.state`，于是走 ESS-990 的分段路径，
  // 段落被停放、空闲窗口起表。旧代码的窗口从**段落收口**那一刻算死
  //（`segmentClosedAt + window`），任务再怎么报进展也不顺延——12 s 忙档到点
  // 就把还在跑的任务连同它的答案一起收掉。
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, '我正在查询')
      send(ws, { type: 'task.running', task: { id: 'work_codex', status: 'running' } })
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      let ticks = 0
      const timer = setInterval(() => {
        ticks += 1
        send(ws, streamFrame({ category: 'progress', seq: ticks, message: '正在查询相关信息' }))
        if (ticks === 24) {
          clearInterval(timer)
          send(ws, streamFrame({ category: 'text', seq: 0, delta: '杭州今天晴' }))
          send(ws, { type: 'task.completed', task: { id: 'work_codex', status: 'completed' } })
        }
      }, 10)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0,
    // 忙档 100 ms 远短于任务全长 240 ms：旧口径（从段落收口起表）必然提前收口。
    segmentGapMs: 40, segmentGapBusyMs: 100, toolCallWindowMs: 300,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r5', sessionId: 's5', deviceId: 'd5', generation: 1, responseId: 'r5:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  try {
    await waitFor(() => events.some(e => e.type === 'agent.audio.done'))
    const answerAt = events.findIndex(e => e.type === 'agent.task' && e.answer)
    const doneAt = events.findIndex(e => e.type === 'agent.audio.done')
    assert.ok(answerAt >= 0 && answerAt < doneAt, '答案增量必须早于回合终态')
    assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1, '终态只发一次')
    assert.ok(logs.some(l => l.evt === 'upstream_segment_gap_armed'
      && l.cause === 'task_activity' && l.base === 'task_activity'),
    '空闲窗口必须以最近一次任务活动为基准重算')
    // 任务终态到达前，窗口一次都没有到点。
    assert.ok(!logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'tool_task_timeout'))
  } finally { turn.close() }
})
