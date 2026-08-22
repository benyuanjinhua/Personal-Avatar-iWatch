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
test('ESS-1068 · 归属明确的播报音频与文本下发，不再命中 announcement_audio_dropped', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement',
        task: { id: 'work_x', sessionId: 's' } })
      audioDelta(ws, 0, 'weather-result', 'ann-1')
      send(ws, { type: 'transcript.final', responseId: 'ann-1', role: 'assistant', content: '杭州今天晴' })
      send(ws, { type: 'audio.done', responseId: 'ann-1' })
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  // 音频与文本都下发，而不是被丢弃。
  assert.deepEqual(spoken(events), ['weather-result'])
  assert.ok(events.some(e => e.type === 'agent.transcript.final' && e.content === '杭州今天晴'))
  // 不再命中隔离丢弃线。
  assert.ok(!logs.some(l => l.evt === 'upstream_announcement_audio_dropped'))
  assert.ok(!logs.some(l => l.evt === 'upstream_announcement_transcript_dropped'))
  // 归属 + 投递留证。
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_delivered' && l.upstream_task_id === 'work_x'))
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_audio_done_delivered'))
  turn.close()
})

test('ESS-1068 · 同一 taskId 的重复播报只消费一次', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      const announce = responseId => {
        send(ws, { type: 'response.started', responseId, origin: 'announcement',
          task: { id: 'work_x', sessionId: 's' } })
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
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  // 第一次投递，第二次命中重复隔离线：音频只有一帧。
  assert.deepEqual(spoken(events), ['result'])
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_delivered'))
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_duplicate' && l.upstream_task_id === 'work_x'))
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
      send(ws, { type: 'task.accepted', task: { id: 'work_z', sessionId: 's', status: 'accepted' } })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'ann-z', origin: 'announcement',
          taskId: 'work_z' })
        audioDelta(ws, 0, 'late-result', 'ann-z')
        send(ws, { type: 'audio.done', responseId: 'ann-z' })
      }, 20)
    }
  })
  const events = []; const logs = []
  const transport = transportFor(url, { logs })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  assert.deepEqual(spoken(events), ['late-result'])
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_delivered' && l.upstream_task_id === 'work_z'))
  turn.close()
})

test('ESS-1068 · 播报结束后清除 turnBusy，直答回合在基础窗口内收口', async () => {
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
      // 一段无归属的后台播报插入：置位 turnBusy，随后结束。
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement',
          taskId: 'work_x' })
        audioDelta(ws, 1, 'bg', 'ann-1')
        send(ws, { type: 'audio.done', responseId: 'ann-1' })
      }, 30)
    }
  })
  const events = []; const logs = []
  // 基础窗 100ms、忙档 500ms：若 turnBusy 未清除，终态 window_ms 会是 500。
  const transport = transportFor(url, { logs, segmentGapMs: 100, segmentGapBusyMs: 500 })
  const turn = openTurn(transport, { events })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  assert.ok(logs.some(l => l.evt === 'upstream_turn_busy' && l.cause === 'announcement_response'))
  assert.ok(logs.some(l => l.evt === 'upstream_turn_busy_cleared'))
  const terminal = logs.find(l => l.evt === 'upstream_turn_terminal')
  assert.ok(terminal, '终态已发生')
  assert.equal(terminal.reason, 'segment_gap')
  // 回落基础窗口，而不是停在忙档 500ms。
  assert.equal(terminal.window_ms, 100)
  turn.close()
})
