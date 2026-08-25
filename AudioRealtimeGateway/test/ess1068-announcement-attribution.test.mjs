// ESS-1068 —— 归属明确的后台任务播报必须到达本用户，且播报结束后清除
// turnBusy，让后续直答回合回落到基础空闲窗口；无归属播报继续隔离。
//
// 事故：Gateway 把所有 origin=announcement 一律当跨会话串台丢弃（ESS-849），
// 于是归属明确的后台任务最终结果（天气答案）也永久命中
// `upstream_announcement_audio_dropped`；且 `turnBusy` 一旦被播报置位就再也
// 不清除，直答回合被锁在 12 s 忙档、`agent.audio.done` 迟迟不发。

import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { WebSocketServer } from 'ws'

import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

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
const audioDelta = (ws, sequence, text, responseId) => send(ws, {
  type: 'audio.delta', sequence, responseId,
  audio: Buffer.from(text).toString('base64'), sampleRate: 24_000,
})
const spoken = events => events
  .filter(event => event.type === 'agent.audio.delta')
  .map(event => Buffer.from(event.audio, 'base64').toString())

function transportFor(url, { logs, segmentGapMs = 100, segmentGapBusyMs = 500 }) {
  return new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs, segmentGapBusyMs, doneSettleMs: 20,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
}

function openTurn(transport, { requestId = 'r', sessionId = 's', events }) {
  return transport.openTurn({
    requestId, sessionId, deviceId: 'd', generation: 1, responseId: `${requestId}:gen1`,
    onEvent: event => events.push(event),
  })
}

// 归属明确的播报：response.started 的 task.sessionId 与当前 turn 一致。
test('ESS-1107 · 归属明确的后台播报也不进入前台响应流', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement',
        task: { id: 'work_x', sessionId: 's', deviceId: 'd' } })
      audioDelta(ws, 0, 'weather-result', 'ann-1')
      send(ws, { type: 'transcript.final', responseId: 'ann-1', role: 'assistant', content: '杭州今天晴' })
      send(ws, { type: 'audio.done', responseId: 'ann-1' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_audio_done_dropped'))

  assert.deepEqual(spoken(events), [])
  assert.ok(!events.some(e => e.type === 'agent.transcript.final'))
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_correlated' && l.upstream_task_id === 'work_x'))
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_transcript_dropped'))
  turn.close()
})

test('ESS-1107 · 同一 taskId 的重放始终隔离在前台响应流外', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      const announce = responseId => {
        send(ws, { type: 'response.started', responseId, origin: 'announcement',
          task: { id: 'work_x', sessionId: 's', deviceId: 'd' } })
        audioDelta(ws, 0, 'result', responseId)
        send(ws, { type: 'audio.done', responseId })
      }
      announce('ann-1')
      announce('ann-2')
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.filter(l => l.evt === 'upstream_announcement_audio_done_dropped').length === 2)
  assert.deepEqual(spoken(events), [])
  assert.equal(logs.filter(l => l.evt === 'upstream_announcement_correlated').length, 2)
  turn.close()
})

test('ESS-1068 · 无归属或其他用户的播报仍被隔离', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      // 本回合真正的回答先到。
      send(ws, { type: 'response.started', responseId: 'ans-1', origin: 'agent' })
      audioDelta(ws, 0, 'answer', 'ans-1')
      send(ws, { type: 'audio.done', responseId: 'ans-1' })
      // 其他 session 的播报（sessionId=other）不得串台到本 turn（sessionId=s）。
      send(ws, { type: 'response.started', responseId: 'ann-other', origin: 'announcement',
        task: { id: 'work_y', sessionId: 'other' } })
      audioDelta(ws, 1, 'foreign-result', 'ann-other')
      send(ws, { type: 'audio.done', responseId: 'ann-other' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  // 只有本回合的回答，外来的播报一帧都没下发。
  assert.deepEqual(spoken(events), ['answer'])
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_isolated' && l.reason === 'unattributed'))
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_audio_dropped'))
  turn.close()
})

test('ESS-1068 · task.* 事件建立的 taskId→session 映射用于归属', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      // 先到 task.accepted（带 sessionId），再迟到的播报只带 taskId。
      send(ws, { type: 'task.accepted', task: { id: 'work_z', sessionId: 's', deviceId: 'd', status: 'accepted' } })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'ann-z', origin: 'announcement',
          taskId: 'work_z' })
        audioDelta(ws, 0, 'late-result', 'ann-z')
        send(ws, { type: 'audio.done', responseId: 'ann-z' })
        send(ws, { type: 'task.completed', task: { id: 'work_z', status: 'completed' } })
      }, 20)
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_audio_done_dropped'))

  assert.deepEqual(spoken(events), [])
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_correlated' && l.upstream_task_id === 'work_z'))
  turn.close()
})

test('ESS-1107 · 播报从不设置 turnBusy，直答回合在基础窗口内收口', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      // 本回合的回答段先收口（park）。
      send(ws, { type: 'response.started', responseId: 'ans-1', origin: 'model' })
      audioDelta(ws, 0, 'prompt', 'ans-1')
      send(ws, { type: 'audio.done', responseId: 'ans-1' })
      // 一段归属当前会话的后台播报插入：不得触碰 turnBusy。
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement',
          task: { id: 'work_x', sessionId: 's', deviceId: 'd' } })
        audioDelta(ws, 1, 'bg', 'ann-1')
        send(ws, { type: 'audio.done', responseId: 'ann-1' })
      }, 30)
    }
  })
  const events = []; const logs = []
  // 基础窗 100ms、忙档 500ms：播报不得把终态窗口改成 500。
  const transport = transportFor(url, { logs, segmentGapMs: 100, segmentGapBusyMs: 500 })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  assert.equal(logs.some(l => l.evt === 'upstream_turn_busy'
    && l.cause === 'announcement_response'), false)
  const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
  assert.ok(terminal, '终态已发生')
  assert.equal(terminal.reason, 'segment_gap')
  // 回落基础窗口，而不是停在忙档 500ms。
  assert.equal(terminal.window_ms, 100)
  assert.deepEqual(spoken(events), ['prompt'])
  assert.equal(events.some(event => event.type === 'agent.audio.segment_done'), false,
    'announcement must not release the parked foreground segment')
  turn.close()
})

test('ESS-1107 · 新会话的无归属历史播报被确认并抢占，不占 busy，随后用户输入正常回答', async () => {
  const wire = []
  const url = await upstream((ws, message) => {
    wire.push(message)
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'stale-ann', origin: 'announcement',
          taskIds: ['old-work-1', 'old-work-2'] })
        audioDelta(ws, 0, 'stale-result', 'stale-ann')
      }, 10)
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'answer', origin: 'model' })
      audioDelta(ws, 1, 'fresh-answer', 'answer')
      send(ws, { type: 'audio.done', responseId: 'answer' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_preempted'))
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  assert.deepEqual(spoken(events), ['fresh-answer'])
  assert.ok(!logs.some(l => l.evt === 'upstream_turn_busy' && l.cause === 'announcement_response'))
  const types = wire.map(message => message.type)
  assert.ok(types.indexOf('playback.started') < types.indexOf('interrupt'))
  assert.ok(types.indexOf('interrupt') < types.indexOf('audio.commit'))
  assert.equal(types.filter(type => type === 'interrupt').length, 1)
  turn.close()
})

test('ESS-1107 · commit 前的响应帧不能满足本次输入的应答死线', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'response.started', responseId: 'precommit', origin: 'model' })
      send(ws, { type: 'transcript.final', responseId: 'precommit', role: 'assistant', content: '旧响应' })
    }
    // audio.commit intentionally produces no response.
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 120,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = openTurn(transport, { events })
  await waitFor(() => logs.some(l => l.evt === 'upstream_precommit_response_ignored'))
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))

  assert.equal(events.at(-1).code, 'ERR_UPSTREAM_NO_RESPONSE')
  assert.ok(logs.some(l => l.evt === 'upstream_response_timeout'))
})

test('ESS-1068 · task 身份跨 turn 持久化：后一轮能归属前一轮任务的结果', async () => {
  const commits = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      commits.push(ws)
      if (commits.length === 1) {
        // 第一轮：只建立 taskId→session 映射（task.accepted），回合随后关闭。
        send(ws, { type: 'task.accepted', task: { id: 'work_w', sessionId: 's', deviceId: 'd', status: 'accepted' } })
        send(ws, { type: 'task.completed', task: { id: 'work_w', status: 'completed' } })
      } else {
        // 第二轮：迟到的播报只带 taskId，靠上一轮建立的映射归属。
        send(ws, { type: 'response.started', responseId: 'ann-w', origin: 'announcement',
          taskId: 'work_w' })
        audioDelta(ws, 0, 'cross-turn-result', 'ann-w')
        send(ws, { type: 'audio.done', responseId: 'ann-w' })
      }
    }
  })
  const logs = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, doneSettleMs: 20, log: (evt, extra) => logs.push({ evt, ...extra }) })
  const events1 = []; const events2 = []
  const turn1 = transport.openTurn({
    requestId: 'r1', sessionId: 's', deviceId: 'd', generation: 1, responseId: 'r1:gen1',
    onEvent: e => events1.push(e),
  })
  turn1.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_task_state' && l.task_id === 'work_w'))

  const turn2 = transport.openTurn({
    requestId: 'r2', sessionId: 's', deviceId: 'd', generation: 2, responseId: 'r2:gen2',
    onEvent: e => events2.push(e),
  })
  turn2.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_audio_done_dropped'))

  assert.equal(events2.filter(e => e.type === 'agent.audio.delta').length, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_correlated' && l.upstream_task_id === 'work_w'))
  turn2.close()
})

test('ESS-1107 · 跨 turn 重放不进入任一前台响应流', async () => {
  const commits = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      commits.push(ws)
      // 两轮都收到同一 taskId 的播报（重投）：第一轮投递，第二轮去重隔离。
      send(ws, { type: 'response.started', responseId: `ann-${commits.length}`, origin: 'announcement',
        task: { id: 'work_d', sessionId: 's', deviceId: 'd' } })
      audioDelta(ws, 0, 'dup-result', `ann-${commits.length}`)
      send(ws, { type: 'audio.done', responseId: `ann-${commits.length}` })
    }
  })
  const logs = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, doneSettleMs: 20, log: (evt, extra) => logs.push({ evt, ...extra }) })
  const events1 = []; const events2 = []
  const turn1 = transport.openTurn({
    requestId: 'r1', sessionId: 's', deviceId: 'd', generation: 1, responseId: 'r1:gen1',
    onEvent: e => events1.push(e),
  })
  turn1.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_audio_done_dropped'))

  const turn2 = transport.openTurn({
    requestId: 'r2', sessionId: 's', deviceId: 'd', generation: 2, responseId: 'r2:gen2',
    onEvent: e => events2.push(e),
  })
  turn2.commit()
  await waitFor(() => logs.filter(l => l.evt === 'upstream_announcement_audio_done_dropped').length === 2)

  assert.equal(events1.filter(e => e.type === 'agent.audio.delta').length, 0)
  assert.equal(events2.filter(e => e.type === 'agent.audio.delta').length, 0)
  assert.equal(logs.filter(l => l.evt === 'upstream_announcement_correlated').length, 2)
  turn2.close()
})

// ESS-1068 复审第2点：跨设备 fail-closed。同一 sessionId 但不同 deviceId 的
// 播报必须被隔离——两个设备共享 sessionId 时不能双双接受同一广播。
test('ESS-1068 · 复审：same-session/different-device 的播报被隔离', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-x', origin: 'announcement',
        task: { id: 'work_cross', sessionId: 's', deviceId: 'other-device' } })
      audioDelta(ws, 0, 'cross-device', 'ann-x')
      send(ws, { type: 'audio.done', responseId: 'ann-x' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_isolated'))

  // deviceId 不匹配 → 隔离，不下发音频。
  assert.equal(events.filter(e => e.type === 'agent.audio.delta').length, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_isolated'))
  turn.close()
})

// ESS-1068 复审第2点：turn 有 deviceId 时，缺 deviceId 的播报不得靠 sessionId
// 单边放行（fail-closed）。
test('ESS-1068 · 复审：有 sessionId 但缺 deviceId 的播报被隔离', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-y', origin: 'announcement',
        task: { id: 'work_nodevice', sessionId: 's' } })
      audioDelta(ws, 0, 'no-device', 'ann-y')
      send(ws, { type: 'audio.done', responseId: 'ann-y' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_isolated'))

  assert.equal(events.filter(e => e.type === 'agent.audio.delta').length, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_isolated'))
  turn.close()
})

// response.done without audio.done 的播报必须清理自身状态，但不得创建或
// 清除前台回合的 busy 状态。
test('ESS-1107 · response.done without audio.done 不触碰 busy', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-nodone', origin: 'announcement',
        task: { id: 'work_nodone', sessionId: 's', deviceId: 'd' } })
      // 只发 response.done，不发 audio.done。
      send(ws, { type: 'response.done', responseId: 'ann-nodone', origin: 'announcement' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_response_done_dropped'))
  assert.equal(logs.some(l => l.evt === 'upstream_turn_busy'
    && l.cause === 'announcement_response'), false)
  assert.equal(logs.some(l => l.evt === 'upstream_turn_busy_cleared'), false)
  turn.close()
})

// ESS-1068 复审第4点：断连（socket close）后 pending 播报不残留，busy 清理。
test('ESS-1068 · 复审：socket close 清理 activeAnnouncements 与 pending', async () => {
  let serverWs
  const url = await upstream((ws, message) => {
    serverWs = ws
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-close', origin: 'announcement',
        task: { id: 'work_close', sessionId: 's', deviceId: 'd' } })
      // 不发 audio.done，直接关闭 socket。
      ws.close()
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_error'))
  // 断连后 turn 终结，pending 播报不得残留为 consumed（dedup 未提前写）。
  assert.ok(!logs.some(l => l.evt === 'upstream_announcement_audio_done_delivered'))
  turn.close()
})
