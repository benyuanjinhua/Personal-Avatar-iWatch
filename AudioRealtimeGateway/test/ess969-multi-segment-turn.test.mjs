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
  await Promise.all(servers.splice(0).map(server => new Promise(resolve => server.close(resolve))))
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

// 上游真实事件形状取自部署中的 Bridge 对同一端点的读法
// （MacRemoteFrontendBridge/supervisor.mjs）：response.started 开段、
// audio.done 收段、voice.state{state:'idle'} 收回合。
test('ESS-969 · 工具调用回合：两段音频都被转发，回合终态取自 voice.state idle', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      // 第一段：「我正在查询杭州天气」
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      // 工具执行的秒级停顿——用 doneSettleMs 之外的延迟模拟。
      setTimeout(() => {
        // 第二段：真正的答案
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'model' })
        audioDelta(ws, 1, 'seg2-a')
        audioDelta(ws, 2, 'seg2-b')
        send(ws, { type: 'audio.done' })
        setTimeout(() => send(ws, { type: 'voice.state', state: 'idle', origin: 'model' }), 200)
      }, 400)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r1', sessionId: 's1', deviceId: 'd1', generation: 1, responseId: 'r1:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta',        // 第一段
    'agent.audio.segment_done', // 段落边界（回合未终结）
    'agent.audio.delta',        // 第二段
    'agent.audio.delta',
    'agent.audio.done',         // 回合终态
  ])
  const boundary = events.find(e => e.type === 'agent.audio.segment_done')
  assert.equal(boundary.segment_index, 0)
  assert.equal(boundary.final_sequence, 0)
  const done = events.at(-1)
  assert.equal(done.final_sequence, 2, '回合终态覆盖两段的全部序号')
  assert.equal(done.segments, 2)
  // 下游序号是全回合单调稠密的，屏障因此仍然成立。
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_mode' && l.mode === 'multi_segment'))
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'voice_state_idle'))
  turn.close()
})

test('ESS-969 · 上游不发 voice.state 时保持 ESS-969 之前的行为（auto 能力探测）', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      audioDelta(ws, 0, 'only')
      send(ws, { type: 'audio.done' })
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }),
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

test('ESS-969 · 单段回合在 multi_segment 模式下不产生多余的段落边界', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'only')
      send(ws, { type: 'audio.done' })
      setTimeout(() => send(ws, { type: 'voice.state', state: 'idle', origin: 'model' }), 200)
    }
  })
  const events = []
  const transport = new QwenAgentTransport({ gatewayUrl: url })
  const turn = transport.openTurn({
    requestId: 'r3', sessionId: 's3', deviceId: 'd3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.equal(events.at(-1).segments, 1)
  turn.close()
})

test('ESS-969 · 后台播报的 voice.state idle 不得终结本回合（origin=announcement）', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      setTimeout(() => {
        // 无关后台播报收尾——不是本回合的终态（ESS-36）。
        send(ws, { type: 'voice.state', state: 'idle', origin: 'announcement' })
        setTimeout(() => {
          send(ws, { type: 'response.started', responseId: 'up-2', origin: 'model' })
          audioDelta(ws, 1, 'seg2')
          send(ws, { type: 'audio.done' })
          setTimeout(() => send(ws, { type: 'voice.state', state: 'idle', origin: 'model' }), 200)
        }, 200)
      }, 300)
    }
  })
  const events = []
  const transport = new QwenAgentTransport({ gatewayUrl: url })
  const turn = transport.openTurn({
    requestId: 'r4', sessionId: 's4', deviceId: 'd4', generation: 1, responseId: 'r4:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta', 'agent.audio.segment_done', 'agent.audio.delta', 'agent.audio.done',
  ])
  assert.equal(events.at(-1).final_sequence, 1)
  turn.close()
})

test('ESS-969 · 上游 socket 关闭把挂起的段落收成回合终态，而不是等兜底窗口', async () => {
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
    // 兜底窗口设得远大于用例时长：若它是收口的机制，用例会超时而不是通过。
    gatewayUrl: url, turnIdleBackstopMs: 60_000, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r5', sessionId: 's5', deviceId: 'd5', generation: 1, responseId: 'r5:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.ok(!events.some(e => e.type === 'agent.error'), '完成的回合不得表现为掉线')
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'upstream_closed'))
  turn.close()
})

// ---------------------------------------------------------------------------
// 全栈 —— 上游脚本 → QwenAgentTransport → RealtimeSession → 客户端帧
//
// 这是 ESS-957 现场复现的直接对照物。修复前该用例给出：
//   下发给客户端的全部帧：ready → audio.delta(0) → audio.done
//   post_done_audio_dropped = 3 | 错误码 = ERR_UPSTREAM_AUDIO_AFTER_DONE
// ---------------------------------------------------------------------------

test('ESS-969 · 全栈：工具调用回合的两段音频都到达客户端且顺序正确', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, '我正在查询杭州天气')
      send(ws, { type: 'audio.done' })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'model' })
        audioDelta(ws, 1, '杭州现在')
        audioDelta(ws, 2, '晴，28 度')
        send(ws, { type: 'audio.done' })
        setTimeout(() => send(ws, { type: 'voice.state', state: 'idle', origin: 'model' }), 150)
      }, 400)
    }
  })
  const sent = []; const logs = []
  const scope = { device_id: 'd9', session_id: 's9', request_id: 'r9', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: new QwenAgentTransport({ gatewayUrl: url }),
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start', session_id: 's9', request_id: 'r9', generation: 1, protocol_version: 1,
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.append', session_id: 's9', request_id: 'r9', generation: 1,
    sequence: 0, audio: Buffer.from('uplink!!').toString('base64'),
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.commit', session_id: 's9', request_id: 'r9', generation: 1, sequence: 0,
  }))
  await waitFor(() => sent.some(frame => frame.type === 'audio.done'), 5_000)

  assert.deepEqual(sent.map(f => f.type), [
    'ready', 'audio.delta', 'audio.segment_done', 'audio.delta', 'audio.delta', 'audio.done',
  ])
  assert.deepEqual(sent.filter(f => f.type === 'audio.delta').map(f => f.sequence), [0, 1, 2])
  assert.equal(sent.at(-1).final_sequence, 2)
  assert.equal(session.doneEmitted, true)
  assert.equal(session.postDoneAudioDropped, 0, '第二段一帧都不许被丢')
  assert.equal(session.segmentsEmitted, 1)
  assert.ok(!sent.some(f => f.type === 'error'))
  session.onSocketClose(1000, 'test_done')
})

// B1（毕玄 review on PR #365）：`reorderWaitMs` 的存在本身就说明上游会在
// 帧还在飞的时候发 `audio.done`。终态在洞未补齐时到达是**合法时序**，不是
// 异常——把它一次性消费掉，健康回合就会白等 45 秒兜底，兜底从异常路径变成
// 正常路径。终态是事实不是瞬间：先闩住，洞补齐、settle 完成后立即消费。
test('ESS-969 B1 · idle 在乱序洞未补齐时到达：闩住终态，补洞后立即收口，不走兜底', async () => {
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
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })  // 终态在洞上到达
      // 迟到帧在 reorderWaitMs(300ms) 之内补齐。
      setTimeout(() => audioDelta(ws, 1, 'seq1'), 120)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url,
    // 兜底设成 60s：若它才是收口机制，本用例会在 waitFor 超时处变红，
    // 而不是靠「跑得快」蒙混过关。
    turnIdleBackstopMs: 60_000,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r7', sessionId: 's7', deviceId: 'd7', generation: 1, responseId: 'r7:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  // 尾帧顺序正确：补洞帧先出，终态在最后，且全程只有一个终态。
  assert.deepEqual(events.map(e => e.type), [
    'agent.audio.delta', 'agent.audio.delta', 'agent.audio.delta', 'agent.audio.done',
  ])
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1, '唯一终态')
  assert.equal(events.at(-1).final_sequence, 2, '终态覆盖迟到补齐的尾帧')
  // 终态被闩住而不是被丢弃。
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_latched' && l.reason === 'voice_state_idle'))
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_latch_consumed'))
  assert.ok(!logs.some(l => l.evt === 'upstream_voice_state_idle_ignored'), '终态不得被忽略')
  // 收口来自终态，不是兜底。
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'voice_state_idle'))
  assert.ok(!logs.some(l => l.evt === 'upstream_turn_idle_backstop'), '正常路径不得触发兜底')
  turn.close()
})

test('ESS-969 B1 · 闩住的终态被新段落作废：迟到的 idle 不得把多段回合截短', async () => {
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
      send(ws, { type: 'voice.state', state: 'idle', origin: 'model' })  // 被闩住
      setTimeout(() => {
        // 上游又开了一段——闩住的终态必须作废，回合继续。
        send(ws, { type: 'response.started', responseId: 'up-2', origin: 'model' })
        audioDelta(ws, 1, 'seg1-b')                              // 同时补齐第一段的洞
        audioDelta(ws, 3, 'seg2')
        send(ws, { type: 'audio.done' })
        setTimeout(() => send(ws, { type: 'voice.state', state: 'idle', origin: 'model' }), 200)
      }, 120)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, turnIdleBackstopMs: 60_000, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r8', sessionId: 's8', deviceId: 'd8', generation: 1, responseId: 'r8:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.equal(events.filter(e => e.type === 'agent.audio.done').length, 1, '唯一终态')
  assert.equal(events.at(-1).final_sequence, 3, '第二段的帧不得被闩住的旧终态截掉')
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2, 3])
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal_latch_invalidated'))
  assert.ok(!logs.some(l => l.evt === 'upstream_turn_idle_backstop'))
  turn.close()
})

test('ESS-969 · 兜底窗口（待标定）在上游宣告 voice.state 却始终不 idle 时收口', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      audioDelta(ws, 0, 'seg1')
      send(ws, { type: 'audio.done' })
      // 之后什么都不发：既不开新段，也不 idle，也不关连接。
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, turnIdleBackstopMs: 250, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r6', sessionId: 's6', deviceId: 'd6', generation: 1, responseId: 'r6:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.equal(events.at(-1).final_sequence, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_turn_idle_backstop'))
  assert.ok(logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'idle_backstop'))
  turn.close()
})
