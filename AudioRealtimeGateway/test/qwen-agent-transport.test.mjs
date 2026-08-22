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

// ESS-974: the provider broadcasts ownership state globally. A superseded
// instance's delayed deactivate can therefore arrive on the replacement
// socket; socket-local current-turn checks alone cannot distinguish it.
test('delayed deactivate naming a superseded instance cannot kill its replacement', async () => {
  const instanceIds = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      instanceIds.push(message.clientInstanceId)
      ws.send(JSON.stringify({ type: 'voice.ready' }))
      if (instanceIds.length === 2) {
        setTimeout(() => ws.send(JSON.stringify({
          type: 'voice.deactivated',
          holder: {
            type: 'cli', label: 'watch-direct-gateway', instanceId: instanceIds[0],
          },
        })), 20)
      }
    }
    if (message.type === 'audio.commit') {
      setTimeout(() => {
        ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
        ws.send(JSON.stringify({ type: 'audio.done' }))
      }, 50)
    }
  })
  const logs = []; const oldEvents = []; const newEvents = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 10,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  transport.openTurn({
    requestId: 'old', sessionId: 's974', deviceId: 'd974', generation: 1,
    responseId: 'old:gen1', onEvent: event => oldEvents.push(event),
  })
  await waitFor(() => instanceIds.length === 1)
  const replacement = transport.openTurn({
    requestId: 'new', sessionId: 's974', deviceId: 'd974', generation: 2,
    responseId: 'new:gen2', onEvent: event => newEvents.push(event),
  })
  replacement.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  replacement.commit()
  await waitFor(() => newEvents.some(event => event.type === 'agent.audio.done'))

  assert.deepEqual(oldEvents, [])
  assert.ok(!newEvents.some(event => event.type === 'agent.error'))
  assert.ok(logs.some(item => item.evt === 'upstream_ownership_ignored'
    && item.reason === 'retired_client_instance'))
  replacement.close()
})

// ESS-773. The downstream done barrier can only release on a dense 0..N run,
// so this adapter owns the contract sequence and treats the provider's as
// diagnostic. These cases are the contract: restart, replay, legitimate
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
    gatewayUrl: url, doneSettleMs: 60, reorderWaitMs: 5,
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

test('drops a near-simultaneous exact upstream replay only once', async () => {
  const payload = Buffer.from('same-frame').toString('base64')
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      const frame = JSON.stringify({ type: 'audio.delta', sequence: 7, audio: payload })
      ws.send(frame); ws.send(frame)
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20, duplicateWindowMs: 200, reorderWaitMs: 5,
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

// The window has to expire. The provider's counter is not response-scoped, so
// the same fingerprint can legitimately reappear later — silence at a restarted
// sequence is the ordinary case, and suppressing it would delete real audio.
test('keeps an identical frame that repeats outside the replay window', async () => {
  const payload = Buffer.from('same-frame').toString('base64')
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      const frame = JSON.stringify({ type: 'audio.delta', sequence: 7, audio: payload })
      ws.send(frame)
      setTimeout(() => {
        ws.send(frame)
        ws.send(JSON.stringify({ type: 'audio.done' }))
      }, 80)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20, duplicateWindowMs: 20, reorderWaitMs: 5,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r7', sessionId: 's7', generation: 1, responseId: 'r7:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(
    events.filter(event => event.type === 'agent.audio.delta').map(event => event.sequence),
    [0, 1],
  )
  assert.equal(events.at(-1).final_sequence, 1)
  assert.equal(logs.filter(item => item.evt === 'upstream_audio_duplicate_dropped').length, 0)
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

// ESS-823 blocker 1. The upstream sequence keeps its ORDERING meaning: frames
// that arrive out of order are reordered before the dense downstream sequence
// is assigned, so the Watch plays A before B — not arrival order.
test('reorders an out-of-order upstream pair before assigning the downstream sequence', async () => {
  const audio = value => Buffer.from(value).toString('base64')
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 11, audio: audio('B') }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 10, audio: audio('A') }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20, reorderWaitMs: 30,
  })
  const turn = transport.openTurn({
    requestId: 'r9', sessionId: 's9', generation: 1, responseId: 'r9:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  const deltas = events.filter(event => event.type === 'agent.audio.delta')
  assert.deepEqual(deltas.map(event => Buffer.from(event.audio, 'base64').toString()), ['A', 'B'])
  assert.deepEqual(deltas.map(event => event.sequence), [0, 1])
  assert.equal(events.at(-1).final_sequence, 1)
  turn.close()
})

// Mid-stream reorder, with the response anchored at 0 so nothing waits.
test('fills an out-of-order hole without delaying the frames around it', async () => {
  const audio = value => Buffer.from(value).toString('base64')
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: audio('A') }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 2, audio: audio('C') }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 1, audio: audio('B') }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20, reorderWaitMs: 200,
  })
  const turn = transport.openTurn({
    requestId: 'r10', sessionId: 's10', generation: 1, responseId: 'r10:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  const deltas = events.filter(event => event.type === 'agent.audio.delta')
  assert.deepEqual(deltas.map(event => Buffer.from(event.audio, 'base64').toString()), ['A', 'B', 'C'])
  assert.deepEqual(deltas.map(event => event.sequence), [0, 1, 2])
  assert.equal(events.at(-1).final_sequence, 2)
  turn.close()
})

// ESS-823 blocker 2, the silent-loss counterexample: upstream {0,2,done} must
// NOT become downstream {0,1,done(1)}. A frame the upstream never delivered is
// a failure, not a shorter response.
test('fails closed on a real upstream gap instead of renumbering past it', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 2, audio: 'BBBB' }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20, reorderWaitMs: 40,
  })
  const turn = transport.openTurn({
    requestId: 'r11', sessionId: 's11', generation: 1, responseId: 'r11:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  // Only the frame ahead of the hole was forwarded, and no done was invented.
  assert.equal(events.filter(event => event.type === 'agent.audio.delta').length, 1)
  assert.ok(!events.some(event => event.type === 'agent.audio.done'))
  assert.equal(events.at(-1).code, 'ERR_UPSTREAM_SEQUENCE_GAP')
  assert.equal(events.at(-1).retriable, true)
  turn.close()
})

// ESS-746 × ESS-773. Validation, the frame cap and the per-turn budget all run
// BEFORE the sequence is assigned, so a frame that fails closed never consumes
// a downstream sequence and never leaves a hole in the dense run.
test('a frame rejected by the ESS-746 budget consumes no downstream sequence', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      for (let sequence = 0; sequence < 6; sequence++) {
        ws.send(JSON.stringify({ type: 'audio.delta', sequence, audio: 'AAAA' }))
      }
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, doneSettleMs: 20, maxDownlinkFrames: 2,
  })
  const turn = transport.openTurn({
    requestId: 'r8', sessionId: 's8', generation: 1, responseId: 'r8:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.deepEqual(
    events.filter(event => event.type === 'agent.audio.delta').map(event => event.sequence),
    [0, 1],
  )
  assert.equal(events.at(-1).code, 'ERR_UPSTREAM_BUDGET_EXCEEDED')
  // Fail closed: no done is manufactured for a turn that was cut off.
  assert.ok(!events.some(event => event.type === 'agent.audio.done'))
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

// ESS-842 真机事故：uplink_committed 之后没有 speech_final / response.started /
// audio.delta / audio.done，客户端等到 1006 断开为止。上游对非 owner 的音频是
// 静默丢弃（ESS-37 §2.1），所以「上游一句话都不回」必须自己有终止条件。
test('a committed turn that gets no upstream response fails closed', async () => {
  const url = await upstream((ws, message) => {
    // Ready 之后完全沉默：既不回 audio.delta / audio.done，也不回 error。
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 120, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r842', sessionId: 's842', deviceId: 'd842', generation: 1,
    responseId: 'r842:gen1', onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.equal(events.at(-1).code, 'ERR_UPSTREAM_NO_RESPONSE')
  assert.equal(events.at(-1).retriable, true)
  const timeout = logs.find(item => item.evt === 'upstream_response_timeout')
  assert.ok(timeout, 'the deadline must leave forensics behind')
  assert.equal(timeout.request_id, 'r842')
  assert.equal(timeout.upstream_ready, true)
  assert.equal(timeout.timeout_ms, 120)
  // 没有回答就不许伪造 done：客户端不能把「无回答」当成一次成功回合。
  assert.ok(!events.some(event => event.type === 'agent.audio.done'))
  assert.equal(transport.turns.size, 0)
})

// 对照组：上游正常回答时，deadline 不得误杀一个健康回合。
test('the response deadline does not fire once the upstream answers', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
      // done 故意晚于 responseTimeoutMs 到达：第一帧已经证明上游在回答。
      setTimeout(() => ws.send(JSON.stringify({ type: 'audio.done' })), 90)
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 40, doneSettleMs: 10,
  })
  const turn = transport.openTurn({
    requestId: 'r843', sessionId: 's843', generation: 1, responseId: 'r843:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.deepEqual(events.map(event => event.type), ['agent.audio.delta', 'agent.audio.done'])
  assert.ok(!events.some(event => event.type === 'agent.error'))
  turn.close()
})

// 握手期间排队的 commit，其 deadline 必须从 voice.ready 真正下发那一刻起表，
// 而不是从客户端调用 commit() 那一刻——否则慢握手会吃掉整个回答预算。
test('a commit queued behind the handshake starts its deadline at voice.ready', async () => {
  let readyGate = null
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') readyGate = () => ws.send(JSON.stringify({ type: 'voice.ready' }))
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 100, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r844', sessionId: 's844', generation: 1, responseId: 'r844:gen1',
    onEvent: event => events.push(event),
  })
  await waitFor(() => readyGate !== null)
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  // 还没 ready：commit 只是排队，deadline 不该起表，更不该到期。
  await new Promise(resolve => setTimeout(resolve, 150))
  assert.deepEqual(events, [])
  readyGate()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.equal(events.at(-1).code, 'ERR_UPSTREAM_NO_RESPONSE')
  assert.ok(logs.some(item => item.evt === 'upstream_ready'))
})

// ESS-37 §2.1：所有权被别人拿走之后，上游对我们的 append/commit 静默丢弃。
// 与其烧完整个回答 deadline，不如在所有权丢失的当下就带着持有者失败。
test('ownership lost mid-turn fails the turn with the holder named', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      ws.send(JSON.stringify({ type: 'voice.ready' }))
      setTimeout(() => ws.send(JSON.stringify({
        type: 'voice.ownership', state: 'busy',
        holder: { type: 'cli', label: 'watch-bridge', instanceId: 'bridge_other' },
      })), 20)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 5_000, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r845', sessionId: 's845', generation: 1, responseId: 'r845:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.equal(events.at(-1).code, 'ERR_VOICE_OWNERSHIP_LOST')
  assert.ok(events.at(-1).detail.includes('watch-bridge'))
  const ownership = logs.find(item => item.evt === 'upstream_ownership')
  assert.equal(ownership.state, 'busy')
  assert.equal(ownership.holder_label, 'watch-bridge')
  assert.equal(ownership.holder_is_self, false)
})

// 反向保证：网关只是把我们自己的所有权回播回来（ESS-37 的 unmute 幂等回播就是
// 这一形状），不得被误判成「所有权丢失」而打断一个健康回合。
test('an ownership echo naming ourselves does not kill the turn', async () => {
  const seen = []
  const url = await upstream((ws, message) => {
    seen.push(message)
    if (message.type === 'connect') {
      ws.send(JSON.stringify({ type: 'voice.ready' }))
      setTimeout(() => ws.send(JSON.stringify({
        type: 'voice.ownership', state: 'busy',
        holder: { type: 'cli', label: 'watch-direct-gateway', instanceId: message.clientInstanceId },
      })), 10)
    }
    if (message.type === 'audio.commit') {
      setTimeout(() => {
        ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
        ws.send(JSON.stringify({ type: 'audio.done' }))
      }, 40)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 2_000, doneSettleMs: 10,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r846', sessionId: 's846', generation: 1, responseId: 'r846:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.ok(!events.some(event => event.type === 'agent.error'))
  assert.equal(logs.find(item => item.evt === 'upstream_ownership').holder_is_self, true)
  turn.close()
})

// voice.deactivated 是「被抢占」的明确信号，不需要 holder 就能判定。
// ESS-978 取证：带 holder 时，抢占者的 label + instanceId 必须落证，
// 让「同标签的另一网关实例」从此有唯一标识。
test('voice.deactivated after ready fails the turn immediately', async () => {
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      ws.send(JSON.stringify({ type: 'voice.ready' }))
      setTimeout(() => ws.send(JSON.stringify({
        type: 'voice.deactivated',
        holder: { type: 'cli', label: 'watch-direct-gateway:4242', instanceId: 'gateway_rogue_abc' },
      })), 20)
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 5_000, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r847', sessionId: 's847', generation: 1, responseId: 'r847:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.equal(events.at(-1).code, 'ERR_VOICE_OWNERSHIP_LOST')
  const ownership = logs.find(item => item.evt === 'upstream_ownership')
  assert.equal(ownership.state, 'deactivated')
  assert.equal(ownership.holder_label, 'watch-direct-gateway:4242')
  assert.equal(ownership.holder_instance_id, 'gateway_rogue_abc')
  assert.equal(ownership.holder_is_self, false)
  assert.ok(events.at(-1).detail.includes('gateway_rogue_abc'))
})

// 边界补齐（PR #325 的用例并入）：用户已经挂断 / 打断的一轮，不许在
// deadline 到期时再冒出一条错误事件——那会打断的是它的**下一轮**。
// 实现里 cancel/close/supersede 都清了表，这里把它钉住。
test('ESS-842: cancel and close disarm the committed-turn deadline', async () => {
  const url = await upstream((ws, message) => {
    // 只握手，之后永远沉默——deadline 若没被撤，必然到期。
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
  })
  const transport = new QwenAgentTransport({ gatewayUrl: url, responseTimeoutMs: 30 })
  for (const [index, teardown] of ['cancel', 'close'].entries()) {
    const events = []
    const turn = transport.openTurn({
      requestId: `r842t_${index}`, sessionId: `s842t_${index}`, generation: 1,
      responseId: `r842t_${index}:gen1`, onEvent: event => events.push(event),
    })
    turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
    turn.commit()
    turn[teardown]()
    await new Promise(resolve => setTimeout(resolve, 120))
    assert.deepEqual(events, [], `${teardown} 之后不得再有 deadline 事件`)
  }
})

// ESS-978：语音被同标签的另一个网关实例持有（真机 2026-08-22 02:19 事故形状）。
// 第二个实例必须先拿到持有者、认出是陌生网关进程，然后拒绝而不是反抢——
// 全程不得发出 takeover=true 的 connect。
test('a foreign gateway holder is never taken over (ESS-978)', async () => {
  const connects = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      connects.push(message)
      if (message.takeover === false) {
        ws.send(JSON.stringify({
          type: 'voice.ownership', state: 'busy',
          holder: { type: 'cli', label: 'watch-direct-gateway:4242', instanceId: 'gateway_rogue_abc' },
        }))
      } else {
        // 不应走到这里：foreign gateway 不满足 takeoverEligible。
        ws.send(JSON.stringify({ type: 'voice.ready' }))
      }
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, clientLabel: 'watch-direct-gateway:1111',
    responseTimeoutMs: 5_000, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r848', sessionId: 's848', generation: 1, responseId: 'r848:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.equal(events.at(-1).code, 'ERR_VOICE_BUSY')
  assert.ok(events.at(-1).detail.includes('gateway_rogue_abc'))
  assert.equal(connects.length, 1)
  assert.equal(connects[0].takeover, false)
  assert.equal(logs.find(item => item.evt === 'upstream_ownership').holder_instance_id, 'gateway_rogue_abc')
  assert.equal(logs.some(item => item.evt === 'upstream_takeover_retry'), false)
})

// ESS-978：持有者是本进程上一轮残留（同 clientLabel）→ 允许带 takeover 重试一次，
// 拿回自己的语音槽。这是 barge-in / 上一连接还没释放所有权的正常形状。
test('our own prior connection is reclaimed with takeover (ESS-978)', async () => {
  const connects = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      connects.push(message)
      if (message.takeover === false) {
        ws.send(JSON.stringify({
          type: 'voice.ownership', state: 'busy',
          holder: { type: 'cli', label: 'watch-direct-gateway:1111', instanceId: 'gateway_self_old' },
        }))
      } else {
        ws.send(JSON.stringify({ type: 'voice.ready' }))
      }
    }
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, clientLabel: 'watch-direct-gateway:1111',
    responseTimeoutMs: 5_000, doneSettleMs: 10, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r849', sessionId: 's849', generation: 1, responseId: 'r849:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.ok(!events.some(event => event.type === 'agent.error'))
  assert.deepEqual(connects.map(c => c.takeover), [false, true])
  assert.ok(logs.some(item => item.evt === 'upstream_takeover_retry'))
  turn.close()
})

// ESS-978 反向保证：持有者是一个非网关前台（例如 Bridge），且配置允许抢占时，
// 仍然走 takeover 拿回语音槽——不能让新防护误伤原本的「Watch 显式说话抢占」语义。
test('an allowed frontend holder is still taken over (ESS-978)', async () => {
  const connects = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      connects.push(message)
      if (message.takeover === false) {
        ws.send(JSON.stringify({
          type: 'voice.ownership', state: 'busy',
          holder: { type: 'cli', label: 'watch-bridge', instanceId: 'bridge_other' },
        }))
      } else {
        ws.send(JSON.stringify({ type: 'voice.ready' }))
      }
    }
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio: 'AAAA' }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, clientLabel: 'watch-direct-gateway:1111',
    responseTimeoutMs: 5_000, doneSettleMs: 10,
  })
  const turn = transport.openTurn({
    requestId: 'r850', sessionId: 's850', generation: 1, responseId: 'r850:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.ok(!events.some(event => event.type === 'agent.error'))
  assert.deepEqual(connects.map(c => c.takeover), [false, true])
  turn.close()
})

// ESS-978 反向保证：前台持有者但配置不允许抢占 → 拒绝，不反抢。
test('a frontend holder is refused when takeover is disabled (ESS-978)', async () => {
  const connects = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') {
      connects.push(message)
      if (message.takeover === false) {
        ws.send(JSON.stringify({
          type: 'voice.ownership', state: 'busy',
          holder: { type: 'cli', label: 'watch-bridge', instanceId: 'bridge_other' },
        }))
      } else {
        ws.send(JSON.stringify({ type: 'voice.ready' }))
      }
    }
  })
  const events = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, clientLabel: 'watch-direct-gateway:1111', takeover: false,
    responseTimeoutMs: 5_000,
  })
  const turn = transport.openTurn({
    requestId: 'r851', sessionId: 's851', generation: 1, responseId: 'r851:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.error'))
  assert.equal(events.at(-1).code, 'ERR_VOICE_BUSY')
  assert.equal(connects.length, 1)
  assert.equal(connects[0].takeover, false)
})
