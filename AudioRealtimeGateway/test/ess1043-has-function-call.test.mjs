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
import { RealtimeSession } from '../realtime-session.mjs'

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

test('ESS-1096 · task running 抑制 idle 与工具音频终态，task terminal 后才释放', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    send(ws, { type: 'task.running', task: { id: 'task-1', status: 'running', sessionId: 's', deviceId: 'd' } })
    send(ws, { type: 'response.done', responseId: 'model', origin: 'model', hasFunctionCall: true })
    audioDelta(ws, 0, 'answer')
    send(ws, { type: 'response.done', responseId: 'agent', origin: 'agent', hasFunctionCall: false })
    send(ws, { type: 'audio.done' })
    send(ws, { type: 'voice.state', state: 'idle', origin: 'agent' })
    setTimeout(() => send(ws, { type: 'task.completed', task: { id: 'task-1', status: 'completed' } }), 300)
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs, segmentGapMs: 50, segmentGapBusyMs: 80, toolCallWindowMs: 1_000 })
  const turn = openTurn(transport, { requestId: 'r-gated', events })
  turn.commit()
  await new Promise(resolve => setTimeout(resolve, 200))
  assert.equal(events.some(event => event.type === 'agent.audio.done'), false)
  const idle = logs.find(log => log.evt === 'upstream_voice_state_idle')
  assert.equal(idle.suppressed, true)
  assert.equal(idle.suppressed_reason, 'tool_turn_active')
  assert.equal(idle.task_id, 'task-1')
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.equal(logs.find(log => log.evt === 'upstream_turn_terminal').reason, 'task_terminal_audio_done')
  turn.close()
})

test('ESS-1096 · 普通新会话不能 supersede 活跃工具回合，显式 cancel 仍可解除', async () => {
  const sockets = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { sockets.push(ws); send(ws, { type: 'voice.ready' }) }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'task.running', task: { id: 'task-busy', status: 'running' } })
      send(ws, { type: 'response.done', responseId: 'model', origin: 'model', hasFunctionCall: true })
    }
  })
  const events1 = []; const events2 = []; const events3 = []; const logs = []
  const transport = transportFor(url, { logs, segmentGapMs: 50, segmentGapBusyMs: 80, toolCallWindowMs: 1_000 })
  const first = openTurn(transport, { requestId: 'r-first', events: events1 })
  first.commit()
  await waitFor(() => logs.some(log => log.evt === 'upstream_task_state'))
  openTurn(transport, { requestId: 'r-racing', events: events2 }).commit()
  await waitFor(() => events2.some(event => event.code === 'ERR_TURN_BUSY'))
  assert.equal(sockets.length, 1)
  assert.ok(logs.some(log => log.evt === 'upstream_supersede_decision' && log.decision === 'rejected_tool_turn_active'))
  first.cancel()
  const third = openTurn(transport, { requestId: 'r-after-cancel', events: events3 })
  third.commit()
  await waitFor(() => sockets.length === 2)
  third.close()
})

test('ESS-1096 · task failed 也是明确终态，task terminal 丢失则有界超时释放', async () => {
  let connection = 0
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { connection += 1; send(ws, { type: 'voice.ready' }) }
    if (message.type !== 'audio.commit') return
    const id = `task-${connection}`
    send(ws, { type: 'task.running', task: { id, status: 'running' } })
    send(ws, { type: 'response.done', responseId: 'model', origin: 'model', hasFunctionCall: true })
    audioDelta(ws, 0, 'answer')
    send(ws, { type: 'response.done', responseId: 'agent', origin: 'agent', hasFunctionCall: false })
    send(ws, { type: 'audio.done' })
    if (connection === 1) setTimeout(() => send(ws, { type: 'task.failed', task: { id, status: 'failed' } }), 100)
  })
  const logs = []; const failedEvents = []
  const transport = transportFor(url, { logs, segmentGapMs: 20, segmentGapBusyMs: 20, toolCallWindowMs: 180 })
  const failed = openTurn(transport, { requestId: 'r-failed', events: failedEvents }); failed.commit()
  await waitFor(() => failedEvents.some(event => event.type === 'agent.audio.done'))
  assert.ok(logs.some(log => log.evt === 'upstream_task_state' && log.status === 'failed'))
  failed.close()
  const timeoutEvents = []
  const timed = openTurn(transport, { requestId: 'r-timeout', events: timeoutEvents }); timed.commit()
  await waitFor(() => logs.some(log => log.evt === 'upstream_task_terminal_timeout'))
  await waitFor(() => timeoutEvents.some(event => event.type === 'agent.audio.done'))
  assert.ok(logs.some(log => log.evt === 'upstream_turn_terminal' && log.reason === 'tool_task_timeout'))
  timed.close()
})

test('ESS-1096 · defer 后工具音频使旧终态失效，task terminal 后用当前 audio.done 收口', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type !== 'audio.commit') return
    send(ws, { type: 'task.running', task: { id: 'task-race', status: 'running' } })
    send(ws, { type: 'response.started', responseId: 'prompt', origin: 'model' })
    audioDelta(ws, 0, 'prompt')
    send(ws, { type: 'audio.done' })
    setTimeout(() => {
      send(ws, { type: 'response.started', responseId: 'answer', origin: 'agent' })
      audioDelta(ws, 1, 'answer-a')
      audioDelta(ws, 2, 'answer-b')
      send(ws, { type: 'task.completed', task: { id: 'task-race', status: 'completed' } })
      send(ws, { type: 'audio.done' })
    }, 140)
  })
  const sent = []; const logs = []
  const scope = { device_id: 'd-race', session_id: 's-race', request_id: 'r-race', generation: 1 }
  const session = new RealtimeSession({
    scope,
    send: text => sent.push(JSON.parse(text)),
    close: () => {},
    agentTransport: new QwenAgentTransport({
      gatewayUrl: url, doneSettleMs: 10, segmentGapMs: 40, segmentGapBusyMs: 60,
      toolCallWindowMs: 500, log: (evt, extra) => logs.push({ evt, ...extra }),
    }),
    log: (evt, extra) => logs.push({ evt, ...extra }),
    heartbeatIntervalMs: 0, idleDisconnectMs: 0, commitDeadlineMs: 0,
  })
  session.onFrame(JSON.stringify({
    type: 'session.start', session_id: scope.session_id, request_id: scope.request_id,
    generation: 1, protocol_version: 1,
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.append', session_id: scope.session_id, request_id: scope.request_id,
    generation: 1, sequence: 0, audio: Buffer.from('uplink').toString('base64'),
  }))
  session.onFrame(JSON.stringify({
    type: 'audio.commit', session_id: scope.session_id, request_id: scope.request_id,
    generation: 1, sequence: 0,
  }))
  await waitFor(() => sent.some(frame => frame.type === 'audio.done'))

  assert.deepEqual(sent.filter(frame => frame.type === 'audio.delta').map(frame => frame.sequence), [0, 1, 2])
  assert.equal(sent.find(frame => frame.type === 'audio.done').final_sequence, 2)
  assert.equal(session.postDoneAudioDropped, 0)
  assert.ok(logs.some(log => log.evt === 'upstream_turn_terminal_deferred' && log.final_sequence === 0))
  assert.ok(logs.some(log => log.evt === 'upstream_turn_terminal_invalidated'
    && log.stale_final_sequence === 0))
  session.onSocketClose(1000, 'test_done')
})

test('ESS-1096 · defer 后新输出缺少 audio.done 时显式超时失败', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    send(ws, { type: 'task.running', task: { id: 'task-no-done', status: 'running' } })
    audioDelta(ws, 0, 'prompt')
    send(ws, { type: 'audio.done' })
    setTimeout(() => {
      send(ws, { type: 'response.started', responseId: 'answer', origin: 'agent' })
      audioDelta(ws, 1, 'unterminated-answer')
      send(ws, { type: 'task.completed', task: { id: 'task-no-done', status: 'completed' } })
    }, 200)
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 20, segmentGapBusyMs: 40, toolCallWindowMs: 180,
  })
  const turn = openTurn(transport, { requestId: 'r-no-final-done', events })
  turn.commit()
  await waitFor(() => events.some(event => event.code === 'ERR_UPSTREAM_TOOL_AUDIO_TIMEOUT'))
  assert.ok(logs.some(log => log.evt === 'upstream_tool_audio_terminal_timeout'))
  assert.equal(events.some(event => event.type === 'agent.audio.done'), false)
  turn.close()
})

test('ESS-1096 · 工具音频持续流动时续期静默窗口，不按总时长中断', async () => {
  const frameCount = 12
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type !== 'audio.commit') return
    send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    send(ws, { type: 'task.running', task: { id: 'task-streaming', status: 'running' } })
    audioDelta(ws, 0, 'prompt')
    send(ws, { type: 'audio.done' })
    setTimeout(() => {
      send(ws, { type: 'response.started', responseId: 'answer', origin: 'agent' })
      let sequence = 1
      const timer = setInterval(() => {
        audioDelta(ws, sequence, `answer-${sequence}`)
        sequence += 1
        if (sequence > frameCount) {
          clearInterval(timer)
          send(ws, { type: 'task.completed', task: { id: 'task-streaming', status: 'completed' } })
          send(ws, { type: 'audio.done' })
        }
      }, 30)
    }, 180)
  })
  const events = []; const logs = []
  const transport = transportFor(url, {
    logs, segmentGapMs: 10, segmentGapBusyMs: 20, toolCallWindowMs: 180,
  })
  const turn = openTurn(transport, { requestId: 'r-streaming-answer', events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done')
    || logs.some(log => log.evt === 'upstream_tool_audio_terminal_timeout'))
  assert.equal(events.filter(event => event.type === 'agent.audio.delta').length, frameCount + 1)
  assert.equal(events.find(event => event.type === 'agent.audio.done').final_sequence, frameCount)
  assert.equal(events.some(event => event.code === 'ERR_UPSTREAM_TOOL_AUDIO_TIMEOUT'), false)
  assert.ok(logs.filter(log => log.evt === 'upstream_tool_audio_terminal_window_armed').length > 2)
  turn.close()
})
