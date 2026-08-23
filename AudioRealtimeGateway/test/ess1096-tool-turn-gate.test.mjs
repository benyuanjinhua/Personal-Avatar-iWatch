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
  server.on('connection', ws => ws.on('message', raw => onMessage(ws, JSON.parse(raw.toString()))))
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

const audio = Buffer.from('answer').toString('base64')

test('running task suppresses idle/audio terminal until task terminal', async () => {
  let socket
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { socket = ws; ws.send(JSON.stringify({ type: 'voice.ready' })) }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, multiSegmentMode: 'always', doneSettleMs: 5,
    segmentGapMs: 20, segmentGapBusyMs: 100,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'old', sessionId: 'session', deviceId: 'watch', generation: 1,
    responseId: 'old:gen1', onEvent: event => events.push(event),
  })
  await waitFor(() => socket)
  socket.send(JSON.stringify({ type: 'task.running', task: { id: 'task-1', status: 'running' } }))
  socket.send(JSON.stringify({ type: 'voice.state', state: 'idle' }))
  socket.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio }))
  socket.send(JSON.stringify({ type: 'audio.done' }))
  await new Promise(resolve => setTimeout(resolve, 40))
  assert.ok(!events.some(event => event.type === 'agent.audio.done'))
  assert.ok(logs.some(log => log.evt === 'upstream_voice_state_idle'))

  socket.send(JSON.stringify({ type: 'task.completed', task: { id: 'task-1', status: 'completed' } }))
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))
  assert.ok(logs.some(log => log.evt === 'upstream_turn_terminal'
    && log.reason === 'task_terminal_and_audio_done'))
  turn.close()
})

test('new turn cannot supersede a running tool turn, but explicit cancel releases it', async () => {
  const sockets = []
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { sockets.push(ws); ws.send(JSON.stringify({ type: 'voice.ready' })) }
  })
  const logs = []; const oldEvents = []; const rejectedEvents = []; const replacementEvents = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, responseTimeoutMs: 0,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const oldTurn = transport.openTurn({
    requestId: 'old', sessionId: 'session', deviceId: 'watch', generation: 1,
    responseId: 'old:gen1', onEvent: event => oldEvents.push(event),
  })
  await waitFor(() => sockets.length === 1)
  sockets[0].send(JSON.stringify({ type: 'task.running', task: { id: 'task-1', status: 'running' } }))
  await waitFor(() => logs.some(log => log.evt === 'upstream_task_state'))

  const replacement = transport.openTurn({
    requestId: 'automatic-new', sessionId: 'session', deviceId: 'watch', generation: 2,
    responseId: 'automatic-new:gen2', onEvent: event => rejectedEvents.push(event),
  })
  await waitFor(() => rejectedEvents.length === 1)
  assert.equal(rejectedEvents[0].code, 'ERR_TOOL_TURN_BUSY')
  assert.equal(sockets.length, 1)
  assert.equal(transport.turns.size, 1)
  assert.ok(logs.some(log => log.evt === 'upstream_supersede_suppressed'
    && log.decision === 'reject_new_turn'))

  oldTurn.cancel()
  transport.openTurn({
    requestId: 'user-barge-in', sessionId: 'session', deviceId: 'watch', generation: 3,
    responseId: 'user-barge-in:gen3', onEvent: event => replacementEvents.push(event),
  })
  await waitFor(() => sockets.length === 2)
  assert.equal(transport.turns.size, 1)
  assert.deepEqual(replacementEvents, [])
  replacement.close()
})

test('stuck task fails with an explicit bounded timeout', async () => {
  let socket
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') { socket = ws; ws.send(JSON.stringify({ type: 'voice.ready' })) }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, multiSegmentMode: 'always', doneSettleMs: 5,
    segmentGapMs: 15, segmentGapBusyMs: 30,
    log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  transport.openTurn({
    requestId: 'timeout', sessionId: 'session', deviceId: 'watch', generation: 1,
    responseId: 'timeout:gen1', onEvent: event => events.push(event),
  })
  await waitFor(() => socket)
  socket.send(JSON.stringify({ type: 'task.running', task: { id: 'stuck', status: 'running' } }))
  socket.send(JSON.stringify({ type: 'audio.delta', sequence: 0, audio }))
  socket.send(JSON.stringify({ type: 'audio.done' }))
  await waitFor(() => events.some(event => event.code === 'ERR_TOOL_TASK_TIMEOUT'))
  assert.ok(logs.some(log => log.evt === 'upstream_tool_turn_timeout'))
  assert.equal(transport.turns.size, 0)
})
