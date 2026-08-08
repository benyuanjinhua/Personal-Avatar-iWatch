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

test('five turns in one session cancel prior requests and reject their late audio', async () => {
  const sockets = []
  const messages = []
  const server = new WebSocketServer({ port: 0 })
  servers.push(server)
  server.on('connection', ws => {
    const index = sockets.length
    sockets.push(ws)
    ws.on('message', raw => {
      const message = JSON.parse(raw.toString())
      messages.push({ index, message })
      if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
      if (message.type === 'audio.commit') {
        setTimeout(() => {
          if (ws.readyState !== ws.OPEN) return
          ws.send(JSON.stringify({
            type: 'audio.delta',
            audio: Buffer.from(`answer-${index + 1}`).toString('base64'),
            sampleRate: 24_000,
          }))
          ws.send(JSON.stringify({ type: 'audio.done' }))
        }, index === 4 ? 5 : 80)
      }
    })
  })
  await new Promise(resolve => server.once('listening', resolve))

  const logs = []
  const eventsByRequest = new Map()
  const transport = new QwenAgentTransport({
    gatewayUrl: `ws://127.0.0.1:${server.address().port}/api/realtime`,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })

  let activeTurn
  for (let turnNumber = 1; turnNumber <= 5; turnNumber += 1) {
    const requestId = `request-${turnNumber}`
    const events = []
    eventsByRequest.set(requestId, events)
    const turn = transport.openTurn({
      requestId, sessionId: 'conversation-1', generation: turnNumber,
      responseId: `${requestId}:gen${turnNumber}`,
      onEvent: event => events.push(event),
    })
    turn.appendAudio({ sequence: 0, bytes: Buffer.from(`question-${turnNumber}`) })
    turn.commit()
    activeTurn = turn
    await waitFor(() => sockets.length === turnNumber)
  }

  await waitFor(() => eventsByRequest.get('request-5')
    .some(event => event.type === 'agent.audio.done'))
  await new Promise(resolve => setTimeout(resolve, 120))

  for (let turnNumber = 1; turnNumber < 5; turnNumber += 1) {
    assert.deepEqual(eventsByRequest.get(`request-${turnNumber}`), [],
      `late answer from request-${turnNumber} must be discarded`)
  }
  const finalEvents = eventsByRequest.get('request-5')
  assert.deepEqual(finalEvents.map(event => event.type), [
    'agent.audio.delta', 'agent.audio.done',
  ])
  assert.equal(
    Buffer.from(finalEvents[0].audio, 'base64').toString(),
    'answer-5',
  )
  assert.deepEqual(
    logs.filter(item => item.evt === 'upstream_turn_superseded')
      .map(item => [item.request_id, item.superseded_by_request_id]),
    [
      ['request-1', 'request-2'],
      ['request-2', 'request-3'],
      ['request-3', 'request-4'],
      ['request-4', 'request-5'],
    ],
  )
  assert.equal(messages.filter(item => item.message.type === 'response.cancel').length, 4)
  activeTurn.close()
})
