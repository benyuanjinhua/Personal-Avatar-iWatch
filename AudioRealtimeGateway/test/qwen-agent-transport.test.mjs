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

// ESS-532: zero-delta done grace period prevents stale_generation_dropped
test('zero-delta done defers until grace expires, late deltas cancel grace', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      // Simulate the qwen-audio-agent bug: done arrives before deltas.
      ws.send(JSON.stringify({ type: 'audio.done' }))
      // After 100 ms, deltas arrive (late).
      setTimeout(() => {
        ws.send(JSON.stringify({ type: 'audio.delta', audio: Buffer.from('late').toString('base64'), sampleRate: 24_000, sequence: 0 }))
        ws.send(JSON.stringify({ type: 'audio.delta', audio: Buffer.from('also').toString('base64'), sampleRate: 24_000, sequence: 1 }))
        ws.send(JSON.stringify({ type: 'audio.done' }))
      }, 100)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url,
    doneZeroGraceMs: 500,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r3', sessionId: 's3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  // Should see: delta(0), delta(1), done(final=1) — NOT done(-1).
  assert.deepEqual(events.map(event => event.type), [
    'agent.audio.delta', 'agent.audio.delta', 'agent.audio.done',
  ])
  const doneEvent = events.find(event => event.type === 'agent.audio.done')
  assert.ok(doneEvent)
  assert.equal(doneEvent.final_sequence, 1)  // 2 deltas → final_sequence=1
  // Should have logged the grace start and cancellation.
  assert.ok(logs.some(item => item.evt === 'done_zero_grace_started'))
  assert.ok(logs.some(item => item.evt === 'done_zero_grace_cancelled'))
  // Should NOT have logged grace expired (deltas arrived in time).
  assert.ok(!logs.some(item => item.evt === 'done_zero_grace_expired'))
  turn.close()
})

test('zero-delta done emits -1 after grace expires with no deltas', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.done' }))
      // No deltas follow — this is a genuine zero-audio response.
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url,
    doneZeroGraceMs: 100,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r4', sessionId: 's4', generation: 1, responseId: 'r4:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.length === 1)
  assert.equal(events[0].type, 'agent.audio.done')
  assert.equal(events[0].final_sequence, -1)
  assert.ok(logs.some(item => item.evt === 'done_zero_grace_started'))
  assert.ok(logs.some(item => item.evt === 'done_zero_grace_expired'))
  turn.close()
})
