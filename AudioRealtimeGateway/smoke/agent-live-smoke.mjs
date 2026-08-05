#!/usr/bin/env node
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { QwenAgentTransport } from '../qwen-agent-transport.mjs'

const pcmPath = process.argv[2]
if (!pcmPath) {
  console.error('usage: node smoke/agent-live-smoke.mjs <16k-mono-s16le.pcm>')
  process.exit(2)
}

const requestId = `live_${randomUUID().replaceAll('-', '')}`
const sessionId = `smoke_${Date.now()}`
const pcm = readFileSync(pcmPath)
const events = []
const logs = []
let settle
const finished = new Promise((resolve, reject) => {
  settle = { resolve, reject }
  setTimeout(() => reject(new Error('live upstream timeout')), 60_000).unref?.()
})
const transport = new QwenAgentTransport({
  log: (evt, extra) => logs.push({ evt, ...extra }),
})
const turn = transport.openTurn({
  requestId, sessionId, generation: 1, responseId: `${requestId}:gen1`,
  onEvent: event => {
    events.push(event)
    if (event.type === 'agent.audio.done') settle.resolve()
    if (event.type === 'agent.error') settle.reject(new Error(`${event.code}: ${event.detail ?? ''}`))
  },
})
for (let offset = 0, sequence = 0; offset < pcm.length; offset += 3_200, sequence += 1) {
  turn.appendAudio({ sequence, bytes: pcm.subarray(offset, offset + 3_200) })
}
turn.commit()

try {
  await finished
  const deltas = events.filter(event => event.type === 'agent.audio.delta')
  console.log(JSON.stringify({
    ok: true, request_id: requestId, input_bytes: pcm.length,
    output_deltas: deltas.length,
    output_bytes: deltas.reduce((sum, event) => sum + Buffer.from(event.audio, 'base64').length, 0),
    stages: logs.map(item => item.evt),
  }))
} finally {
  turn.close()
}
