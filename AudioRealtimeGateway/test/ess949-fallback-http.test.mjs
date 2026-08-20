import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync } from 'node:fs'
import http from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { createGateway } from '../server.mjs'
import { signServiceRequest } from '../service-auth.mjs'

const secret = 'ess949-test-secret-that-is-at-least-32-bytes'
const request = ({ port, method, path, requestId, body = Buffer.alloc(0), signatureSecret = secret }) => new Promise((resolve, reject) => {
  const timestamp = String(Date.now())
  const signed = signServiceRequest({ secret: signatureSecret, method, path, requestId, timestamp, body })
  const req = http.request({ host: '127.0.0.1', port, path, method, headers: {
    'content-type': 'application/json', 'content-length': body.length,
    'x-request-id': requestId, 'x-request-timestamp': timestamp,
    'x-body-sha256': signed.bodySha, 'x-signature': signed.signature,
  } }, res => {
    const chunks = []; res.on('data', c => chunks.push(c)); res.on('end', () => {
      resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString()) })
    })
  }); req.on('error', reject); req.end(body)
})

test('HMAC loopback endpoint executes through the Gateway-owned transport', async () => {
  const prior = process.env.FALLBACK_JOB_HMAC_SECRET; process.env.FALLBACK_JOB_HMAC_SECRET = secret
  const gateway = createGateway({ state_dir: mkdtempSync(join(tmpdir(), 'ess949-http-')),
    bind: '127.0.0.1', port: 0, dev_allow_plain_ws: true, agent_transport: 'mock',
    fallback_jobs_enabled: true })
  try {
    await gateway.start(); const port = gateway.server.address().port
    const audio = Buffer.from('pcm16 test bytes'); const audioSha = createHash('sha256').update(audio).digest('hex')
    const requestId = 'ess949-http-1'; const path = `/v1/fallback-jobs/${requestId}`
    const body = Buffer.from(JSON.stringify({ request_id: requestId, codec: 'pcm_s16le_16k',
      audio_sha256: audioSha, audio_base64: audio.toString('base64') }))
    assert.equal((await request({ port, method: 'POST', path, requestId, body })).status, 202)
    let status
    for (let i = 0; i < 20; i++) {
      status = await request({ port, method: 'GET', path, requestId })
      if (status.body.state === 'completed') break
      await new Promise(resolve => setTimeout(resolve, 5))
    }
    assert.equal(status.status, 200); assert.equal(status.body.state, 'completed')
    assert.ok(status.body.result.audio24k_base64)
    const duplicate = await request({ port, method: 'POST', path, requestId, body })
    assert.equal(duplicate.status, 202); assert.equal(duplicate.body.status, 'duplicate')
  } finally {
    await gateway.stop()
    if (prior === undefined) delete process.env.FALLBACK_JOB_HMAC_SECRET
    else process.env.FALLBACK_JOB_HMAC_SECRET = prior
  }
})

test('fallback endpoint rejects a bad service signature', async () => {
  const prior = process.env.FALLBACK_JOB_HMAC_SECRET; process.env.FALLBACK_JOB_HMAC_SECRET = secret
  const gateway = createGateway({ state_dir: mkdtempSync(join(tmpdir(), 'ess949-auth-')),
    bind: '127.0.0.1', port: 0, dev_allow_plain_ws: true, agent_transport: 'mock', fallback_jobs_enabled: true })
  try {
    await gateway.start(); const port = gateway.server.address().port
    const result = await request({ port, method: 'GET', path: '/v1/fallback-jobs/bad', requestId: 'bad',
      signatureSecret: 'wrong-secret-that-is-still-long-enough-000' })
    assert.equal(result.status, 401); assert.equal(result.body.reason, 'auth_failed')
  } finally { await gateway.stop(); if (prior === undefined) delete process.env.FALLBACK_JOB_HMAC_SECRET; else process.env.FALLBACK_JOB_HMAC_SECRET = prior }
})
