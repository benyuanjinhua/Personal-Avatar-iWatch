// ESS-969 — 一个回合承载多段回答。
//
// 事故：工具调用回合的第二段（真正的答案）一帧都到不了 Watch。
// ESS-957 的复现脚本原样保留在第一条用例里：第一段 done 之后，第二段的
// delta 全部被 `post_done` 丢弃，客户端只收到 ready → delta(0) → audio.done。
//
// 两层各自钉住：
//   • RealtimeSession —— `agent.audio.segment_done` 是段落边界，不是回合终态；
//     `doneEmitted` 只由回合终态置位、且永不复位（ESS-957 欠的那条用例）。
//   • QwenAgentTransport —— 回合终态取自上游信号（`voice.state {state:'idle'}`），
//     不是超时；上游不发该信号时退回 ESS-969 之前的行为，逐字节不变。

import assert from 'node:assert/strict'
import { afterEach, describe, it, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { RealtimeSession } from '../realtime-session.mjs'
import { ScriptedAgentTransport } from '../agent-transport.mjs'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

// ---------------------------------------------------------------------------
// RealtimeSession 层
// ---------------------------------------------------------------------------

function harness(overrides = {}) {
  const sent = []
  const logs = []
  const closes = []
  const agent = new ScriptedAgentTransport()
  const scope = { device_id: 'jackson-iphone', session_id: 's-1', request_id: 'r-1', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: (code, reason) => closes.push({ code, reason }),
    agentTransport: agent,
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0,
    idleDisconnectMs: 0,
    commitDeadlineMs: 0,
    ...overrides,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start',
    session_id: scope.session_id, request_id: scope.request_id,
    generation: scope.generation, protocol_version: 1,
  }))
  return { session, sent, logs, closes, agent, scope }
}

const RESPONSE_ID = 'r-1:gen1'
const delta = sequence => ({
  type: 'agent.audio.delta', response_id: RESPONSE_ID, sequence,
  sample_rate: 24_000, codec: 'pcm_s16le',
  audio: Buffer.from([sequence, sequence, sequence, sequence]).toString('base64'),
})

describe('ESS-969 · RealtimeSession 分段语义', () => {
  it('第二段的 delta 在段落边界之后仍然下发，不再按 post_done 丢弃', () => {
    const { sent, logs, agent } = harness()
    // 第一段：一帧音频 + 段落边界。
    agent.emit('r-1', delta(0))
    agent.emit('r-1', {
      type: 'agent.audio.segment_done', response_id: RESPONSE_ID,
      segment_index: 0, final_sequence: 0,
    })
    // 第二段：真正的答案。ESS-957 之前这三帧全被丢弃。
    agent.emit('r-1', delta(1))
    agent.emit('r-1', delta(2))
    agent.emit('r-1', delta(3))
    agent.emit('r-1', {
      type: 'agent.audio.done', response_id: RESPONSE_ID, final_sequence: 3,
    })

    assert.deepEqual(sent.map(f => f.type), [
      'ready', 'audio.delta', 'audio.segment_done',
      'audio.delta', 'audio.delta', 'audio.delta', 'audio.done',
    ])
    // 顺序正确：段落边界在第一段之后、第二段之前。
    assert.deepEqual(sent.filter(f => f.type === 'audio.delta').map(f => f.sequence), [0, 1, 2, 3])
    const boundary = sent.find(f => f.type === 'audio.segment_done')
    assert.equal(boundary.segment_index, 0)
    assert.equal(boundary.final_sequence, 0)
    assert.equal(boundary.response_id, RESPONSE_ID)
    assert.equal(boundary.generation, 1)
    assert.equal(sent.at(-1).final_sequence, 3)
    // 一帧都没被丢。
    assert.equal(logs.filter(l => l.evt === 'post_done_audio_dropped').length, 0)
    assert.equal(sent.filter(f => f.type === 'audio.segment_dropped').length, 0)
  })

  it('doneEmitted 只由回合终态置位：段落边界之后仍为 false', () => {
    const { session, agent } = harness()
    agent.emit('r-1', delta(0))
    agent.emit('r-1', {
      type: 'agent.audio.segment_done', response_id: RESPONSE_ID,
      segment_index: 0, final_sequence: 0,
    })
    assert.equal(session.doneEmitted, false, '段落边界不得置位回合终态闩锁')
    assert.equal(session.segmentsEmitted, 1)
    assert.equal(session.finalSequence, null)

    agent.emit('r-1', delta(1))
    agent.emit('r-1', { type: 'agent.audio.done', response_id: RESPONSE_ID, final_sequence: 1 })
    assert.equal(session.doneEmitted, true)
    assert.equal(session.finalSequence, 1)
  })

  it('回合终态之后的段落边界与音频仍然被丢弃并可观测（闩锁不复位）', () => {
    const { session, sent, logs, agent } = harness()
    agent.emit('r-1', delta(0))
    agent.emit('r-1', { type: 'agent.audio.done', response_id: RESPONSE_ID, final_sequence: 0 })
    assert.equal(session.doneEmitted, true)

    agent.emit('r-1', {
      type: 'agent.audio.segment_done', response_id: RESPONSE_ID,
      segment_index: 1, final_sequence: 1,
    })
    agent.emit('r-1', delta(1))

    assert.equal(session.doneEmitted, true, 'doneEmitted 永不复位')
    assert.ok(logs.some(l => l.evt === 'segment_done_after_turn_done'))
    const dropped = sent.filter(f => f.type === 'audio.segment_dropped')
    assert.equal(dropped.length, 1)
    assert.equal(dropped[0].reason, 'post_done')
    assert.equal(session.postDoneAudioDropped, 1)
    // 终态之后不得再有 audio.delta / audio.segment_done 下发。
    assert.equal(sent.filter(f => f.type === 'audio.segment_done').length, 0)
    assert.deepEqual(sent.filter(f => f.type === 'audio.delta').map(f => f.sequence), [0])
  })

  it('段落边界与回合终态一样受稠密前缀屏障约束：有洞时先扣住', () => {
    const { sent, agent } = harness()
    // 段落宣称到 seq=2，但 seq=1 还没到。
    agent.emit('r-1', delta(0))
    agent.emit('r-1', delta(2))
    agent.emit('r-1', {
      type: 'agent.audio.segment_done', response_id: RESPONSE_ID,
      segment_index: 0, final_sequence: 2,
    })
    assert.equal(sent.filter(f => f.type === 'audio.segment_done').length, 0, '有洞时不得放行边界')

    agent.emit('r-1', delta(1))   // 补洞
    const boundary = sent.find(f => f.type === 'audio.segment_done')
    assert.ok(boundary, '洞补齐后边界才放行')
    assert.equal(boundary.final_sequence, 2)
    // 边界必须排在补洞帧之后，客户端才不会把 seq=1 归到下一段。
    assert.equal(sent.at(-1).type, 'audio.segment_done')
  })

  it('单段回合的下发帧序与 ESS-969 之前完全一致（老客户端兼容）', () => {
    const { sent, agent } = harness()
    agent.emit('r-1', delta(0))
    agent.emit('r-1', delta(1))
    agent.emit('r-1', { type: 'agent.audio.done', response_id: RESPONSE_ID, final_sequence: 1 })
    assert.deepEqual(sent.map(f => f.type), ['ready', 'audio.delta', 'audio.delta', 'audio.done'])
  })

  it('空段落（final_sequence < 0）不产生边界帧', () => {
    const { sent, agent } = harness()
    agent.emit('r-1', {
      type: 'agent.audio.segment_done', response_id: RESPONSE_ID,
      segment_index: 0, final_sequence: -1,
    })
    assert.equal(sent.filter(f => f.type === 'audio.segment_done').length, 0)
  })
})

// ---------------------------------------------------------------------------
// QwenAgentTransport 层 —— 回合终态取自上游信号
// ---------------------------------------------------------------------------

const servers = []
afterEach(async () => {
  await Promise.all(servers.splice(0).map(server => new Promise(resolve => {
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

function waitFor(predicate, timeoutMs = 2_000) {
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

// 从 PR #377（ESS-1004，同一作者）搬过来的一条：终态必须一路走到
// `downlink_done` —— 那正是真机日志里 0 次的那条。#377 的另外两条钉的是
// 已被本 PR 删除的 `turnIdleBackstopMs`，随常数一起作废（说明见 ESS-990）。
test('ESS-990 · 回合终态必然产出 downlink_done（承自 ESS-1004）', () => {
  const { session, sent, logs, agent } = harness()
  agent.emit('r-1', delta(0))
  agent.emit('r-1', {
    type: 'agent.audio.segment_done', response_id: RESPONSE_ID,
    segment_index: 0, final_sequence: 0,
  })
  agent.emit('r-1', delta(1))
  agent.emit('r-1', {
    type: 'agent.audio.done', response_id: RESPONSE_ID, final_sequence: 1, segments: 2,
  })
  assert.equal(
    logs.filter(l => l.evt === 'downlink_done').length, 1,
    'downlink_done 是真机上 0 次的那条日志：终态到达时它必须出现，且只出现一次',
  )
  assert.equal(sent.filter(f => f.type === 'audio.done').length, 1)
  assert.equal(sent.find(f => f.type === 'audio.done').final_sequence, 1)
  assert.equal(session.doneEmitted, true)
})

// ---------------------------------------------------------------------------
// ESS-990 —— 回合终态判据取证后的重写。
//
// #365 的判据（`voice.state {state:'idle'}` 收回合）已被 L1 推翻：
// 2026-08-22 对真实上游（`ws://127.0.0.1:3101/api/realtime`）跑了 10 个工具
// 调用回合，idle 在**每一段** `audio.done` 之后 0.14–0.54 ms 内到达，
// 10/10 的回合在首条 idle 之后又开了新段（取证脚本：
// `smoke/upstream-turn-capture.mjs`，原始帧与统计贴在 ESS-990）。
// L2 侧一致：上游 `server/src/voice/realtime-gateway.mjs` 在
// `finishPlayback` / `cancelPlayback` 每段播完就发 idle，
// `shared/realtime-events.mjs` 里根本没有回合终态事件。
//
// 现在的判据：段落收口后有界空闲窗口；上游忙（播报在途 / 未终结 task）时
// 用延长档。下面每条用例都把窗口设成毫秒级，靠**时序**而不是靠跑得快取胜。
// ---------------------------------------------------------------------------

test('ESS-990 · voice.state idle 不再收口回合：第一段之后 idle 到达，第二段仍然到客户端', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      // 第一段：「我正在查询杭州天气」——真实上游的形状：done 之后立刻 idle。
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      // 工具执行的秒级停顿（实测 326.6–7332.5 ms）。
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
        audioDelta(ws, 1, 'seg2-a')
        audioDelta(ws, 2, 'seg2-b')
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'voice.state', state: 'idle', origin: 'agent' })
      }, 400)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 900, segmentGapBusyMs: 900,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r1', sessionId: 's1', deviceId: 'd1', generation: 1, responseId: 'r1:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta',        // 第一段
    'agent.audio.segment_done', // 段落边界（回合未终结）
    'agent.audio.delta',        // 第二段——#365 的判据下这两帧会被 post-done 丢掉
    'agent.audio.delta',
    'agent.audio.done',         // 回合终态
  ])
  const boundary = events.find(e => e.type === 'agent.audio.segment_done')
  assert.equal(boundary.segment_index, 0)
  assert.equal(boundary.final_sequence, 0)
  const done = events.at(-1)
  assert.equal(done.final_sequence, 2, '回合终态覆盖两段的全部序号')
  assert.equal(done.segments, 2)
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_mode' && l.mode === 'multi_segment'))
  // 终态来自空闲窗口，而不是 idle。
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'segment_gap'))
  assert.equal(logs.filter(l => l.evt === 'upstream_turn_terminal').length, 1, '唯一终态')
  assert.ok(logs.filter(l => l.evt === 'upstream_voice_state_idle').length >= 2,
    'idle 仍然被记录，只是不再决定终态')
  turn.close()
})

test('ESS-990 · 上游不发 voice.state 时保持 ESS-969 之前的行为（auto 能力探测）', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      audioDelta(ws, 0, 'only')
      send(ws, { type: 'audio.done' })
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    // 窗口设成 60 s：legacy 路径若误走窗口，用例会超时而不是变绿。
    gatewayUrl: url, segmentGapMs: 60_000, segmentGapBusyMs: 60_000,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r2', sessionId: 's2', deviceId: 'd2', generation: 1, responseId: 'r2:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  // 逐字节与 ESS-969 之前一致：没有额外的 segment_done，done 立刻到。
  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_mode'
    && l.mode === 'legacy' && l.saw_voice_state === false))
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'legacy_first_done'))
  turn.close()
})

test('ESS-990 · 单段回合：窗口到期收口，不产生多余的段落边界', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'only')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 250, segmentGapBusyMs: 60_000,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r3', sessionId: 's3', deviceId: 'd3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.equal(events.at(-1).segments, 1)
  // 没有忙证据 ⇒ 走基础档。
  const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminal.reason, 'segment_gap')
  assert.equal(terminal.window_ms, 250)
  assert.equal(terminal.outstanding_tasks, 0)
  turn.close()
})

test('ESS-1096 · 未终结 task 否决普通窗口收口，terminal 后才释放', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      // 实测形状：task.accepted 比第一段 done 晚 795–8689 ms，顶层 taskId 为空，
      // id 挂在 event.task.id 上（2026-08-22 抓包）。
      setTimeout(() => send(ws, {
        type: 'task.accepted',
        task: {
          id: 'work_0728ac87', workId: 'work_0728ac87', status: 'queued',
          sessionId: 'watch-direct-s4-1', turnId: 'text_abc',
        },
      }), 120)
      setTimeout(() => send(ws, {
        type: 'task.completed', task: { id: 'work_0728ac87', status: 'completed' },
      }), 1_000)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 200, segmentGapBusyMs: 1_400,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r4', sessionId: 's4', deviceId: 'd4', generation: 1, responseId: 'r4:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  // 基础档（200 ms）早就过了，延长档（1400 ms）还没到：回合必须仍然开着。
  await waitFor(() => events.some(e => e.type === 'agent.task'), 2_000)
  await new Promise(resolve => setTimeout(resolve, 500))
  assert.ok(!events.some(e => e.type === 'agent.audio.done'),
    '未终结 task 在途时不得按基础档收口')
  // 即使忙档已过也不能收口；task terminal 到达后才释放已完成的 audio barrier。
  await waitFor(() => events.some(e => e.type === 'agent.audio.done'), 4_000)
  const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminal.reason, 'segment_gap')
  assert.equal(terminal.window_ms, 200)
  assert.equal(terminal.outstanding_tasks, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_turn_busy' && l.cause === 'task_in_flight'))
  assert.ok(logs.some(l => l.evt === 'upstream_turn_busy_cleared' && l.cause === 'task_terminal'))
  turn.close()
})

test('ESS-990 · task 终态把它移出未终结集合；真实帧的三种 id 形状都认', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'task.accepted', task: { id: 'work_a', status: 'queued' } })
      send(ws, { type: 'task.running', task: { workId: 'work_b', status: 'running' } })
      send(ws, { type: 'task.running', taskId: 'work_c' })
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      setTimeout(() => {
        send(ws, { type: 'task.completed', task: { id: 'work_a', status: 'completed' } })
        send(ws, { type: 'task.failed', task: { id: 'work_b', status: 'failed' } })
      }, 100)
      setTimeout(() => {
        send(ws, { type: 'task.cancelled', task: { id: 'work_c', status: 'cancelled' } })
      }, 250)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 100, segmentGapBusyMs: 700,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r5', sessionId: 's5', deviceId: 'd5', generation: 1, responseId: 'r5:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)
  // 三种形状都被认成 lifecycle，并原样转发给下游。
  assert.deepEqual(
    events.filter(e => e.type === 'agent.task').map(e => e.task.id),
    ['work_a', 'work_b', 'work_c', 'work_a', 'work_b', 'work_c'],
  )
  const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminal.outstanding_tasks, 0)
  // 所有 task terminal 后 busy 清除，已完成音频按基础窗口安全释放。
  assert.equal(terminal.window_ms, 100)
  turn.close()
})

test('ESS-990 · 后台播报占着声道：不产生段落边界，但把窗口抬到延长档（ESS-36）', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      setTimeout(() => {
        // 无关后台播报：不是本回合的段落，也不是终态（实测在第一段 done 之后
        // 237–361 ms 到达，并且它一到，本回合的下一段就会晚 2.7–7.3 s）。
        send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement', taskId: 'work_x' })
        send(ws, { type: 'voice.state', state: 'idle', origin: 'announcement' })
        setTimeout(() => {
          send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
          audioDelta(ws, 1, 'seg2')
          send(ws, { type: 'audio.done' })
          send(ws, { type: 'voice.state', state: 'idle', origin: 'agent' })
        }, 500)
      }, 100)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    // 基础档 200 ms 远小于 600 ms 的段落间隔：没有播报证据这条用例必红。
    gatewayUrl: url, segmentGapMs: 200, segmentGapBusyMs: 1_500,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r6', sessionId: 's6', deviceId: 'd6', generation: 1, responseId: 'r6:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 5_000)
  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta', 'agent.audio.segment_done', 'agent.audio.delta', 'agent.audio.done',
  ])
  assert.equal(events.at(-1).final_sequence, 1)
  assert.equal(events.filter(e => e.type === 'agent.audio.segment_done').length, 1,
    '播报不得制造段落边界')
  assert.ok(logs.some(l => l.evt === 'upstream_turn_busy' && l.cause === 'announcement_response'))
  turn.close()
})

test('ESS-990 · 上游 socket 关闭把挂起的段落收成回合终态，而不是等空闲窗口', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      setTimeout(() => ws.close(1000, 'done'), 300)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    // 窗口设得远大于用例时长：若它才是收口机制，用例会超时而不是通过。
    gatewayUrl: url, segmentGapMs: 60_000, segmentGapBusyMs: 60_000,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r7', sessionId: 's7', deviceId: 'd7', generation: 1, responseId: 'r7:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.ok(!events.some(e => e.type === 'agent.error'), '完成的回合不得表现为掉线')
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'upstream_closed'))
  turn.close()
})

// 乱序洞（原 B1，毕玄 review on PR #365）：`reorderWaitMs` 的存在本身就说明
// 上游会在帧还在飞的时候发 `audio.done`。窗口从**段落收口那一刻**起算，
// 所以迟到的尾帧不会让回合白等——不再需要闩住任何终态。
test('ESS-990 · 乱序洞：迟到尾帧补齐后按窗口收口，终态覆盖补齐的尾帧', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seq0')
      audioDelta(ws, 2, 'seq2')                                  // seq1 缺席，进重排缓冲
      send(ws, { type: 'audio.done' })                           // 洞未补齐 → flushDone 直接返回
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      setTimeout(() => audioDelta(ws, 1, 'seq1'), 120)           // 在 reorderWaitMs(300ms) 内补齐
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 250, segmentGapBusyMs: 250,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r8', sessionId: 's8', deviceId: 'd8', generation: 1, responseId: 'r8:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta', 'agent.audio.delta', 'agent.audio.delta', 'agent.audio.done',
  ])
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1, '唯一终态')
  assert.equal(events.at(-1).final_sequence, 2, '终态覆盖迟到补齐的尾帧')
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'segment_gap'))
  turn.close()
})

test('ESS-990 · 乱序洞之后又开了新段：两段都完整，且只有一个终态', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1-a')
      audioDelta(ws, 2, 'seg1-c')                                // 洞：seq1
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
        audioDelta(ws, 1, 'seg1-b')                              // 同时补齐第一段的洞
        audioDelta(ws, 3, 'seg2')
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'voice.state', state: 'idle', origin: 'agent' })
      }, 120)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 400, segmentGapBusyMs: 400,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r9', sessionId: 's9', deviceId: 'd9', generation: 1, responseId: 'r9:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)
  assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1, '唯一终态')
  assert.equal(events.at(-1).final_sequence, 3, '第二段的帧不得被截掉')
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2, 3])
  turn.close()
})

// ---------------------------------------------------------------------------
// 全栈 —— 上游脚本 → QwenAgentTransport → RealtimeSession → 客户端帧
//
// 这是 ESS-957 现场复现的直接对照物。修复前该用例给出：
//   下发给客户端的全部帧：ready → audio.delta(0) → audio.done
//   post_done_audio_dropped = 3 | 错误码 = ERR_UPSTREAM_AUDIO_AFTER_DONE
// ---------------------------------------------------------------------------

test('ESS-990 · 全栈：真实上游时序（每段 done 后立刻 idle）下两段音频都到客户端', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, '我正在查询杭州天气')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })   // 实测：done 后 0.2 ms
      setTimeout(() => {
        send(ws, { type: 'task.accepted', task: { id: 'work_weather', status: 'queued' } })
      }, 100)
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'agent' })
        audioDelta(ws, 1, '杭州现在')
        audioDelta(ws, 2, '晴，28 度')
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'voice.state', state: 'idle', origin: 'agent' })
        send(ws, { type: 'task.completed', task: { id: 'work_weather', status: 'completed' } })
      }, 600)
    }
  })
  const sent = []; const logs = []
  const scope = { device_id: 'd10', session_id: 's10', request_id: 'r10', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    // 基础档 250 ms 小于 600 ms 的段落间隔：第二段能到，靠的是 task 抬起的延长档。
    agentTransport: new QwenAgentTransport({ gatewayUrl: url, segmentGapMs: 250, segmentGapBusyMs: 1_200 }),
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start', session_id: 's10', request_id: 'r10', generation: 1, protocol_version: 1,
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.append', session_id: 's10', request_id: 'r10', generation: 1,
    sequence: 0, audio: Buffer.from('uplink!!').toString('base64'),
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.commit', session_id: 's10', request_id: 'r10', generation: 1, sequence: 0,
  }))
  await waitFor(() => sent.some(frame => frame.type === 'audio.done'), 6_000)

  // ESS-1097：`task.state` 现在也走下行（客户端需要它才知道「工具还在跑」）。
  // 这里把它**显式**写进期望序列而不是过滤掉——它落在哪一步是契约的一部分：
  // 任务事实必须在第二段音频之前到达客户端，否则客户端在段落间隙里仍然是
  // 瞎的，本单等于没做。
  assert.deepEqual(sent.map(f => f.type), [
    'ready', 'audio.delta', 'task.state',
    'audio.segment_done', 'audio.delta', 'audio.delta', 'audio.done',
  ])
  const taskFrame = sent.find(f => f.type === 'task.state')
  assert.equal(taskFrame.task_id, 'work_weather')
  assert.equal(taskFrame.status, 'queued')
  assert.equal(taskFrame.request_id, 'r10')
  assert.equal(taskFrame.session_id, 's10')
  assert.equal(taskFrame.generation, 1)
  assert.deepEqual(sent.filter(f => f.type === 'audio.delta').map(f => f.sequence), [0, 1, 2])
  assert.equal(sent.at(-1).final_sequence, 2)
  assert.equal(session.doneEmitted, true)
  assert.equal(session.postDoneAudioDropped, 0, '第二段一帧都不许被丢')
  assert.equal(session.segmentsEmitted, 1)
  assert.ok(!sent.some(f => f.type === 'error'))
  session.onSocketClose(1000, 'test_done')
})
