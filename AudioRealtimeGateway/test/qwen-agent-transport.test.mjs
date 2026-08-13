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

// ESS-745: request_id is client-supplied (token-issuer only checks it is a
// string), and one transport instance serves every connection of the process.
// Two different devices/sessions may therefore present the SAME request_id.
test('two sessions sharing a requestId keep independent turns', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', audio: Buffer.from('b').toString('base64') }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const transport = new QwenAgentTransport({ gatewayUrl: url })
  const eventsA = []; const eventsB = []
  const turnA = transport.openTurn({
    requestId: 'shared-req', sessionId: 'sA', deviceId: 'dA', generation: 1,
    responseId: 'shared-req:gen1@A', onEvent: event => eventsA.push(event),
  })
  const turnB = transport.openTurn({
    requestId: 'shared-req', sessionId: 'sB', deviceId: 'dB', generation: 1,
    responseId: 'shared-req:gen1@B', onEvent: event => eventsB.push(event),
  })
  // Neither device may evict or supersede the other's book-keeping.
  assert.equal(transport.turns.size, 2)
  assert.deepEqual(eventsA, [])

  // Closing A must leave B registered and working.
  turnA.close()
  assert.equal(transport.turns.size, 1)
  assert.equal([...transport.turns.values()][0].sessionId, 'sB')
  turnB.appendAudio({ bytes: Buffer.from('audio') })
  turnB.commit()
  await waitFor(() => eventsB.some(event => event.type === 'agent.audio.done'))
  assert.ok(eventsB.every(event => event.response_id === 'shared-req:gen1@B'))
  assert.deepEqual(eventsA, [])
  turnB.close()
  assert.equal(transport.turns.size, 0)
})

// ESS-745: a barge-in retry may reuse the same request_id with generation+1.
// The superseded socket settles late; its close must not evict the replacement.
test('late close of a superseded same-requestId turn does not evict its replacement', async () => {
  const connections = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { connections.push(ws); ws.send(JSON.stringify({ type: 'voice.ready' })) }
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', audio: Buffer.from('b').toString('base64') }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const logs = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }) })
  const eventsOld = []; const eventsNew = []
  const oldTurn = transport.openTurn({
    requestId: 'r1', sessionId: 's1', deviceId: 'd1', generation: 1,
    responseId: 'r1:gen1', onEvent: event => eventsOld.push(event),
  })
  await waitFor(() => logs.some(item => item.evt === 'upstream_ready' && item.generation === 1))

  const newTurn = transport.openTurn({
    requestId: 'r1', sessionId: 's1', deviceId: 'd1', generation: 2,
    responseId: 'r1:gen2', onEvent: event => eventsNew.push(event),
  })
  assert.ok(logs.some(item => item.evt === 'upstream_turn_superseded' && item.generation === 1))
  assert.equal(transport.turns.size, 1)
  assert.equal([...transport.turns.values()][0].generation, 2)

  // The old upstream socket now settles (close/error arrive after the
  // replacement was registered) and the old session tears its handle down.
  await waitFor(() => connections.length === 2)
  connections[0].close(1011, 'late')
  oldTurn.close()
  await new Promise(resolve => setTimeout(resolve, 50))

  assert.equal(transport.turns.size, 1)
  assert.equal([...transport.turns.values()][0].generation, 2)
  assert.deepEqual(eventsOld, [])
  newTurn.appendAudio({ bytes: Buffer.from('audio') })
  newTurn.commit()
  await waitFor(() => eventsNew.some(event => event.type === 'agent.audio.done'))
  assert.ok(eventsNew.every(event => event.response_id === 'r1:gen2'))
  newTurn.close()
})

// ESS-773. The downstream done barrier can only release on a dense 0..N run,
// so this adapter owns the contract sequence and treats the provider's as
// diagnostic. These five cases are the contract: restart, replay, legitimate
// repeated payload, late delta after done, and completion on upstream close.
test('normalizes restarted upstream sequences and holds done for late audio', async () => {
  const audio = value => Buffer.from(value).toString('base64')
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 10, audio: audio('a') }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 11, audio: audio('b') }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
      setTimeout(() => {
        // The provider restarts its counter after done. These are new audio,
        // not response-scoped duplicates, and must extend the done barrier.
        ws.send(JSON.stringify({ type: 'audio.delta', sequence: 10, audio: audio('c') }))
        ws.send(JSON.stringify({ type: 'audio.delta', sequence: 11, audio: audio('d') }))
      }, 10)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 60,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r3', sessionId: 's3', generation: 1, responseId: 'r3:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(
    events.filter(event => event.type === 'agent.audio.delta').map(event => event.sequence),
    [0, 1, 2, 3],
  )
  assert.equal(events.at(-1).type, 'agent.audio.done')
  assert.equal(events.at(-1).final_sequence, 3)
  assert.ok(logs.some(item => item.evt === 'upstream_done_extended_for_late_delta'))
  turn.close()
})

// A duplicate is witnessed by the upstream sequence, not by the clock: the
// observed replay path (a reliable WCSession copy) can settle far later than
// any plausible arrival window.
test('drops an exact upstream replay however late it arrives', async () => {
  const payload = Buffer.from('same-frame').toString('base64')
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      const frame = JSON.stringify({ type: 'audio.delta', sequence: 7, audio: payload })
      ws.send(frame)
      setTimeout(() => {
        ws.send(frame)
        ws.send(JSON.stringify({ type: 'audio.done' }))
      }, 120)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r4', sessionId: 's4', generation: 1, responseId: 'r4:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.equal(events.filter(event => event.type === 'agent.audio.delta').length, 1)
  assert.equal(events.at(-1).final_sequence, 0)
  assert.equal(logs.filter(item => item.evt === 'upstream_audio_duplicate_dropped').length, 1)
  turn.close()
})

// The mirror of the case above: identical bytes at a NEW upstream sequence are
// legitimate audio (silence repeats constantly) and must survive.
test('keeps identical audio that arrives at a new upstream sequence', async () => {
  const silence = 'AAAA'
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: silence }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 1, audio: silence }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 2, audio: silence }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, doneSettleMs: 20 })
  const turn = transport.openTurn({
    requestId: 'r5', sessionId: 's5', generation: 1, responseId: 'r5:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(
    events.filter(event => event.type === 'agent.audio.delta').map(event => event.sequence),
    [0, 1, 2],
  )
  assert.equal(events.at(-1).final_sequence, 2)
  turn.close()
})

// The settle window must not turn a completed response into a disconnect: the
// provider is free to close the socket the moment it has sent `audio.done`.
test('releases the pending done when the upstream closes right after it', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
      ws.close(1000, 'complete')
    }
  })
  const events = []
  const transport = new QwenAgentTransport({ gatewayUrl: url, doneSettleMs: 5_000 })
  const turn = transport.openTurn({
    requestId: 'r6', sessionId: 's6', generation: 1, responseId: 'r6:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(event => event.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.equal(events.at(-1).final_sequence, 0)
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
