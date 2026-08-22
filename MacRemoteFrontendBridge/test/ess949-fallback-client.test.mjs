import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync } from 'node:fs'
import http from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { FallbackJobClient } from '../fallback-job-client.mjs'
import { FallbackJobOutbox } from '../fallback-job-outbox.mjs'
import { verifyServiceRequest } from '../../AudioRealtimeGateway/service-auth.mjs'

test('Bridge outbox durably recovers a pending full file and settles it', () => {
  const stateDir = mkdtempSync(join(tmpdir(), 'ess949-outbox-')); const audio = Buffer.from('full file')
  const meta = { sha256: createHash('sha256').update(audio).digest('hex'), codec: 'm4a' }
  const first = new FallbackJobOutbox({ stateDir }); first.accept({ requestId: 'r1', audio, meta, context: {} })
  const restarted = new FallbackJobOutbox({ stateDir }); assert.equal(restarted.pending().length, 1)
  assert.deepEqual(restarted.readAudio(restarted.pending()[0]), audio)
  restarted.settle('r1', 'completed'); assert.equal(restarted.pending().length, 0)
})

test('Bridge outbox persists the ledger seed needed to close the accept/create crash window', () => {
  const stateDir = mkdtempSync(join(tmpdir(), 'ess949-outbox-seed-')); const audio = Buffer.from('full file')
  const meta = { sha256: createHash('sha256').update(audio).digest('hex'), codec: 'm4a' }
  const ledgerSeed = { deviceId: 'watch-1', bodySha256: 'body-hash', sessionId: 'session-1', watchCreatedAt: 42 }
  new FallbackJobOutbox({ stateDir }).accept({ requestId: 'crash-window', audio, meta, context: {}, ledgerSeed })
  const recovered = new FallbackJobOutbox({ stateDir }).pending()[0]
  assert.deepEqual(recovered.ledger_seed, ledgerSeed)
})

test('Bridge client signs POST/GET and observes a terminal result', async () => {
  const secret = 'bridge-client-test-secret-32-bytes-minimum'; let gets = 0
  const server = http.createServer((req, res) => {
    const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => {
      const body = Buffer.concat(chunks); const requestId = req.headers['x-request-id']
      assert.ok(verifyServiceRequest({ secret, headers: req.headers, method: req.method, path: req.url, body }))
      res.setHeader('content-type', 'application/json')
      if (req.method === 'POST') return res.end(JSON.stringify({ status: 'accepted' }))
      gets++; res.end(JSON.stringify(gets === 1 ? { state: 'queued' }
        : { state: 'completed', result: { audio24k_base64: 'AA==' } }))
    })
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  try {
    const client = new FallbackJobClient({ baseUrl: `http://127.0.0.1:${server.address().port}`,
      secret, pollMs: 1, timeoutMs: 1000 })
    const audio = Buffer.from('pcm'); const audioSha256 = createHash('sha256').update(audio).digest('hex')
    const result = await client.submitAndWait({ requestId: 'r2', audio, audioSha256 })
    assert.equal(result.audio24k_base64, 'AA=='); assert.equal(gets, 2)
  } finally { await new Promise(resolve => server.close(resolve)) }
})

test('Bridge client maps an unreachable Gateway to an explicit failure', async () => {
  const client = new FallbackJobClient({ baseUrl: 'http://127.0.0.1:1',
    secret: 'bridge-client-test-secret-32-bytes-minimum', timeoutMs: 20 })
  await assert.rejects(client.submitAndWait({ requestId: 'r3', audio: Buffer.from('x'), audioSha256: 'x' }),
    error => error.code === 'gateway_unreachable')
})

test('Bridge client maps a missing HMAC secret to a deterministic failure', async () => {
  const client = new FallbackJobClient({ baseUrl: 'http://127.0.0.1:1', secret: '', timeoutMs: 500 })
  await assert.rejects(client.submitAndWait({ requestId: 'r4', audio: Buffer.from('x'), audioSha256: 'x' }),
    error => error.code === 'fallback_hmac_secret_missing')
})

test('Bridge client maps a short HMAC secret to a deterministic failure', async () => {
  const client = new FallbackJobClient({ baseUrl: 'http://127.0.0.1:1', secret: 'too-short', timeoutMs: 500 })
  await assert.rejects(client.submitAndWait({ requestId: 'r5', audio: Buffer.from('x'), audioSha256: 'x' }),
    error => error.code === 'fallback_hmac_secret_missing')
})

test('Bridge client maps a gateway rejection to a distinct refusal code', async () => {
  const server = http.createServer((req, res) => {
    res.writeHead(500, { 'content-type': 'text/plain' })
    res.end('boom')
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  try {
    const client = new FallbackJobClient({ baseUrl: `http://127.0.0.1:${server.address().port}`,
      secret: 'bridge-client-test-secret-32-bytes-minimum', timeoutMs: 500 })
    await assert.rejects(client.submitAndWait({ requestId: 'r6', audio: Buffer.from('x'), audioSha256: 'x' }),
      error => error.code === 'gateway_refused')
  } finally { await new Promise(resolve => server.close(resolve)) }
})
