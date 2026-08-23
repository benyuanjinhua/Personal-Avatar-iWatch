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

// 三段工具调用回合：当前 turn 的即时提示（有音频）→ model function call（无音频，
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
      // 段 0：当前 turn 的 action promise「我正在查询」。它归属 model/本轮，
      // 与 origin=announcement 的过期后台播报不同，后者由 ESS-849 隔离。
      send(ws, { type: 'response.started', responseId: 'up-prompt', origin: 'model' })
      audioDelta(ws, 0, 'current-turn-prompt')
      send(ws, { type: 'response.done', responseId: 'up-prompt', origin: 'model', hasFunctionCall: false, status: 'completed' })
      send(ws, { type: 'audio.done' })
      // 段 1：model 决定调用工具（无音频）
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-model', origin: 'model' })
        const done = nestedShape
          ? { type: 'response.done', response: { id: 'up-model', hasFunctionCall: true } }
          : { type: 'response.done', responseId: 'up-model', origin: 'model', hasFunctionCall: true, status: 'completed' }
        send(ws, done)
        send(ws, { type: 'audio.done' })
      }, 200)
      // 段 2：agent 工具结果（真正的答案），在工具执行之后到达
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-agent', origin: 'agent' })
        audioDelta(ws, 1, 'real-answer-a')
        audioDelta(ws, 2, 'real-answer-b')
        send(ws, { type: 'response.done', responseId: 'up-agent', origin: 'agent', hasFunctionCall: false, status: 'completed' })
        send(ws, { type: 'audio.done' })
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

  // 两段音频（当前 turn 即时提示 + 真正答案）都到，序号连续 0..2。
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

test('ESS-1052 · pending 期间夹入 announcement/缺字段 done 不得冒充工具结果', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'up-model', origin: 'model' })
      audioDelta(ws, 0, 'prompt')
      send(ws, { type: 'response.done', responseId: 'up-model', origin: 'model',
        hasFunctionCall: true, status: 'completed' })
      send(ws, { type: 'audio.done' })

      // 同一 WSS 的无关完成事件：显式 false 的后台播报，以及缺字段的未知响应。
      send(ws, { type: 'response.done', responseId: 'up-ann', origin: 'announcement',
        hasFunctionCall: false, status: 'completed' })
      send(ws, { type: 'response.done', responseId: 'up-unknown', origin: 'agent',
        status: 'completed' })

      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'up-agent', origin: 'agent' })
        audioDelta(ws, 1, 'real-answer')
        send(ws, { type: 'response.done', responseId: 'up-agent', origin: 'agent',
          hasFunctionCall: false, status: 'completed' })
        send(ws, { type: 'audio.done' })
      }, 250)
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 100, segmentGapBusyMs: 100, toolCallWindowMs: 2_000,
  })
  const turn = openTurn(transport, { requestId: 'r-interleaved', events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(events.filter(e => e.type === 'agent.audio.delta').map(e => e.sequence), [0, 1])
  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 1)
  assert.equal(terminals[0].reason, 'tool_result_done')
  assert.equal(logs.filter(l => l.evt === 'upstream_tool_call_resolution_ignored').length, 1)
  assert.equal(logs.filter(l => l.evt === 'upstream_announcement_response_done_dropped').length, 1)
  assert.equal(logs.filter(l => l.evt === 'upstream_tool_call_resolved').length, 1)
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

test('ESS-1096 · 工具调用声明后若结果永不回来，tool-call 窗口显式失败（有界）', async () => {
  // hasFunctionCall=true 之后什么都不发：回合只能靠 tool-call 窗口失败退出，
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
  await waitFor(() => events.some(event => event.code === 'ERR_TOOL_TASK_TIMEOUT'), 4_000)

  const terminals = logs.filter(l => l.evt === 'upstream_turn_terminal')
  assert.equal(terminals.length, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_tool_turn_timeout'))
  assert.ok(logs.some(l => l.evt === 'upstream_tool_call_pending'))
  turn.close()
})
