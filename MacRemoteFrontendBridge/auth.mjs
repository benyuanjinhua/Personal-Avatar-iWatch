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
  constructor({ stateDir, timestampSkewMs, pairingCodeTtlMs, allowedPairingDeviceIds = [], log = () => {} }) {
    this.path = join(stateDir, 'devices.json')
    this.timestampSkewMs = timestampSkewMs
    this.pairingCodeTtlMs = pairingCodeTtlMs
    // ESS-175: 允许 config 通过 allowed_pairing_device_ids 固定 pair 出的 device_id
    // （例如 "jackson-watch"）。如果 pair body 里带了 device_id 但不在列表里，
    // 拒绝；如果没带 device_id，走原来的 dev_* 随机生成。
    this.allowedPairingDeviceIds = Array.isArray(allowedPairingDeviceIds) ? allowedPairingDeviceIds : []
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

    // ESS-175: 允许调用方指定 device_id（仅限 allowed_pairing_device_ids 白名单），
    // 未指定时按原路径随机生成 dev_*。已配对过的 device_id 不允许重复配对——
    // 由白梦林先手动清 devices.json 里对应条目再重跑。
    let deviceId
    if (body.device_id) {
      if (!this.allowedPairingDeviceIds.includes(body.device_id)) {
        throw new ApiError(ERR.MISSING_FIELD, 'device_id not in allowed_pairing_device_ids')
      }
      if (this.state.devices[body.device_id]) {
        throw new ApiError(ERR.MISSING_FIELD, 'device_id already paired; clear devices.json to re-pair')
      }
      deviceId = body.device_id
    } else {
      deviceId = 'dev_' + crypto.randomBytes(8).toString('hex')
    }
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
export function inCgnat(ip) {
  const m = ip.match(/^100\.(\d+)\.\d+\.\d+$/)
  return Boolean(m && Number(m[1]) >= 64 && Number(m[1]) <= 127)
}

// ESS-175: allowed_peer_ips entries can be exact IPv4 ("192.168.1.5") or
// CIDR ("192.168.0.0/16"). Config is the trust declaration—CGNAT is no
// longer required. Loopback stays hard-wired. Anything else (public IPv4,
// IPv6 beyond ::1) must be listed explicitly in config.
function ipv4ToInt(ip) {
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some(p => !Number.isInteger(p) || p < 0 || p > 255)) return null
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
}
export function ipMatchesAllowlistEntry(ip, entry) {
  if (!entry) return false
  if (!entry.includes('/')) return ip === entry
  const [prefix, bitsStr] = entry.split('/')
  const bits = Number(bitsStr)
  if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false
  const ipInt = ipv4ToInt(ip)
  const prefixInt = ipv4ToInt(prefix)
  if (ipInt === null || prefixInt === null) return false
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0
  return (ipInt & mask) === (prefixInt & mask)
}
export function makeSourceGate(allowedPeerIps) {
  const entries = Array.isArray(allowedPeerIps) ? allowedPeerIps : []
  return ip => ip === '127.0.0.1' || ip === '::1' || entries.some(e => ipMatchesAllowlistEntry(ip, e))
}
