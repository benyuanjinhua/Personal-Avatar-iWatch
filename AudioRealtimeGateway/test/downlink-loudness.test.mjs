import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { WebSocketServer } from 'ws'
import { QwenAgentTransport, dbfs, pcm16Level } from '../qwen-agent-transport.mjs'

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

function pcm16(...values) {
  const buf = Buffer.alloc(values.length * 2)
  values.forEach((value, index) => buf.writeInt16LE(value, index * 2))
  return buf
}

// ESS-891 取证口径：Gateway 与 Watch 用同一套 rms/peak 指标对同一 request_id
// 对账，才能证明「源音频低」还是「Watch 侧衰减」。
test('pcm16Level computes the same rms/peak the Watch player logs', () => {
  const full = pcm16Level(pcm16(32767, 32767).toString('base64'))
  assert.ok(Math.abs(full.rms - 1.0) < 0.0001)
  assert.ok(Math.abs(full.peak - 1.0) < 0.0001)
  assert.equal(full.samples, 2)

  const half = pcm16Level(pcm16(16384, 16384).toString('base64'))
  assert.ok(Math.abs(half.rms - 0.5) < 0.001)
  assert.ok(Math.abs(half.peak - 0.5) < 0.001)

  const silence = pcm16Level(pcm16(0, 0, 0, 0).toString('base64'))
  assert.equal(silence.rms, 0)
  assert.equal(silence.peak, 0)

  const empty = pcm16Level('')
  assert.equal(empty.samples, 0)
  assert.equal(empty.rms, 0)
})

test('dbfs converts known linear levels', () => {
  assert.ok(Math.abs(dbfs(1.0) - 0.0) < 0.0001)
  assert.ok(Math.abs(dbfs(0.5) - (-6.0206)) < 0.001)
  assert.equal(dbfs(0), -Infinity)
})

// 端到端：第一帧落 frame=first、audio.done 落 frame=summary，均带 request_id。
test('logs first-frame and summary PCM level per request', async () => {
  const frame = pcm16(16384, 16384) // 0.5 满量程
  const url = await upstream((ws, message) => {
    if (message.type === 'connect') ws.send(JSON.stringify({ type: 'voice.ready' }))
    if (message.type === 'audio.commit') {
      ws.send(JSON.stringify({
        type: 'audio.delta', sequence: 0, audio: frame.toString('base64'), sampleRate: 24_000,
      }))
      ws.send(JSON.stringify({ type: 'audio.done' }))
    }
  })
  const events = []; const logs = []
  const transport = new QwenAgentTransport({
    gatewayUrl: url, log: (evt, extra) => logs.push({ evt, ...extra }),
  })
  const turn = transport.openTurn({
    requestId: 'r-loud', sessionId: 's-loud', generation: 1, responseId: 'r-loud:gen1',
    onEvent: event => events.push(event),
  })
  turn.appendAudio({ sequence: 0, bytes: Buffer.from('audio') })
  turn.commit()
  await waitFor(() => events.some(event => event.type === 'agent.audio.done'))

  const first = logs.find(item => item.evt === 'upstream_pcm_level' && item.frame === 'first')
  assert.ok(first, 'first frame loudness must be logged')
  assert.equal(first.request_id, 'r-loud')
  assert.ok(Math.abs(first.rms - 0.5) < 0.001)
  assert.ok(Math.abs(first.peak_rms - 0.5) < 0.001)
  assert.equal(first.sample_rate, 24_000)
  assert.equal(first.samples, 2)

  const summary = logs.find(item => item.evt === 'upstream_pcm_level' && item.frame === 'summary')
  assert.ok(summary, 'summary loudness must be logged on done')
  assert.equal(summary.frames, 1)
  assert.ok(Math.abs(summary.peak_rms - 0.5) < 0.001)
  turn.close()
})
