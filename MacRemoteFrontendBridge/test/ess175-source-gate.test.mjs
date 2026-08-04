// ESS-175: makeSourceGate 支持 CIDR + 精确 LAN IP；DeviceAuth.pair 支持
// 固定 device_id（受 allowed_pairing_device_ids 白名单限制）。
import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { makeSourceGate, ipMatchesAllowlistEntry, DeviceAuth, ApiError, ERR } from '../auth.mjs'

describe('ESS-175 makeSourceGate', () => {
  test('loopback always allowed', () => {
    const gate = makeSourceGate([])
    assert.equal(gate('127.0.0.1'), true)
    assert.equal(gate('::1'), true)
  })

  test('exact IP in allowlist passes (Tailscale CGNAT)', () => {
    const gate = makeSourceGate(['100.80.229.218'])
    assert.equal(gate('100.80.229.218'), true)
    assert.equal(gate('100.80.229.219'), false)
  })

  test('exact LAN IP in allowlist passes', () => {
    const gate = makeSourceGate(['192.168.1.100'])
    assert.equal(gate('192.168.1.100'), true)
    assert.equal(gate('192.168.1.101'), false)
  })

  test('CIDR in allowlist matches range', () => {
    const gate = makeSourceGate(['192.168.0.0/16'])
    assert.equal(gate('192.168.1.100'), true)
    assert.equal(gate('192.168.99.50'), true)
    assert.equal(gate('192.168.0.0'), true)
    assert.equal(gate('192.168.255.255'), true)
    assert.equal(gate('192.169.0.1'), false)
    assert.equal(gate('10.0.0.1'), false)
  })

  test('CIDR /24 restricts to single subnet', () => {
    const gate = makeSourceGate(['192.168.1.0/24'])
    assert.equal(gate('192.168.1.5'), true)
    assert.equal(gate('192.168.1.255'), true)
    assert.equal(gate('192.168.2.0'), false)
  })

  test('unlisted public IP rejected (no CGNAT fallback)', () => {
    const gate = makeSourceGate(['192.168.0.0/16'])
    assert.equal(gate('8.8.8.8'), false)
    assert.equal(gate('100.80.229.218'), false, 'CGNAT must be explicitly listed now')
  })

  test('mixed exact + CIDR entries', () => {
    const gate = makeSourceGate(['127.0.0.1', '100.80.229.218', '192.168.0.0/16'])
    assert.equal(gate('100.80.229.218'), true)
    assert.equal(gate('192.168.5.5'), true)
    assert.equal(gate('192.169.5.5'), false)
  })

  test('malformed CIDR safely rejects', () => {
    const gate = makeSourceGate(['not-an-ip/16', '192.168.0.0/99', '192.168.0.0/-1'])
    assert.equal(gate('192.168.0.1'), false)
  })

  test('ipMatchesAllowlistEntry direct API', () => {
    assert.equal(ipMatchesAllowlistEntry('10.0.0.5', '10.0.0.0/8'), true)
    assert.equal(ipMatchesAllowlistEntry('11.0.0.5', '10.0.0.0/8'), false)
    assert.equal(ipMatchesAllowlistEntry('10.0.0.5', '10.0.0.5'), true)
    assert.equal(ipMatchesAllowlistEntry('10.0.0.5', ''), false)
    assert.equal(ipMatchesAllowlistEntry('10.0.0.5', null), false)
  })
})

describe('ESS-175 DeviceAuth.pair with fixed device_id', () => {
  function makeAuth({ allowedPairingDeviceIds = [] } = {}) {
    const stateDir = mkdtempSync(join(tmpdir(), 'ess175-auth-'))
    const auth = new DeviceAuth({
      stateDir,
      timestampSkewMs: 300000,
      pairingCodeTtlMs: 600000,
      allowedPairingDeviceIds,
    })
    return { auth, stateDir, cleanup: () => rmSync(stateDir, { recursive: true, force: true }) }
  }

  test('pair without body.device_id returns random dev_*', () => {
    const { auth, cleanup } = makeAuth()
    const paired = auth.pair({ pairing_code: auth.pairingCode, device_name: 'iPhone' })
    assert.match(paired.device_id, /^dev_[a-f0-9]{16}$/)
    cleanup()
  })

  test('pair with allowed body.device_id returns exact id', () => {
    const { auth, cleanup } = makeAuth({ allowedPairingDeviceIds: ['jackson-watch'] })
    const paired = auth.pair({
      pairing_code: auth.pairingCode,
      device_name: 'Apple Watch',
      device_id: 'jackson-watch',
    })
    assert.equal(paired.device_id, 'jackson-watch')
    cleanup()
  })

  test('pair with disallowed body.device_id rejects', () => {
    const { auth, cleanup } = makeAuth({ allowedPairingDeviceIds: ['jackson-watch'] })
    assert.throws(
      () => auth.pair({
        pairing_code: auth.pairingCode,
        device_name: 'Attacker',
        device_id: 'attacker-id',
      }),
      err => err instanceof ApiError && err.code === ERR.MISSING_FIELD[0],
    )
    cleanup()
  })

  test('pair with already-paired device_id rejects', () => {
    const { auth, cleanup } = makeAuth({ allowedPairingDeviceIds: ['jackson-watch'] })
    // Reset pairing code between the two pair calls (pairingCodeUsed flag).
    auth.pair({ pairing_code: auth.pairingCode, device_name: 'Watch 1', device_id: 'jackson-watch' })
    auth.pairingCodeUsed = false
    auth.pairingCode = 'aabbccdd'
    auth.pairingCodeExpiry = Date.now() + 60000
    assert.throws(
      () => auth.pair({ pairing_code: auth.pairingCode, device_name: 'Watch 2', device_id: 'jackson-watch' }),
      err => err instanceof ApiError && err.code === ERR.MISSING_FIELD[0],
    )
    cleanup()
  })

  test('empty allowedPairingDeviceIds means any body.device_id rejected', () => {
    const { auth, cleanup } = makeAuth()
    assert.throws(
      () => auth.pair({
        pairing_code: auth.pairingCode,
        device_name: 'Watch',
        device_id: 'jackson-watch',
      }),
      err => err instanceof ApiError && err.code === ERR.MISSING_FIELD[0],
    )
    cleanup()
  })
})
