import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { describe, it } from 'node:test'

import { QwenAgentTransport } from '../agent-transport.mjs'

class FakeWebSocket extends EventEmitter {
  static instances = []
  constructor(url, options) {
    super(); this.url = url; this.options = options; this.sent = []; this.closed = false
    FakeWebSocket.instances.push(this)
  }
  send(text) { this.sent.push(JSON.parse(text)) }
  close() { this.closed = true }
}

const tick = () => new Promise(resolve => setImmediate(resolve))

describe('QwenAgentTransport', () => {
  it('streams queued PCM to the real protocol and maps provider audio events', async () => {
    FakeWebSocket.instances.length = 0
    const logs = []; const events = []
    const transport = new QwenAgentTransport({
      providerKey: 'secret-sentinel', url: 'ws://provider.test/realtime', model: 'qwen-test',
      log: (evt, extra) => logs.push({ evt, ...extra }), WebSocketImpl: FakeWebSocket,
    })
    const turn = transport.openTurn({ requestId: 'req-1', sessionId: 'sess-1', generation: 1,
      responseId: 'req-1:gen1', onEvent: event => events.push(event) })
    const ws = FakeWebSocket.instances[0]
    turn.appendAudio({ bytes: Buffer.from('pcm') }); turn.commit()
    assert.equal(ws.sent.length, 0, 'audio waits for provider session readiness')
    ws.emit('open')
    assert.equal(ws.options.headers.Authorization, 'Bearer secret-sentinel')
    assert.equal(ws.sent[0].type, 'session.update')
    ws.emit('message', Buffer.from(JSON.stringify({ type: 'session.created' })))
    assert.equal(ws.sent.length, 1, 'audio waits for session.update acknowledgement')
    ws.emit('message', Buffer.from(JSON.stringify({ type: 'session.updated' })))
    assert.deepEqual(ws.sent.slice(1).map(event => event.type),
      ['input_audio_buffer.append', 'input_audio_buffer.commit', 'response.create'])
    ws.emit('message', Buffer.from(JSON.stringify({ type: 'response.audio.delta', delta: 'AQI=' })))
    ws.emit('message', Buffer.from(JSON.stringify({ type: 'response.audio.done' })))
    assert.deepEqual(events.map(event => [event.type, event.sequence, event.final_sequence]), [
      ['agent.audio.delta', 0, undefined], ['agent.audio.done', undefined, 0],
    ])
    assert.ok(logs.every(record => !JSON.stringify(record).includes('secret-sentinel')))
  })

  it('turns provider failure into one structured agent error without leaking the key', async () => {
    FakeWebSocket.instances.length = 0
    const logs = []; const events = []
    const transport = new QwenAgentTransport({ providerKey: 'secret-sentinel',
      url: 'ws://provider.test/realtime', log: (evt, extra) => logs.push({ evt, ...extra }),
      WebSocketImpl: FakeWebSocket })
    transport.openTurn({ requestId: 'req-2', sessionId: 'sess-2', generation: 3,
      responseId: 'req-2:gen3', onEvent: event => events.push(event) })
    const ws = FakeWebSocket.instances[0]
    ws.emit('open')
    ws.emit('message', Buffer.from(JSON.stringify({ type: 'error', error: {
      type: 'server_error', code: 'service_unavailable', message: 'try later',
    } })))
    ws.emit('close', 1011)
    await tick()
    assert.equal(events.length, 1)
    assert.deepEqual(events[0], { type: 'agent.error', response_id: 'req-2:gen3',
      code: 'ERR_UPSTREAM_UNAVAILABLE', detail: 'try later', retriable: true })
    assert.equal(logs.find(record => record.evt === 'agent_upstream_error').request_id, 'req-2')
    assert.ok(logs.every(record => !JSON.stringify(record).includes('secret-sentinel')))
  })
})
