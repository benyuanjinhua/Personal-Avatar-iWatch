// ESS-1043 — Gateway reads qwen `response.done` `hasFunctionCall` to keep a
// tool-call turn open until the tool result segment arrives.
//
// 事故：qwen 三段响应（announcement → model function call → agent result），
// 第一段（announcement）`audio.done` 之后，Gateway 的 segment-gap 窗口在工具
// 执行的 8–16 s 里超时判 turn terminal，真正答案的音频被 `post_done` 丢弃。
//
// 修复：`response.done` 携带 `hasFunctionCall`。为 true 时，模型已决定调用
// 工具，后面还有一段（工具结果）—— 不得用普通空闲窗口收口，改用专用
// `toolCallWindowMs` 窗口；为 false 且之前有 pending tool call 时，这一段就是
// 回合的最终段，audio settle 后立即收口（`upstream_turn_terminal
// reason=tool_result_done`），而不是等空闲窗口。

import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

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

function transportFor(url, { logs, segmentGapMs, segmentGapBusyMs, toolCallWindowMs }) {
  return new QwenAgentTransport({
    gatewayUrl: url,
    segmentGapMs,
    segmentGapBusyMs,
    toolCallWindowMs,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
}

function openTurn(transport, { requestId, events }) {
  return transport.openTurn({
    requestId, sessionId: 's', deviceId: 'd', generation: 1, responseId: `${requestId}:gen1`,
    onEvent: event => events.push(event),
  })
}

// 三段工具调用回合：announcement（有音频）→ model function call（无音频，
// hasFunctionCall=true）→ agent 工具结果（有音频，hasFunctionCall=false）。
// 工具延迟 500 ms 远大于基础档（100 ms）/ 忙档（200 ms）——没有 tool-call 窗口
// 这条用例必红。
function scriptToolCallTurn({ toolDelayMs = 500, nestedShape = false } = {}) {
  return (ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      // 段 0：announcement「我正在查询」
      send(ws, { type: 'response.started', responseId: 'up-ann', origin: 'announcement' })
      audioDelta(ws, 0, 'announcement')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'response.done', responseId: 'up-ann', origin: 'announcement', hasFunctionCall: false, status: 'completed' })
      // 段 1：model 决定调用工具（无音频）
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-model', origin: 'model' })
        send(ws, { type: 'audio.done' })
        const done = nestedShape
          ? { type: 'response.done', response: { id: 'up-model', hasFunctionCall: true } }
          : { type: 'response.done', responseId: 'up-model', origin: 'model', hasFunctionCall: true, status: 'completed' }
        send(ws, done)
      }, 200)
      // 段 2：agent 工具结果（真正的答案），在工具执行之后到达
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-agent', origin: 'agent' })
        audioDelta(ws, 1, 'real-answer-a')
        audioDelta(ws, 2, 'real-answer-b')
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'response.done', responseId: 'up-agent', origin: 'agent', hasFunctionCall: false, status: 'completed' })
      }, 200 + toolDelayMs)
    }
  }
}

test('ESS-1043 · hasFunctionCall=true 时回合跨过工具延迟保持打开，只在最终段收口', async () => {
  const url = await upstream(scriptToolCallTurn())
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 200, toolCallWindowMs: 2_000,
  })
  const turn = openTurn(transport, { requestId: 'r1', events })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  // 两段音频（announcement + 真正答案）都到，序号连续 0..2。
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  // 段落边界：announcement 之后、空函数调用段之后各一次。
  assert.deepEqual(
    events.filter(e => e.type === 'agent.audio.segment_done').map(e => e.segment_index),
    [0, 1],
  )
  // 终态只有一次，且在最终段（agent 工具结果 done）触发。
  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1, '唯一终态')
  assert.equal(terminals[0].reason, 'tool_result_done')
  assert.equal(terminals[0].final_sequence, 2)
  assert.equal(terminals[0].segments, 3)
  // 终态不是 segment_gap（那正是 ESS-1043 的事故形态）。
  assert.ok(!logs.some(l => l.evt === 'upstream_turn_terminal' && l.reason === 'segment_gap'))
  assert.ok(logs.some(l => l.evt === 'upstream_tool_call_pending'))
  assert.ok(logs.some(l => l.evt === 'upstream_tool_call_resolved'))
  const done = events.find(e => e.type === 'agent.audio.done')
  assert.equal(done.final_sequence, 2)
  assert.equal(done.segments, 3)
  turn.close()
})

test('ESS-1043 · 嵌套 response.hasFunctionCall 形状同样被识别', async () => {
  const url = await upstream(scriptToolCallTurn({ nestedShape: true }))
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 200, toolCallWindowMs: 2_000,
  })
  const turn = openTurn(transport, { requestId: 'r2', events })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1)
  assert.equal(terminals[0].reason, 'tool_result_done')
  turn.close()
})

test('ESS-1043 · 上游不发 response.done 时保持 ESS-990 之前的行为（segment_gap 收口）', async () => {
  // 没有 response.done 的回合：不进入 tool-call 路径，普通空闲窗口收口。
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-1', origin: 'model' })
      audioDelta(ws, 0, 'only')
      send(ws, { type: 'audio.done' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 200, toolCallWindowMs: 2_000,
  })
  const turn = openTurn(transport, { requestId: 'r3', events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(events.map(e => e.type), ['agent.audio.delta', 'agent.audio.done'])
  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1)
  assert.equal(terminals[0].reason, 'segment_gap')
  assert.ok(!logs.some(l => l.evt === 'upstream_tool_call_pending'))
  turn.close()
})

test('ESS-1043 · 工具调用声明后若结果永不回来，tool-call 窗口仍兜底收口（有界）', async () => {
  // hasFunctionCall=true 之后什么都不发：回合只能靠 tool-call 窗口收口，
  // 不能永远挂着。toolCallWindowMs=600 在用例时长内。
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
        send(ws, { type: 'response.done', responseId: 'up-1', origin: 'model', hasFunctionCall: true, status: 'completed' })
      }, 150)
      // 之后工具结果永不回来。
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 100, toolCallWindowMs: 600,
  })
  const turn = openTurn(transport, { requestId: 'r4', events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1)
  // 有界收口：tool-call 窗口到期按 segment_gap 收口，而不是永远挂起。
  assert.equal(terminals[0].reason, 'segment_gap')
  assert.equal(terminals[0].window_ms, 600)
  assert.ok(logs.some(l => l.evt === 'upstream_tool_call_pending'))
  turn.close()
})

// 阻断 2 回归：pending tool call 期间，无关的 response.done 不得提前清除 pending。
// 只有 origin=agent 且显式 hasFunctionCall=false 的工具结果段才收口，且终态唯一。
test('ESS-1043 · pending 期间夹入 announcement/缺字段/model 的 response.done 不提前收口', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      // 段 0：announcement「我正在查询」
      send(ws, { type: 'response.started', responseId: 'up-ann', origin: 'announcement' })
      audioDelta(ws, 0, 'announcement')
      send(ws, { type: 'audio.done' })
      send(ws, { type: 'response.done', responseId: 'up-ann', origin: 'announcement', hasFunctionCall: false, status: 'completed' })
      // 段 1：model 决定调用工具 → pending
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-model', origin: 'model' })
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'response.done', responseId: 'up-model', origin: 'model', hasFunctionCall: true, status: 'completed' })
        // 工具执行期间夹入三类无关 done：
        setTimeout(() => {
          send(ws, { type: 'response.done', responseId: 'up-ann2', origin: 'announcement', hasFunctionCall: false, status: 'completed' })
          send(ws, { type: 'response.done', responseId: 'up-unknown', origin: 'model', status: 'completed' })
          send(ws, { type: 'response.done', responseId: 'up-model2', origin: 'model', hasFunctionCall: false, status: 'completed' })
        }, 100)
      }, 200)
      // 段 2：agent 工具结果 → 收口
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-agent', origin: 'agent' })
        audioDelta(ws, 1, 'real-answer-a')
        audioDelta(ws, 2, 'real-answer-b')
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'response.done', responseId: 'up-agent', origin: 'agent', hasFunctionCall: false, status: 'completed' })
      }, 700)
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 200, toolCallWindowMs: 2_000,
  })
  const turn = openTurn(transport, { requestId: 'r5', events })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  // 两段答案音频都到，序号连续。
  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1, 2])
  // 终态唯一，且只由 agent 工具结果触发。
  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1, '唯一终态')
  assert.equal(terminals[0].reason, 'tool_result_done')
  assert.equal(terminals[0].final_sequence, 2)
  // 三类无关 done 都被识别并留证，没有清除 pending。
  const ignored = logs.filter(l => l.evt === 'upstream_response_done_ignored')
  assert.ok(ignored.some(l => l.reason === 'announcement'), 'announcement done 被忽略')
  assert.ok(ignored.some(l => l.reason === 'missing_has_function_call'), '缺字段 done 被忽略')
  assert.ok(ignored.some(l => l.reason === 'origin_model'), 'model 非工具结果 done 被忽略')
  turn.close()
})

// 阻断 2 回归：登记在 announcementResponseIds 的 response.done（本身不带 origin）
// 也不得清除 pending——归属靠 responseId → announcementResponseIds 映射。
test('ESS-1043 · 登记在 announcementResponseIds 的 response.done（无 origin）不清除 pending', async () => {
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
        // 模型决定调用工具 → pending
        send(ws, { type: 'response.started', responseId: 'up-model', origin: 'model' })
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'response.done', responseId: 'up-model', origin: 'model', hasFunctionCall: true, status: 'completed' })
        // 工具执行期间夹入一条已登记播报：response.started 登记了 responseId，
        // 其 response.done 不带 origin，只能靠 responseId 映射识别为 announcement。
        setTimeout(() => {
          send(ws, { type: 'response.started', responseId: 'up-ann-live', origin: 'announcement' })
          send(ws, { type: 'response.done', responseId: 'up-ann-live', hasFunctionCall: false, status: 'completed' })
        }, 100)
      }, 200)
      // agent 工具结果 → 收口
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-agent', origin: 'agent' })
        audioDelta(ws, 1, 'real-answer')
        send(ws, { type: 'audio.done' })
        send(ws, { type: 'response.done', responseId: 'up-agent', origin: 'agent', hasFunctionCall: false, status: 'completed' })
      }, 700)
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 200, toolCallWindowMs: 2_000,
  })
  const turn = openTurn(transport, { requestId: 'r6', events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1])
  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1, '唯一终态')
  assert.equal(terminals[0].reason, 'tool_result_done')
  const ignored = logs.filter(l => l.evt === 'upstream_response_done_ignored')
  assert.ok(ignored.some(l => l.reason === 'announcement' && l.upstream_response_id === 'up-ann-live'),
    '已登记播报的 done 靠 responseId 映射被忽略')
  turn.close()
})
