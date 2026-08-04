// Application-layer auth (ESS-23, extracted): one-time pairing code → rotatable
// device token (stored hashed); every request carries request_id, timestamp,
// nonce, body sha256 and an HMAC-SHA256 signature over a canonical string.
// Tailscale ACL is the network gate; this is the mandatory app-side gate (§7).

import crypto from 'node:crypto'
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

export const ERR = {
  SOURCE_NOT_ALLOWED: ['ERR_SOURCE_NOT_ALLOWED', 403],
  NOT_FOUND: ['ERR_NOT_FOUND', 404],
  METHOD_NOT_ALLOWED: ['ERR_METHOD_NOT_ALLOWED', 405],
  BODY_TOO_LARGE: ['ERR_BODY_TOO_LARGE', 413],
  BAD_JSON: ['ERR_BAD_JSON', 400],
  PROTOCOL_VERSION: ['ERR_PROTOCOL_VERSION', 400],
  MISSING_FIELD: ['ERR_MISSING_FIELD', 400],
  PAIRING_CODE_INVALID: ['ERR_PAIRING_CODE_INVALID', 403],
  DEVICE_UNKNOWN: ['ERR_DEVICE_UNKNOWN', 401],
  TIMESTAMP_SKEW: ['ERR_TIMESTAMP_SKEW', 401],
  NONCE_REPLAYED: ['ERR_NONCE_REPLAYED', 401],
  BODY_HASH_MISMATCH: ['ERR_BODY_HASH_MISMATCH', 401],
  SIGNATURE_INVALID: ['ERR_SIGNATURE_INVALID', 401],
  AUDIO_TOO_LARGE: ['ERR_AUDIO_TOO_LARGE', 413],
  DURATION_TOO_LONG: ['ERR_DURATION_TOO_LONG', 422],
  AUDIO_HASH_MISMATCH: ['ERR_AUDIO_HASH_MISMATCH', 422],
  AUDIO_INVALID: ['ERR_AUDIO_INVALID', 422],
  IDEMPOTENCY_CONFLICT: ['ERR_IDEMPOTENCY_CONFLICT', 409],
  TURN_NOT_CANCELLABLE: ['ERR_TURN_NOT_CANCELLABLE', 409],
  PERMISSION_UNKNOWN: ['ERR_PERMISSION_UNKNOWN', 404],
  PERMISSION_DECISION_INVALID: ['ERR_PERMISSION_DECISION_INVALID', 400],
  UPSTREAM_UNAVAILABLE: ['ERR_UPSTREAM_UNAVAILABLE', 502],
  WORK_TIMEOUT: ['ERR_WORK_TIMEOUT', 504],
  INTERNAL: ['ERR_INTERNAL', 500],
}

export class ApiError extends Error {
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

export class DeviceAuth {
  constructor({ stateDir, timestampSkewMs, pairingCodeTtlMs, log = () => {} }) {
    this.path = join(stateDir, 'devices.json')
    this.timestampSkewMs = timestampSkewMs
    this.pairingCodeTtlMs = pairingCodeTtlMs
    this.log = log
    this.state = { devices: {}, nonces: {} }
    try { this.state = JSON.parse(readFileSync(this.path, 'utf8')) } catch { /* first boot */ }

    this.pairingCode = crypto.randomBytes(4).toString('hex')
    this.pairingCodeExpiry = Date.now() + pairingCodeTtlMs
    this.pairingCodeUsed = false
    const codePath = join(stateDir, 'pairing-code.txt')
    mkdirSync(stateDir, { recursive: true })
    writeFileSync(codePath, this.pairingCode + '\n', { mode: 0o600 })
    this.log({ evt: 'pairing_code_written', file: codePath, ttl_ms: pairingCodeTtlMs })
  }

  save() {
    mkdirSync(dirname(this.path), { recursive: true })
    const tmp = this.path + '.tmp'
    writeFileSync(tmp, JSON.stringify(this.state), { mode: 0o600 })
    renameSync(tmp, this.path)
  }

  pair(body) {
    if (!body.pairing_code || !body.device_name) throw new ApiError(ERR.MISSING_FIELD, 'pairing_code, device_name')
    const codeOk =
      !this.pairingCodeUsed &&
      Date.now() < this.pairingCodeExpiry &&
      body.pairing_code.length === this.pairingCode.length &&
      crypto.timingSafeEqual(Buffer.from(body.pairing_code), Buffer.from(this.pairingCode))
    if (!codeOk) throw new ApiError(ERR.PAIRING_CODE_INVALID)
    this.pairingCodeUsed = true

    const deviceId = 'dev_' + crypto.randomBytes(8).toString('hex')
    const token = crypto.randomBytes(32).toString('hex')
    this.state.devices[deviceId] = {
      name: String(body.device_name).slice(0, 64),
      token_sha256: sha256hex(token),
      paired_at: new Date().toISOString(),
    }
    this.save()
    this.log({ evt: 'device_paired', device_id: deviceId })
    return { device_id: deviceId, token } // token returned exactly once
  }

  pruneNonces(now) {
    for (const [n, ts] of Object.entries(this.state.nonces)) {
      if (now - ts > this.timestampSkewMs * 2) delete this.state.nonces[n]
    }
  }

  // Verifies headers of an HTTP request or WS upgrade. Signature check precedes
  // the nonce store so a forged request cannot burn a nonce.
  verify({ headers, method, pathName, rawBody }) {
    const deviceId = headers['x-device-id']
    const timestamp = headers['x-request-timestamp']
    const nonce = headers['x-nonce']
    const bodySha = headers['x-body-sha256']
    const signature = headers['x-signature']
    if (!deviceId || !timestamp || !nonce || !bodySha || !signature) {
      throw new ApiError(ERR.MISSING_FIELD, 'x-device-id, x-request-timestamp, x-nonce, x-body-sha256, x-signature')
    }
    const device = this.state.devices[deviceId]
    if (!device) throw new ApiError(ERR.DEVICE_UNKNOWN)

    const now = Date.now()
    const ts = Number(timestamp)
    if (!Number.isFinite(ts) || Math.abs(now - ts) > this.timestampSkewMs) throw new ApiError(ERR.TIMESTAMP_SKEW)
    if (sha256hex(rawBody) !== bodySha) throw new ApiError(ERR.BODY_HASH_MISMATCH)

    const requestId = headers['x-request-id'] || ''
    const expected = crypto
      .createHmac('sha256', Buffer.from(device.token_sha256, 'hex'))
      .update(canonicalString(deviceId, method, pathName, requestId, timestamp, nonce, bodySha))
      .digest('hex')
    let sigBuf
    try { sigBuf = Buffer.from(signature, 'hex') } catch { throw new ApiError(ERR.SIGNATURE_INVALID) }
    const expBuf = Buffer.from(expected, 'hex')
    if (sigBuf.length !== expBuf.length || !crypto.timingSafeEqual(sigBuf, expBuf)) {
      throw new ApiError(ERR.SIGNATURE_INVALID)
    }

    this.pruneNonces(now)
    const nonceKey = deviceId + ':' + nonce
    if (this.state.nonces[nonceKey]) throw new ApiError(ERR.NONCE_REPLAYED)
    this.state.nonces[nonceKey] = now
    this.save()

    return { deviceId, requestId }
  }
}

export function normalizeIp(ip) {
  return ip.startsWith('::ffff:') ? ip.slice(7) : ip
}

// IPv4 dotted-quad → unsigned 32-bit int, or null if malformed.
export function parseIPv4(text) {
  if (typeof text !== 'string') return null
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text)
  if (!m) return null
  let acc = 0
  for (let i = 1; i <= 4; i++) {
    const octet = Number(m[i])
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) return null
    acc = (acc * 256) + octet
  }
  return acc >>> 0
}

// "a.b.c.d/N" → {base, mask} (unsigned 32-bit), or null if malformed. The
// address must be the canonical network base for the given prefix so a typo
// like "192.168.1.5/24" is rejected rather than silently widened.
export function parseCidr(text) {
  if (typeof text !== 'string') return null
  const slash = text.indexOf('/')
  if (slash < 0) return null
  const base = parseIPv4(text.slice(0, slash))
  if (base === null) return null
  const bitsText = text.slice(slash + 1)
  if (!/^\d+$/.test(bitsText)) return null
  const bits = Number(bitsText)
  if (bits < 0 || bits > 32) return null
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0
  if (((base & mask) >>> 0) !== base) return null
  return { base, mask, bits }
}

// Source gate for the northbound TLS listener. Loopback is always allowed;
// every other peer must exactly match an IP listed in allowed_peer_ips or
// fall inside a listed IPv4 CIDR (e.g. "192.168.1.0/24"). LAN-connected
// Watch clients on the office WiFi come in through the CIDR path.
// Malformed entries fail loudly at boot so a typo cannot silently widen
// or narrow the gate.
export function makeSourceGate(allowedPeerIps) {
  const exact = new Set()
  const cidrs = []
  for (const entry of allowedPeerIps ?? []) {
    if (typeof entry !== 'string' || entry.length === 0) {
      throw new Error(`invalid allowed_peer_ips entry: ${JSON.stringify(entry)}`)
    }
    if (entry.includes('/')) {
      const cidr = parseCidr(entry)
      if (!cidr) throw new Error(`invalid CIDR in allowed_peer_ips: ${entry}`)
      cidrs.push(cidr)
    } else {
      if (parseIPv4(entry) === null) throw new Error(`invalid IP in allowed_peer_ips: ${entry}`)
      exact.add(entry)
    }
  }
  return ip => {
    if (ip === '127.0.0.1' || ip === '::1') return true
    if (exact.has(ip)) return true
    if (cidrs.length === 0) return false
    const num = parseIPv4(ip)
    if (num === null) return false
    for (const c of cidrs) if (((num & c.mask) >>> 0) === c.base) return true
    return false
  }
}
