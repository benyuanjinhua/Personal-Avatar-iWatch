import { createHash, createHmac } from 'node:crypto'
import http from 'node:http'
import https from 'node:https'

const signServiceRequest = ({ secret, method, path, requestId, timestamp, body }) => {
  const bodySha = createHash('sha256').update(body).digest('hex')
  const canonical = ['fallback-v1', method, path, requestId, timestamp, bodySha].join('\n')
  return { bodySha, signature: createHmac('sha256', secret).update(canonical).digest('hex') }
}

export class FallbackJobClient {
  constructor({ baseUrl, secret, pollMs = 100, timeoutMs = 35_000, log = () => {} }) {
    this.baseUrl = baseUrl; this.secret = secret; this.pollMs = pollMs; this.timeoutMs = timeoutMs; this.log = log
  }
  async submitAndWait({ requestId, audio, audioSha256, context = {} }) {
    // ESS-983: 三个拒因拆成三个可区分的错误码，不再共享误导性的
    // `gateway_unavailable`——密钥缺失是确定性配置失败，网关不可达是
    // 网络问题，网关拒绝是服务端主动拒收。
    if (!this.secret || this.secret.length < 32) throw Object.assign(new Error('fallback HMAC secret unavailable'), { code: 'fallback_hmac_secret_missing' })
    const path = `/v1/fallback-jobs/${encodeURIComponent(requestId)}`
    const body = Buffer.from(JSON.stringify({ request_id: requestId, codec: 'pcm_s16le_16k',
      audio_sha256: audioSha256, audio_base64: audio.toString('base64'),
      parent_request_id: context.parentRequestId ?? null,
      context_summary: context.contextSummary ?? null,
    }))
    const accepted = await this.#request('POST', path, requestId, body)
    if (!['accepted', 'duplicate'].includes(accepted.status)) {
      throw Object.assign(new Error(accepted.reason ?? 'fallback rejected'), { code: accepted.reason ?? 'fallback_rejected' })
    }
    const deadline = Date.now() + this.timeoutMs
    while (Date.now() < deadline) {
      const job = await this.#request('GET', path, requestId, Buffer.alloc(0))
      if (job.state === 'completed') return job.result
      if (['failed', 'rejected', 'timed_out', 'cancelled'].includes(job.state)) {
        throw Object.assign(new Error(job.reason ?? job.state), { code: job.reason ?? job.state })
      }
      await new Promise(resolve => setTimeout(resolve, this.pollMs))
    }
    await this.cancel(requestId).catch(() => {})
    throw Object.assign(new Error('fallback job wait timeout'), { code: 'queue_timeout' })
  }
  cancel(requestId) {
    const path = `/v1/fallback-jobs/${encodeURIComponent(requestId)}`
    return this.#request('DELETE', path, requestId, Buffer.alloc(0))
  }
  #request(method, path, requestId, body) {
    const timestamp = String(Date.now())
    const signed = signServiceRequest({ secret: this.secret, method, path, requestId, timestamp, body })
    const url = new URL(path, this.baseUrl); const transport = url.protocol === 'https:' ? https : http
    return new Promise((resolve, reject) => {
      const req = transport.request(url, { method, headers: {
        'content-type': 'application/json', 'content-length': body.length,
        'x-request-id': requestId, 'x-request-timestamp': timestamp,
        'x-body-sha256': signed.bodySha, 'x-signature': signed.signature,
      } }, res => {
        const chunks = []; res.on('data', c => chunks.push(c)); res.on('end', () => {
          let parsed = {}; try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch { /* typed below */ }
          if ((res.statusCode ?? 500) >= 400) return reject(Object.assign(new Error(parsed.reason ?? parsed.error ?? 'gateway refused'), {
            code: parsed.reason ?? parsed.error ?? 'gateway_refused', status: res.statusCode,
          }))
          resolve(parsed)
        })
      })
      req.on('error', error => reject(Object.assign(error, { code: 'gateway_unreachable' })))
      req.end(body)
    })
  }
}
