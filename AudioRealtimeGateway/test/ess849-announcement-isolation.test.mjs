// ESS-849 —— 上游 `origin="announcement"` 的播报不得冒充本回合的回答。
//
// 事故（2026-08-22 真机 13:59–14:00，L1）：
//   13:59:57.011 downlink_audio_done_accepted final_seq=51 gen=1  ← 播报的 done 闩死下行
//   14:00:02.405 response.done origin="agent" hasAudio=true       ← 服务端确实生成了答案
//   14:00:04.115 downlink_segment_dropped seq=52..55 reason=post_done ← 答案被整段丢弃
// 用户侧：界面停在「思考中」直到 15 s 预算耗尽。同一机理还会串台——深圳那一轮
// 的下行里播出「刚才查询的是杭州今天的天气情况，不是深圳的」。
//
// 归属只能在本层判定：实测 `audio.delta` / `audio.done` 94/94 条 `origin=null`，
// 只有 `response.started` 带 origin，客户端拿不到这张 responseId → origin 表。

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
const audioDelta = (ws, sequence, text, responseId) => send(ws, {
  type: 'audio.delta', sequence, responseId,
  audio: Buffer.from(text).toString('base64'), sampleRate: 24_000,
})
const spoken = events => events
  .filter(event => event.type === 'agent.audio.delta')
  .map(event => Buffer.from(event.audio, 'base64').toString())

test('ESS-849 · 播报音频不进入本回合的下行，本回合的答案完整送达', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      // 播报抢在答案前面出音频（实测早 8.6 s）。它有自己的 sequence 轴。
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement' })
      audioDelta(ws, 0, '杭州天气查询失败了', 'ann-1')
      audioDelta(ws, 1, '这是后台任务的播报', 'ann-1')
      send(ws, { type: 'audio.done', responseId: 'ann-1' })
      // 本回合真正的答案。
      send(ws, { type: 'response.started', responseId: 'ans-1', origin: 'agent' })
      audioDelta(ws, 0, 'answer-a', 'ans-1')
      audioDelta(ws, 1, 'answer-b', 'ans-1')
      send(ws, { type: 'audio.done', responseId: 'ans-1' })
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
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  // 手表只听到答案：播报的两帧一帧都没下发，串台的那句话不在下行里。
  assert.deepEqual(spoken(events), ['answer-a', 'answer-b'])
  assert.ok(!JSON.stringify(events).includes(Buffer.from('杭州天气查询失败了').toString('base64')))
  assert.deepEqual(events.map(event => event.type),
    ['agent.audio.delta', 'agent.audio.delta', 'agent.audio.done'])
  // 播报的 `audio.done` 没有提前收口：终态覆盖答案的全部序号。
  assert.equal(events.at(-1).final_sequence, 1)
  assert.equal(events.filter(event => event.type === 'agent.error').length, 0)
  // 丢弃留证：哪个 responseId、丢了几帧。
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_audio_dropped'
    && l.upstream_response_id === 'ann-1'))
  const dropped = logs.find(l => l.evt === 'upstream_announcement_audio_done_dropped')
  assert.equal(dropped.upstream_response_id, 'ann-1')
  assert.equal(dropped.dropped_frames, 2)
  assert.ok(dropped.dropped_bytes > 0)
  turn.close()
})

test('ESS-849 · 播报的 audio.done 落在两段之间：第二段（答案）不被 post_done 吞掉', async () => {
  // 真机 14:00 的时序：第一段说完 → 播报插进来并结束 → 答案的第二段才到。
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      send(ws, { type: 'voice.ready' })
      send(ws, { type: 'voice.state', state: 'listening', origin: 'model' })
    }
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ans-1', origin: 'model' })
      audioDelta(ws, 0, 'seg1', 'ans-1')
      send(ws, { type: 'audio.done', responseId: 'ans-1' })
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement' })
      audioDelta(ws, 0, '播报第一帧', 'ann-1')
      audioDelta(ws, 1, '播报第二帧', 'ann-1')
      send(ws, { type: 'audio.done', responseId: 'ann-1' })
      setTimeout(() => {
        send(ws, { type: 'response.started', responseId: 'ans-2', origin: 'agent' })
        audioDelta(ws, 1, 'seg2-a', 'ans-2')
        audioDelta(ws, 2, 'seg2-b', 'ans-2')
        send(ws, { type: 'audio.done', responseId: 'ans-2' })
        send(ws, { type: 'voice.state', state: 'idle', origin: 'agent' })
      }, 200)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, segmentGapMs: 700, segmentGapBusyMs: 700,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r2', sessionId: 's2', deviceId: 'd2', generation: 1, responseId: 'r2:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'), 4_000)

  assert.deepEqual(spoken(events), ['seg1', 'seg2-a', 'seg2-b'])
  assert.deepEqual(events.map(event => event.type), [
    'agent.audio.delta', 'agent.audio.segment_done',
    'agent.audio.delta', 'agent.audio.delta', 'agent.audio.done',
  ])
  assert.equal(events.at(-1).final_sequence, 2, '终态覆盖两段的全部序号')
  // 段落边界只有一个：播报既没有开新段，也没有充当终态。
  assert.equal(events.filter(event => event.type === 'agent.audio.segment_done').length, 1)
  assert.equal(logs.filter(l => l.evt === 'upstream_turn_terminal').length, 1)
  assert.equal(events.filter(event => event.type === 'agent.error').length, 0)
  turn.close()
})

test('ESS-849 · 只有播报音频时，应答死线照常到期（播报不算「上游在回答」）', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement' })
      audioDelta(ws, 0, '只有播报', 'ann-1')
      send(ws, { type: 'audio.done', responseId: 'ann-1' })
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 300,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r3', sessionId: 's3', deviceId: 'd3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  // 客户端拿到可判定的错误，而不是被一段无关播报骗成「已经在回答了」再干等。
  assert.equal(events.at(-1).code, 'ERR_UPSTREAM_NO_RESPONSE')
  assert.equal(events.filter(event => event.type === 'agent.audio.delta').length, 0)
  assert.ok(logs.some(l => l.evt === 'upstream_response_timeout'))
})

test('ESS-849 · 映射缺失默认放行：先 delta 后 started 的乱序漏网，但留证', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      // 乱序：音频先到，登记 origin 的 `response.started` 后到。
      audioDelta(ws, 0, 'ordered-late', 'ann-1')
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement' })
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r4', sessionId: 's4', deviceId: 'd4', generation: 1, responseId: 'r4:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => logs.some(l => l.evt === 'upstream_announcement_started_late'))
  // 宁可多播一段无关的，也不可吞掉用户的回答（毕玄-cx 2026-08-22 拍板）。
  assert.deepEqual(spoken(events), ['ordered-late'])
  assert.equal(
    logs.filter(l => l.evt === 'upstream_announcement_started_late'
      && l.upstream_response_id === 'ann-1').length, 1,
    '漏网必须留证——这条日志是将来改口径的唯一依据',
  )
  turn.close()
})

test('ESS-849 · 播报的 transcript 不作为本回合的文本上抛', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') send(ws, { type: 'voice.ready' })
    if (message.type === 'audio.commit') {
      send(ws, { type: 'response.started', responseId: 'ann-1', origin: 'announcement' })
      send(ws, { type: 'transcript.final', responseId: 'ann-1', role: 'assistant',
        content: '刚才查询的是杭州今天的天气情况，不是深圳的' })
      send(ws, { type: 'response.started', responseId: 'ans-1', origin: 'agent' })
      send(ws, { type: 'transcript.final', responseId: 'ans-1', role: 'assistant',
        content: '深圳今天多云' })
      audioDelta(ws, 0, 'answer', 'ans-1')
      send(ws, { type: 'audio.done', responseId: 'ans-1' })
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r5', sessionId: 's5', deviceId: 'd5', generation: 1, responseId: 'r5:gen1',
    onEvent: event => events.push(event),
  })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(
    events.filter(event => event.type === 'agent.transcript.final').map(event => event.content),
    ['深圳今天多云'],
  )
  assert.ok(logs.some(l => l.evt === 'upstream_announcement_transcript_dropped'
    && l.upstream_response_id === 'ann-1'))
  turn.close()
})
