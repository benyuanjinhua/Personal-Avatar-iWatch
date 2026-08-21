import { createHash, createHmac, timingSafeEqual } from 'node:crypto'

const sha = value => createHash('sha256').update(value).digest('hex')
export const signServiceRequest = ({ secret, method, path, requestId, timestamp, body }) => {
  const bodySha = sha(body)
  const canonical = ['fallback-v1', method, path, requestId, timestamp, bodySha].join('\n')
  return { bodySha, signature: createHmac('sha256', secret).update(canonical).digest('hex') }
}

export function verifyServiceRequest({ secret, headers, method, path, body, now = Date.now(), skewMs = 300_000 }) {
  if (!secret || secret.length < 32) return false
  const requestId = headers['x-request-id']; const timestamp = headers['x-request-timestamp']
  const bodySha = headers['x-body-sha256']; const signature = headers['x-signature']
  if (!requestId || !timestamp || !bodySha || !signature || Math.abs(now - Number(timestamp)) > skewMs) return false
  const expected = signServiceRequest({ secret, method, path, requestId, timestamp, body })
  if (expected.bodySha !== bodySha) return false
  const a = Buffer.from(signature, 'hex'); const b = Buffer.from(expected.signature, 'hex')
  return a.length === b.length && timingSafeEqual(a, b)
}
