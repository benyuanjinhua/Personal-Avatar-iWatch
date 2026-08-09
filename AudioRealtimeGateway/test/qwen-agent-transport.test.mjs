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

test('agent transport forwards real upstream audio with request-scoped logs', async () => {
  const received = []
  const url = await upstream((ws, message) => {
    received.push(message)
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', audio: Buffer.from('reply').toString('base64'), sampleRate: 24_000 }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }) })
  const turn = transport.openTurn({
    requestId: 'r1', sessionId: 's1', generation: 1, responseId: 'r1:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.ok(received.some(event => event.type === 'audio.append'))
  assert.deepEqual(events.map(event => event.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.ok(logs.some(item => item.evt === 'upstream_ready' && item.request_id === 'r1'))
  assert.ok(logs.some(item => item.evt === 'upstream_audio_done' && item.request_id === 'r1'))
  assert.deepEqual(
    logs.filter(item => item.evt === 'upstream_event_received').map(item => item.upstream_event_type),
    ['audio.delta', 'audio.done'],
  )
  assert.ok(logs.filter(item => item.evt === 'upstream_event_received')
    .every(item => item.request_id === 'r1'))
  assert.ok(!JSON.stringify(logs).includes('provider'))
  turn.close()
})

test('upstream failure becomes one structured agent error', async () => {
  const url = await upstream(ws => ws.close(1011, 'provider unavailable'))
  const events = []; const logs = []
  new QwenAgentTransport({ gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }) }).openTurn({
    requestId: 'r2', sessionId: 's2', generation: 1, responseId: 'r2:gen1',
    onEvent: event => events.push(event),
  })
  await waitFor(() => events.length === 1)
  assert.equal(events[0].type, 'agent.error')
  assert.equal(events[0].code, 'ERR_UPSTREAM_DISCONNECTED')
  assert.equal(logs.filter(item => item.evt === 'upstream_error').length, 1)
})

// ESS-551 A3: the Gateway MUST explicitly disable Qwen server-side turn
// detection (connect first frame carries `turnDetection: null`) so the
// Watch-side VAD is the single authoritative turn boundary (方案 §2.1).
// If this field ever goes missing, Watch VAD and Qwen VAD produce
// conflicting `final` judgments — this test MUST fail in that case.
test('connect first frame disables server-side turn detection (ESS-551 A3)', async () => {
  let connectMessage = null
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      connectMessage = message
      ws.send(JSON.stringify({ type: 'voice.ready' }))
    }
  })
  const events = []
  const logs = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }) })
  const turn = transport.openTurn({
    requestId: 'r-turn-detection', sessionId: 's3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  await waitFor(() => connectMessage !== null)
  // Acceptance: "Gateway 建立 Qwen realtime session，出站首帧一定包含
  // turn_detection 关闭配置" — own-property check catches both a missing
  // key and an accidental refactor that drops the field.
  assert.ok(connectMessage, 'connect message must be sent on open')
  assert.ok(
    Object.prototype.hasOwnProperty.call(connectMessage, 'turnDetection'),
    'connect first frame MUST contain the turnDetection key',
  )
  assert.equal(connectMessage.turnDetection, null, 'turnDetection must be null (server-side VAD off)')
  // Acceptance: "Gateway open 日志含 turn_detection=off".
  const configLogs = logs.filter(item => item.evt === 'turn_detection_config')
  assert.ok(configLogs.length >= 1, 'turn_detection_config log must be emitted on open')
  assert.equal(configLogs[0].turn_detection, 'off', 'open log must record turn_detection=off')
  assert.equal(configLogs[0].request_id, 'r-turn-detection')
  turn.close()
})

// ESS-551 A3 exit plan: the kill switch is config-gated. With
// disableServerTurnDetection: false the field stays off the wire and the
// open log records the upstream default instead of 'off'.
test('turn-detection kill switch can be disabled via config (ESS-551 A3 exit plan)', async () => {
  let connectMessage = null
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      connectMessage = message
      ws.send(JSON.stringify({ type: 'voice.ready' }))
    }
  })
  const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, disableServerTurnDetection: false,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r-td-off', sessionId: 's4', generation: 1, responseId: 'r4:gen1',
    onEvent: () => {},
  })
  await waitFor(() => connectMessage !== null)
  assert.ok(connectMessage, 'connect message must be sent on open')
  assert.ok(
    !Object.prototype.hasOwnProperty.call(connectMessage, 'turnDetection'),
    'turnDetection must be omitted when the kill switch is disabled',
  )
  const configLogs = logs.filter(item => item.evt === 'turn_detection_config')
  assert.ok(configLogs.length >= 1, 'turn_detection_config log must still be emitted')
  assert.equal(configLogs[0].turn_detection, 'upstream_default')
  turn.close()
})
