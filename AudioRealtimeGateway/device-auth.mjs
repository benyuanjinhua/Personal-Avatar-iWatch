// Per-device HMAC signature verifier for the session-token endpoint. The wire
// format is the SAME canonical string the Mac Bridge uses (see
// `MacRemoteFrontendBridge/auth.mjs`) so `state/devices.json` can be shared
// during bootstrap. The Gateway never issues long-lived tokens itself; this
// module only gates the ephemeral-token issuer.

import crypto from 'node:crypto'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const AUTH_ERR = {
  MISSING_FIELD: ['ERR_MISSING_FIELD', 400],
  DEVICE_UNKNOWN: ['ERR_DEVICE_UNKNOWN', 401],
  TIMESTAMP_SKEW: ['ERR_TIMESTAMP_SKEW', 401],
  NONCE_REPLAYED: ['ERR_NONCE_REPLAYED', 401],
  BODY_HASH_MISMATCH: ['ERR_BODY_HASH_MISMATCH', 401],
  SIGNATURE_INVALID: ['ERR_SIGNATURE_INVALID', 401],
}

export class AuthError extends Error {
  constructor([code, status], detail) {
    super(code)
    this.code = code
    this.status = status
    this.detail = detail
  }
}

export const sha256hex = buf => crypto.createHash('sha256').update(buf).digest('hex')

export function canonicalString(deviceId, method, pathName, requestId, timestamp, nonce, bodySha) {
  return ['v1', deviceId, method, pathName, requestId, timestamp, nonce, bodySha].join('\n')
}

export class DeviceStore {
  constructor({ stateDir, timestampSkewMs = 300_000, log = () => {} }) {
    this.path = join(stateDir, 'devices.json')
    this.timestampSkewMs = timestampSkewMs
    this.log = log
    this.state = { devices: {}, nonces: {} }
    try { this.state = JSON.parse(readFileSync(this.path, 'utf8')) } catch { /* first boot */ }
  }

  save() {
    mkdirSync(dirname(this.path), { recursive: true })
    const tmp = this.path + '.tmp'
    writeFileSync(tmp, JSON.stringify(this.state), { mode: 0o600 })
    renameSync(tmp, this.path)
  }

  // Register a device with a raw token (test / bootstrap helper). Only the
  // sha256 is persisted; the raw token must be delivered out-of-band.
  register(deviceId, tokenRaw, extras = {}) {
    if (!deviceId || typeof deviceId !== 'string') throw new AuthError(AUTH_ERR.MISSING_FIELD, 'device_id')
    if (!tokenRaw || typeof tokenRaw !== 'string' || tokenRaw.length < 32) {
      throw new AuthError(AUTH_ERR.MISSING_FIELD, 'token must be at least 32 chars')
    }
    this.state.devices[deviceId] = {
      token_sha256: sha256hex(tokenRaw),
      registered_at: new Date().toISOString(),
      ...extras,
    }
    this.save()
    return { device_id: deviceId }
  }

  has(deviceId) {
    return Boolean(this.state.devices[deviceId])
  }

  #pruneNonces(now) {
    for (const [n, ts] of Object.entries(this.state.nonces)) {
      if (now - ts > this.timestampSkewMs * 2) delete this.state.nonces[n]
    }
  }

  // Verify an HMAC-signed HTTP request. `rawBody` is the exact bytes that
  // the client hashed (a Buffer). Throws AuthError on any failure.
  verify({ headers, method, pathName, rawBody, now = Date.now() }) {
    const deviceId = headers['x-device-id']
    const timestamp = headers['x-request-timestamp']
    const nonce = headers['x-nonce']
    const bodySha = headers['x-body-sha256']
    const signature = headers['x-signature']
    if (!deviceId || !timestamp || !nonce || !bodySha || !signature) {
      throw new AuthError(AUTH_ERR.MISSING_FIELD,
        'x-device-id, x-request-timestamp, x-nonce, x-body-sha256, x-signature')
    }
    const device = this.state.devices[deviceId]
    if (!device) throw new AuthError(AUTH_ERR.DEVICE_UNKNOWN)

    const ts = Number(timestamp)
    if (!Number.isFinite(ts) || Math.abs(now - ts) > this.timestampSkewMs) {
      throw new AuthError(AUTH_ERR.TIMESTAMP_SKEW)
    }
    const bodyHash = sha256hex(rawBody)
    if (bodyHash !== bodySha) throw new AuthError(AUTH_ERR.BODY_HASH_MISMATCH)

    const requestId = headers['x-request-id'] || ''
    const expected = crypto
      .createHmac('sha256', Buffer.from(device.token_sha256, 'hex'))
      .update(canonicalString(deviceId, method, pathName, requestId, timestamp, nonce, bodySha))
      .digest('hex')
    let sigBuf
    try { sigBuf = Buffer.from(signature, 'hex') } catch { throw new AuthError(AUTH_ERR.SIGNATURE_INVALID) }
    const expBuf = Buffer.from(expected, 'hex')
    if (sigBuf.length !== expBuf.length || !crypto.timingSafeEqual(sigBuf, expBuf)) {
      throw new AuthError(AUTH_ERR.SIGNATURE_INVALID)
    }

    this.#pruneNonces(now)
    const nonceKey = deviceId + ':' + nonce
    if (this.state.nonces[nonceKey]) throw new AuthError(AUTH_ERR.NONCE_REPLAYED)
    this.state.nonces[nonceKey] = now
    this.save()

    return { deviceId, requestId }
  }
}

// Helper for tests / clients: build the canonical signature over a body.
export function signRequest({ tokenRaw, deviceId, method, pathName, requestId, body, nonce, timestamp }) {
  const rawBody = body === undefined || body === null ? Buffer.alloc(0)
    : Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))
  const bodySha = sha256hex(rawBody)
  const canonical = canonicalString(deviceId, method, pathName, requestId, String(timestamp), nonce, bodySha)
  const key = Buffer.from(sha256hex(tokenRaw), 'hex')
  const signature = crypto.createHmac('sha256', key).update(canonical).digest('hex')
  return {
    rawBody,
    headers: {
      'x-device-id': deviceId,
      'x-request-timestamp': String(timestamp),
      'x-nonce': nonce,
      'x-body-sha256': bodySha,
      'x-signature': signature,
      ...(requestId ? { 'x-request-id': requestId } : {}),
    },
  }
}
